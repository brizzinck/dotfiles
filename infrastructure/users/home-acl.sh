#!/usr/bin/env bash
# Extended-ACL cleanup of the owner's home + owner-only permissions of the known secret locations. One implementation for
# apply-system.sh (section users), doctor.sh (check `home-acl`), rollback.sh and the offline tests.
#
#   home-acl.sh report [opts]   read-only: what `apply` would do (counts, kinds, examples, every path it would tighten)
#   home-acl.sh apply  [opts]   do it (root when the home belongs to the owner): strip the unintended extended ACLs, tighten
#                               the secret locations, keep the before-state, write the marker file
#   home-acl.sh check  [opts]   read-only and bounded (doctor): key=value lines (acl_count, acl_examples, mode_count,
#                               mode_examples, partial, marker)
# Options (defaults in brackets; every one is a test hook):
#   --root DIR      tree to clean [$HOME]            --owner USER    owner of the tree [current user]
#   --state DIR     before-state dir [/var/lib/usr-managed]
#   --managed LIST  space separated managed users whose leftover named entries are removed too [managed.tsv]
#   --keep FILE     explicit keep list [home-acl-keep.txt next to this script]
#   --secrets FILE  secret locations [secret-paths.txt next to this script]
#   --repo DIR      what @REPO@ stands for in the secrets file [the dotfiles checkout]
#   --marker FILE   written by `apply` [ROOT/.local/state/usr/home-acl-cleanup]
#   --examples N    examples to print [8]            --depth N / --budget SECONDS   check only [5 / 10]
#
# What is an unintended extended ACL: any path of the tree that carries an ACL xattr without a named user/group entry that
# is not a managed user's: a default-ACL skeleton (default:user/group/other/mask with nothing named; it makes new files
# 0650/0750), a leftover access mask, a default mask. `setfacl -b` removes them (the file mode stays; where the old group
# entry was narrower than the mask the group bits are set to the effective permission, so nothing becomes wider).
# Kept: paths with a named entry of anybody else (listed), paths under an entry of the keep file, paths owned by another
# user (Docker volumes), paths whose name contains a backslash (getfacl escapes them, they cannot be addressed safely).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-}"
[ -n "$MODE" ] && shift
case "$MODE" in report | apply | check) ;; -h | --help | "") sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;; *) echo "usage: home-acl.sh report|apply|check [options]" >&2; exit 2 ;; esac

ROOT="${HOME:-}" OWNER="$(id -un)" STATE=/var/lib/usr-managed MANAGED="" KEEP="$HERE/home-acl-keep.txt"
SECRETS="$HERE/secret-paths.txt" REPO="$(cd "$HERE/../.." && pwd)" MARKER="" EXAMPLES=8 DEPTH=5 BUDGET=10
managed_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift ;;
    --owner) OWNER="$2"; shift ;;
    --state) STATE="$2"; shift ;;
    --managed) MANAGED="$2"; managed_set=1; shift ;;
    --keep) KEEP="$2"; shift ;;
    --secrets) SECRETS="$2"; shift ;;
    --repo) REPO="$2"; shift ;;
    --marker) MARKER="$2"; shift ;;
    --examples) EXAMPLES="$2"; shift ;;
    --depth) DEPTH="$2"; shift ;;
    --budget) BUDGET="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
ROOT="${ROOT%/}"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "home-acl: root directory missing: $ROOT" >&2; exit 2; }
[ -n "$MARKER" ] || MARKER="$ROOT/.local/state/usr/home-acl-cleanup"
if [ "$managed_set" -eq 0 ] && [ -r "$HERE/lib.sh" ]; then
  # shellcheck source=infrastructure/users/lib.sh
  source "$HERE/lib.sh"
  MANAGED="$(managed_users | paste -sd' ' -)"
fi
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# ── classification: getfacl -p -s output on stdin -> TSV  class, top-level, kinds, group-fix, path ──────────────────────
# class: STRIP | KEEP-named | KEEP-excluded | KEEP-foreign | SKIP-oddname; group-fix: the effective group permission to set
# after `setfacl -b` (only when it differs from the mask that the mode bits show), else `-`.
classify() {
  awk -v root="$ROOT" -v own="$OWNER" -v managed="$MANAGED" -v keepfile="$KEEP" '
    function andperm(a, b,   i, r, ca, cb) {
      r = ""
      for (i = 1; i <= 3; i++) { ca = substr(a, i, 1); cb = substr(b, i, 1); r = r ((ca != "-" && cb != "-") ? ca : "-") }
      return r
    }
    function kept(rel,   p) {
      p = rel
      while (p != "") {
        if (p in keep) return 1
        if (index(p, "/") == 0) break
        sub(/\/[^\/]*$/, "", p)
      }
      return 0
    }
    function flush(   cls, rel, top, fix, eff) {
      if (path == "") return
      rel = (substr(path, 1, length(root) + 1) == root "/") ? substr(path, length(root) + 2) : path
      top = rel; sub(/\/.*/, "", top); if (path == root) top = "."
      if (path ~ /\\/) cls = "SKIP-oddname"
      else if (named_other) cls = "KEEP-named"
      else if (kept(rel)) cls = "KEEP-excluded"
      else if (owner != own) cls = "KEEP-foreign"
      else cls = "STRIP"
      fix = "-"
      if (has_mask && grp != "") { eff = andperm(grp, mask); if (eff != mask) fix = eff }
      printf "%s\t%s\t%s\t%s\t%s\n", cls, top, (sig == "" ? "-" : sig), fix, path
    }
    BEGIN {
      n = split(managed, m, " "); for (i = 1; i <= n; i++) mg[m[i]] = 1
      while ((getline l < keepfile) > 0) { sub(/#.*/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l); sub(/\/+$/, "", l); if (l != "") keep[l] = 1 }
    }
    /^# file: / { flush(); path = substr($0, 9); owner = ""; named_other = 0; sig = ""; grp = ""; mask = ""; has_mask = 0; next }
    /^# owner: / { owner = substr($0, 10); next }
    /^# group: / || /^$/ { next }
    {
      line = $0; sub(/[ \t]+#effective:[rwx-]+$/, "", line)
      nf = split(line, f, ":"); d = 0
      if (f[1] == "default") { d = 1; for (i = 1; i < nf; i++) f[i] = f[i + 1]; nf-- }
      tag = f[1]; qual = f[2]; perm = f[3]
      if ((tag == "user" || tag == "group") && qual != "") {
        if (tag == "user" && (qual in mg)) tok = (d ? "def" : "acc") ":managed-user"
        else { named_other = 1; tok = (d ? "def" : "acc") ":named-" tag }
      } else if (tag == "mask") {
        tok = (d ? "def" : "acc") ":mask"
        if (!d) { has_mask = 1; mask = perm }
      } else {
        if (!d) { if (tag == "group") grp = perm; next }
        tok = "def:" tag
      }
      if (index("+" sig "+", "+" tok "+") == 0) sig = (sig == "" ? tok : sig "+" tok)
    }
    END { flush() }'
}

# ── the walk ────────────────────────────────────────────────────────────────────────────────────────────────────────────
# secret locations: "KIND<TAB>ABSOLUTE-PATH" (KIND full = everything below must be owner-only, top = the top path only)
secret_locations() {
  local p kind abs
  [ -r "$SECRETS" ] || return 0
  while IFS= read -r p; do
    p="${p%%[[:space:]]#*}"
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    case "$p" in '' | '#'*) continue ;; esac
    kind=top
    case "$p" in
      *" full") kind=full p="${p% full}" ;;
      *" top") p="${p% top}" ;;
    esac
    case "$p" in
      @REPO@/*) abs="$REPO/${p#@REPO@/}" ;;
      /*) abs="$p" ;;
      *) abs="$ROOT/$p" ;;
    esac
    printf '%s\t%s\n' "$kind" "$abs"
  done <"$SECRETS"
}

# paths whose ACL is read: apply/report = the whole tree; check = the first DEPTH levels + the secret locations in full
emit_paths() {
  if [ "$MODE" = check ]; then
    find "$ROOT" -xdev -maxdepth "$DEPTH" ! -type l -print0 2>/dev/null
    local kind abs
    while IFS=$'\t' read -r kind abs; do
      [ -e "$abs" ] && [ ! -L "$abs" ] || continue
      if [ "$kind" = full ]; then find "$abs" -xdev ! -type l -print0 2>/dev/null; else printf '%s\0' "$abs"; fi
    done < <(secret_locations)
  else
    find "$ROOT" -xdev ! -type l -print0 2>/dev/null
  fi
}

# scan: raw getfacl output in $W/raw, classification in $W/classes.tsv; returns 124 when the time budget was hit (check)
scan() {
  local rc=0
  if [ "$MODE" = check ]; then
    timeout "$BUDGET" bash -c 'emit_paths | xargs -0 -r getfacl -p -s 2>/dev/null' >"$W/raw" 2>/dev/null || rc=$?
  else
    emit_paths | xargs -0 -r getfacl -p -s >"$W/raw" 2>/dev/null || true
  fi
  classify <"$W/raw" >"$W/classes.tsv"
  return "$rc"
}
export -f emit_paths secret_locations
export ROOT DEPTH SECRETS REPO MODE

# secret paths wider than owner-only: "mode<TAB>type<TAB>path". apply/report: everything below every location (the owner's
# files only); check: `full` locations below, `top` locations only the path itself.
widened() {
  local kind abs
  while IFS=$'\t' read -r kind abs; do
    [ -e "$abs" ] && [ ! -L "$abs" ] || continue
    if [ "$MODE" = check ] && [ "$kind" = top ]; then
      find "$abs" -xdev -maxdepth 0 ! -type l -perm /077 -printf '%m\t%y\t%p\n' 2>/dev/null
    elif [ "$MODE" = check ]; then
      find "$abs" -xdev ! -type l -perm /077 -printf '%m\t%y\t%p\n' 2>/dev/null
    else
      find "$abs" -xdev -user "$OWNER" ! -type l -perm /077 -printf '%m\t%y\t%p\n' 2>/dev/null
    fi
  done < <(secret_locations)
}
newmode() { # newmode MODE: the mode with the group and other bits removed
  printf '%o' $((8#$1 & 8#700))
}
rel() { local p="$1"; case "$p" in "$ROOT"/*) printf '~/%s' "${p#"$ROOT"/}" ;; *) printf '%s' "$p" ;; esac; }

count_class() { awk -F'\t' -v c="$1" '$1 == c { n++ } END { print n + 0 }' "$W/classes.tsv"; }
examples_of() { # examples_of CLASS N: "path  (kinds)" lines
  awk -F'\t' -v c="$1" -v n="$2" '$1 == c && k < n { k++; print "    " $5 "   [" $3 "]" }' "$W/classes.tsv"
}

report_acl() {
  local total strip named excl foreign odd
  total="$(wc -l <"$W/classes.tsv")"
  strip="$(count_class STRIP)" named="$(count_class KEEP-named)" excl="$(count_class KEEP-excluded)"
  foreign="$(count_class KEEP-foreign)" odd="$(count_class SKIP-oddname)"
  printf 'extended ACLs under %s: %s paths (%s unintended, to strip)\n' "$ROOT" "$total" "$strip"
  if [ "$total" -gt 0 ]; then
    echo "  by kind of entries (extended entries only; the base user/group/other entries are not counted):"
    awk -F'\t' '{ c[$1 "  " $3]++ } END { for (k in c) printf "    %7d x %s\n", c[k], k }' "$W/classes.tsv" | sort -rn | sed -n '1,12p'
    echo "  by top-level path (unintended):"
    awk -F'\t' '$1 == "STRIP" { c[$2]++ } END { for (k in c) printf "    %7d x %s\n", c[k], k }' "$W/classes.tsv" | sort -rn | sed -n '1,15p'
    [ "$strip" -gt 0 ] && { echo "  examples (unintended):"; examples_of STRIP "$EXAMPLES"; }
    [ "$named" -gt 0 ] && { echo "  KEPT, a named entry of somebody else ($named):"; examples_of KEEP-named "$EXAMPLES"; }
    [ "$excl" -gt 0 ] && { echo "  KEPT, listed in $(basename "$KEEP") ($excl):"; examples_of KEEP-excluded "$EXAMPLES"; }
    [ "$foreign" -gt 0 ] && { echo "  KEPT, owned by another user ($foreign):"; examples_of KEEP-foreign "$EXAMPLES"; }
    [ "$odd" -gt 0 ] && { echo "  SKIPPED, backslash in the name ($odd):"; examples_of SKIP-oddname "$EXAMPLES"; }
  fi
}

report_modes() {
  local n kind abs shown=0 m t p limit
  [ -r "$SECRETS" ] || { echo "no secret-location list ($SECRETS)"; return 0; }
  widened >"$W/wide.tsv"
  n="$(wc -l <"$W/wide.tsv")"
  printf 'secret locations wider than owner-only: %s paths\n' "$n"
  while IFS=$'\t' read -r kind abs; do
    if [ ! -e "$abs" ] && [ ! -L "$abs" ]; then continue; fi
    [ -L "$abs" ] && { printf '  skipped (symlink, the target is not followed): %s\n' "$(rel "$abs")"; continue; }
    shown="$(awk -F'\t' -v a="$abs" '$3 == a || index($3, a "/") == 1 { k++ } END { print k + 0 }' "$W/wide.tsv")"
    [ "$shown" -gt 0 ] || continue
    printf '  %s  (%s, %s paths wider)\n' "$(rel "$abs")" "$kind" "$shown"
    limit=$([ "$kind" = full ] && echo 100000 || echo 25)
    awk -F'\t' -v a="$abs" '$3 == a || index($3, a "/") == 1' "$W/wide.tsv" | sed -n "1,${limit}p" | while IFS=$'\t' read -r m t p; do
      printf '      %s -> %s  %s\n' "$m" "$(newmode "$m")" "$(rel "$p")"
    done
    [ "$shown" -gt "$limit" ] && printf '      ... %s more below it (same rule: group and other bits removed)\n' $((shown - limit))
  done < <(secret_locations)
  while IFS=$'\t' read -r kind abs; do
    [ -e "$abs" ] || [ -L "$abs" ] || printf '  absent (nothing to do): %s\n' "$(rel "$abs")"
  done < <(secret_locations)
}

# ── actions ────────────────────────────────────────────────────────────────────────────────────────────────────────────
apply_acl() {
  local strip stamp f eff n_fix=0
  strip="$(count_class STRIP)"
  [ "$strip" -gt 0 ] || { echo "unchanged: no unintended extended ACL under $ROOT"; return 0; }
  stamp="$(date +%Y%m%d-%H%M%S)"
  install -d -m 700 "$STATE"
  gzip -c "$W/raw" >"$STATE/home-acl-before-$stamp.txt.gz"
  chmod 600 "$STATE/home-acl-before-$stamp.txt.gz"
  echo "before-state (getfacl of every path that carried an ACL): $STATE/home-acl-before-$stamp.txt.gz"
  awk -F'\t' '$1 == "STRIP" { p = $0; sub(/^([^\t]*\t){4}/, "", p); printf "%s%c", p, 0 }' "$W/classes.tsv" >"$W/strip.lst"
  xargs -0 -r setfacl -b -- <"$W/strip.lst" 2>"$W/setfacl.err" || echo "warning: some paths could not be changed (setfacl -b): $(head -c 300 "$W/setfacl.err")" >&2
  # the group bits showed the old mask: where the old group entry was narrower, set the effective permission (never wider)
  for eff in $(awk -F'\t' '$1 == "STRIP" && $4 != "-" { print $4 }' "$W/classes.tsv" | sort -u); do
    f="$W/fix.$eff"
    awk -F'\t' -v e="$eff" '$1 == "STRIP" && $4 == e { p = $0; sub(/^([^\t]*\t){4}/, "", p); printf "%s%c", p, 0 }' "$W/classes.tsv" >"$f"
    xargs -0 -r chmod "g=${eff//-/}" -- <"$f" 2>/dev/null || true
    n_fix=$((n_fix + $(tr -cd '\0' <"$f" | wc -c)))
  done
  echo "stripped: $strip paths (setfacl -b); group bits set to the effective permission on $n_fix of them"
}

apply_modes() {
  local n stamp
  [ -r "$SECRETS" ] || return 0
  widened >"$W/wide.tsv"
  n="$(wc -l <"$W/wide.tsv")"
  [ "$n" -gt 0 ] || { echo "unchanged: every secret location is owner-only"; return 0; }
  stamp="$(date +%Y%m%d-%H%M%S)"
  install -d -m 700 "$STATE"
  awk -F'\t' '{ print $1 "\t" $3 }' "$W/wide.tsv" >"$STATE/secret-modes-before-$stamp.txt"
  chmod 600 "$STATE/secret-modes-before-$stamp.txt"
  awk -F'\t' '{ printf "%s%c", $3, 0 }' "$W/wide.tsv" | xargs -0 -r chmod go-rwx --
  echo "tightened: $n secret paths (group and other bits removed); before-modes: $STATE/secret-modes-before-$stamp.txt"
}

write_marker() {
  install -d -m 755 "$(dirname "$MARKER")" 2>/dev/null || true
  printf '%s\n' "home-acl cleanup ran $(date -Is)" >"$MARKER"
  if [ "$EUID" -eq 0 ]; then chown "$OWNER:$(id -gn "$OWNER")" "$MARKER" "$(dirname "$MARKER")" 2>/dev/null || true; fi
}

case "$MODE" in
  report)
    scan
    report_acl
    report_modes
    printf 'RESULT strip=%s tighten=%s\n' "$(count_class STRIP)" "$(wc -l <"$W/wide.tsv")"
    ;;
  apply)
    scan
    report_acl
    apply_acl
    apply_modes
    write_marker
    printf 'RESULT strip=%s tighten=%s\n' "$(count_class STRIP)" "$(wc -l <"$W/wide.tsv" 2>/dev/null || echo 0)"
    ;;
  check)
    partial=0
    scan || partial=1
    widened >"$W/wide.tsv"
    printf 'acl_count=%s\n' "$(count_class STRIP)"
    printf 'acl_examples=%s\n' "$(awk -F'\t' '$1 == "STRIP" && k < 3 { k++; p = $5; sub("^" ENVIRON["ROOT"] "/", "~/", p); printf "%s%s", (k > 1 ? ", " : ""), p }' "$W/classes.tsv")"
    printf 'mode_count=%s\n' "$(wc -l <"$W/wide.tsv")"
    printf 'mode_examples=%s\n' "$(awk -F'\t' 'k < 3 { k++; p = $3; sub("^" ENVIRON["ROOT"] "/", "~/", p); printf "%s%s %s", (k > 1 ? ", " : ""), p, $1 }' "$W/wide.tsv")"
    printf 'partial=%s\n' "$partial"
    printf 'marker=%s\n' "$([ -e "$MARKER" ] && echo 1 || echo 0)"
    ;;
esac
