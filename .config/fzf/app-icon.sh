#!/usr/bin/env bash
# app-icon.sh CLASS: print the path of the best icon file for a window class / app id (empty when none).
# Looks the class up in the .desktop files (StartupWMClass, file name), then resolves the Icon= value in the icon
# theme directories (largest png or the scalable svg). Used by the window switcher preview. Results are cached in
# $XDG_RUNTIME_DIR/app-icons (one file per class).
set -u
class=${1:-}
[[ -n $class ]] || exit 0
cache="${XDG_RUNTIME_DIR:-/tmp}/app-icons"
mkdir -p "$cache" 2>/dev/null
key=${class//\//_}
if [[ -s $cache/$key ]]; then cat "$cache/$key"; exit 0; fi

apps=(/usr/share/applications "$HOME/.local/share/applications" /var/lib/flatpak/exports/share/applications "$HOME/.local/share/flatpak/exports/share/applications")
themes=("$HOME/.local/share/icons" /usr/share/icons/hicolor /usr/share/icons/Adwaita /usr/share/pixmaps /var/lib/flatpak/exports/share/icons "$HOME/.local/share/flatpak/exports/share/icons")

desktop=""
lc=${class,,}
for d in "${apps[@]}"; do
  [[ -d $d ]] || continue
  # by StartupWMClass, then by file name (org.telegram.desktop -> org.telegram.desktop.desktop)
  desktop=$(grep -ilx "StartupWMClass=$class" "$d"/*.desktop 2>/dev/null | head -1)
  [[ -n $desktop ]] && break
  for n in "$d/$class.desktop" "$d/$lc.desktop"; do
    if [[ -f $n ]]; then desktop=$n; break 2; fi
  done
done

icon=""
[[ -n $desktop ]] && icon=$(sed -n 's/^Icon=//p' "$desktop" | head -1)
icon=${icon:-$lc}

found=""
if [[ $icon == /* && -f $icon ]]; then
  found=$icon
else
  # largest raster up to 512 px first, then the scalable svg
  found=$(find "${themes[@]}" \( -name "$icon.png" -o -name "$icon.svg" \) 2>/dev/null |
    awk '{ s = 0; if (match($0, /\/[0-9]+x[0-9]+(@2)?\//)) { split(substr($0, RSTART + 1, RLENGTH - 2), a, "x"); s = a[1] + 0 } else if ($0 ~ /scalable/) s = 300; if (s > 0 && s <= 512) print s "\t" $0 }' |
    sort -rn | head -1 | cut -f2)
fi
[[ -n $found ]] && printf '%s\n' "$found" >"$cache/$key"
printf '%s' "$found"
[[ -n $found ]] && echo
exit 0
