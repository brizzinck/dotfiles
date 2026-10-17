// Runs the rendered polkit rule against a mock polkit: node polkit-rule-test.js RULE_FILE OWNER
// Exit 0 when every case behaves; prints one line per failed case.
const fs = require("fs");
const [file, owner] = process.argv.slice(2);
let rule = null;
const polkit = { Result: { YES: "YES", NO: "NO", NOT_HANDLED: "NOT_HANDLED" }, addRule(fn) { rule = fn; } };
new Function("polkit", fs.readFileSync(file, "utf8"))(polkit);
const act = (id, user) => ({ id, lookup: (k) => (k === "user" ? user : undefined) });
const subj = (user, local = true, active = true) => ({ user, local, active });
const HS = "org.freedesktop.machine1.host-shell";
const cases = [
  ["owner shell as td", act(HS, "td"), subj(owner), "YES"],
  ["owner shell as yc", act(HS, "yc"), subj(owner), "YES"],
  ["owner shell as root", act(HS, "root"), subj(owner), "NOT_HANDLED"],
  ["owner shell without a user", act(HS, undefined), subj(owner), "NOT_HANDLED"],
  ["owner shell as an unlisted user", act(HS, "aimcp"), subj(owner), "NOT_HANDLED"],
  ["owner shell as the owner", act(HS, owner), subj(owner), "NOT_HANDLED"],
  ["another user as td", act(HS, "td"), subj("mallory"), "NOT_HANDLED"],
  ["td as td", act(HS, "td"), subj("td"), "NOT_HANDLED"],
  ["owner remote session", act(HS, "td"), subj(owner, false, true), "NOT_HANDLED"],
  ["owner inactive session", act(HS, "td"), subj(owner, true, false), "NOT_HANDLED"],
  ["other action (pty login)", act("org.freedesktop.machine1.host-open-pty", "td"), subj(owner), "NOT_HANDLED"],
  ["other action (manage units)", act("org.freedesktop.systemd1.manage-units", "td"), subj(owner), "NOT_HANDLED"],
];
let bad = 0;
for (const [name, a, s, want] of cases) {
  const got = rule(a, s);
  if (got !== want) { bad++; console.log(`FAIL ${name}: want ${want}, got ${got}`); }
}
if (!rule) { console.log("FAIL: the file registered no rule"); bad++; }
process.exit(bad ? 1 : 0);
