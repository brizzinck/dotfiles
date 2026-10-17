# browsers/

Settings that cannot be stowed because they live inside a flatpak sandbox or inside the browser.

| File | What | How it gets applied |
|---|---|---|
| `zen/user.js` | Zen prefs (memory, cache) | `browsers/apply.sh` (called by `install.sh`) |
| `chrome/chrome-flags.conf` | Chrome flags (1 GiB disk cache) | `browsers/apply.sh` |
| `vimium-c.json` | Vimium C settings: ua/ru `mapKey`, YouTube pass keys, mail/docs exclusions, Everforest look | by hand, see below |
| `vimium-c-mapkey.txt` | the `mapKey` block, generated from `.config/layout/keymap.tsv` | `layout.py gen vimium` |
| `vimium-c-build.py` | builds `vimium-c.json` from the mapKey block and the palette CSS | `python3 browsers/vimium-c-build.py` |

## Vimium C in Zen (owner steps, once)

Zen is a flatpak and extensions are installed by the owner; nothing here touches the running browser or its profile.

1. `about:addons` > Extensions: **disable (or remove) Vimium and vim-navigation** (they duplicate Vimium C and fight over the same keys).
   Keep **Vimium C** (enabled).
2. Vimium C > Options (the extension's own options page) > **Backup and restore > Import settings** > pick
   `~/dotfiles/browsers/vimium-c.json`. Importing replaces every other stored option with its default: press **Export settings** first
   if you want a way back.
3. Reload an open page. Check: `f` shows green-framed hints, `J` / `K` switch tabs, `o` opens the Vomnibar, and with the
   ua or ru layout active the same keys work (`а` = `f`, `о` = `j`, ...).

What the file sets:

- **Keys**: Vimium C's defaults stay (`j k h l gg G d u f F H L J K x X o O b B T yy yf p P gi gs / n N v V`). Only additions:
  the Cyrillic `mapKey` block (`vimium-c-mapkey.txt`: every non-ASCII character of the ua and ru layouts is translated to the
  us key of the same physical key; the `.` / `,` of the ru slash key are left alone, as everywhere in this setup).
  **The Cyrillic characters in that block are functional data, not text.**
- **Exclusions**: `https://www.youtube.com/` passes `f m k j l c t i <space>` to the page (player keys); Gmail, Google Docs,
  Outlook (live, office, office365) and Proton Mail have Vimium C switched off. So has the generated keymap page
  (`file:///.../.cache/keymap/`, opened by `SUPER+SHIFT+/`; regex `^file:///[^?#]*/\.cache/keymap/`): it has its own vim keys.
- **Look**: link hints, HUD, find bar and Vomnibar in the Everforest palette (`themes/palette/templates/vimium-c.css.tmpl`,
  black variant). For the night variant: `python3 browsers/vimium-c-build.py --variant night`, then import again.

After changing the layout table, the palette or the lists in `vimium-c-build.py`:

```bash
cd ~/dotfiles
PYTHONPYCACHEPREFIX=/tmp/pycache python3 .config/layout/layout.py gen vimium
PYTHONPYCACHEPREFIX=/tmp/pycache python3 themes/palette/render.py
PYTHONPYCACHEPREFIX=/tmp/pycache python3 browsers/vimium-c-build.py          # --check exits 1 when stale
```

## Zen shortcuts (by hand, Settings > Keyboard Shortcuts)

These work on `about:` pages and the sidebar, where extensions cannot. Check the dialog for conflicts first (split view uses
Ctrl+Alt+H/V/G/U).

- Next / previous workspace: `Ctrl+Alt+J` / `Ctrl+Alt+K` (defaults `Ctrl+Alt+E` / `Ctrl+Alt+Q`).
- Switch to workspace 1-4: `Ctrl+Alt+1` ... `Ctrl+Alt+4`. Compact mode stays on `Ctrl+Alt+C`.
- pdf.js has its own keys (`j`/`n` next page, `k`/`p` previous, `Ctrl+F`); `F7` is caret browsing where Vimium C cannot run.
