-- Hyprland 0.56 (Lua). Palette: Everforest v2 (themes/palette); colours live in the generated fragments loaded in
-- the look section, so `theme black|night` recolours without touching this file.
-- Monitors are static rules (no polling script); lid.sh re-applies the panel rule from monitors.lua.

local home = os.getenv("HOME")
local hypr_dir = home .. "/.config/hypr"

-- ───────────────────────────── monitors ─────────────────────────────
-- With an HDMI monitor: HDMI on top at 0x0, the laptop panel below it.
-- Without: only eDP-1 is present and the offset is harmless.
-- The rules live in monitors.lua so lid.sh can re-enable the panel from the same data.
for _, rule in ipairs(dofile(hypr_dir .. "/monitors.lua")) do
    hl.monitor(rule)
end

-- ───────────────────────────── programs ─────────────────────────────
local terminal = "ghostty"
local fileManagerTerminal = terminal .. " -e yazi"
local fileManagerGUI = "nemo"
local menu = "pkill rofi || rofi -show drun"
local editor = "nvim"
local browser = "flatpak run app.zen_browser.zen"
-- palette-driven vector wallpaper, one swaybg per output (scripts/wallpaper.sh renders the PNGs, see themes/palette/palette.md)
local wallpaper = "~/.config/hypr/scripts/wallpaper.sh apply"
-- Floating terminal for TUIs; matched by the float-tui window rule below
local tui = "ghostty --class=float.tui -e"
local scripts = "~/.config/hypr/scripts"
-- App binds (T Telegram, S YouTube Music, N Obsidian) are the pinned apps' left click: focus, repeat = next window, launch when closed.
local pinned = "~/.config/waybar/scripts/pinned.sh"

-- ───────────────────────────── autostart ────────────────────────────
-- hyprland.start fires once per session (not on reload).
-- The marker (per Hyprland instance, in the runtime dir) keeps a `hyprctl reload full-reset` from starting everything twice.
local instance = os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or "unknown"
local autostart_marker = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/hypr/" .. instance .. "/autostart-done"
hl.on("hyprland.start", function()
    local seen = io.open(autostart_marker, "r")
    if seen then
        seen:close()
        return
    end
    local mark = io.open(autostart_marker, "w")
    if mark then
        mark:write("1")
        mark:close()
    end
    -- pointer: the hl.env calls below already reach the cursor manager on a clean start (Hyprland v0.56.2 creates it in
    -- CCompositor::initServer after Config::mgr()->init(), and libhyprcursor / CXCursorManager read HYPRCURSOR_THEME,
    -- XCURSOR_THEME and the *_SIZE variables themselves), so `setcursor` is a belt-and-braces step for a compositor that
    -- came up with a different theme (greetd -> hypr-login -> start-hyprland). It must not run as the very first command: the
    -- autostart fires before the IPC loop runs, so cursor-apply --boot waits until hyprctl answers, applies gsettings +
    -- `hyprctl setcursor`, retries once and logs to the journal (journalctl -t cursor-apply).
    hl.exec_cmd("~/.local/bin/cursor-apply --boot")
    -- palette link first (black when missing): waybar, dunst, rofi, swayosd read ~/.local/state/theme/current
    hl.exec_cmd("~/.local/bin/theme init")
    hl.exec_cmd("~/.config/waybar/scripts/bar.sh init; ~/.config/waybar/scripts/waybar-run.sh & hypridle")
    hl.exec_cmd("systemctl --user start hyprpolkitagent")
    hl.exec_cmd("~/.local/bin/usr clipboard-acl")
    hl.exec_cmd("dunst")
    hl.exec_cmd("swayosd-server")
    hl.exec_cmd("wl-paste --type text --watch cliphist -max-items 300 store")
    hl.exec_cmd("wl-paste --type image --watch cliphist -max-items 300 store")
    hl.exec_cmd("wl-clip-persist --clipboard regular")
    -- one master password per login: drop the rbw agent left over from the previous session (silent without rbw)
    hl.exec_cmd("~/.config/hypr/scripts/vault.sh session-start")
    hl.exec_cmd("~/.local/bin/fzf-menu --server-start")
    -- the lingering user manager starts pipewire + wireplumber at boot, before greetd gives this user seat0 (no /dev/snd ACL
    -- yet), so the sound cards can come up on profile off; audio-ensure restarts wireplumber once if that happened (journalctl -t audio-ensure)
    hl.exec_cmd("~/.local/bin/audio-ensure --boot")
    hl.exec_cmd("easyeffects --service-mode --hide-window")
    hl.exec_cmd("udiskie --automount --notify --no-tray")
    hl.exec_cmd("Telegram -startintray")
    hl.exec_cmd(wallpaper)
end)

-- A new monitor gets its bars from the config waybar parsed at startup. After a compact/full toggle that config is stale,
-- so bar.sh reloads waybar on hotplug, but only when a toggle left it stale (see .config/waybar/scripts/bar.sh).
hl.on("monitor.added", function()
    hl.exec_cmd("~/.config/waybar/scripts/bar.sh sync --if-stale")
    -- the new output gets its own render (native size) and swaybg
    hl.exec_cmd(wallpaper)
end)

-- The external monitor went away while the laptop panel was switched off (SUPER+CTRL+Delete): bring the panel back.
hl.on("monitor.removed", function()
    hl.exec_cmd(scripts .. "/lid.sh recover")
end)

-- A key press restores a dimmed panel even when hypridle missed its resume event (dim.sh keeps the saved value; the watcher it
-- starts also reacts to pointer movement and to a dead hypridle). The state file only exists while the panel is dimmed.
local dim_state = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/dim-saved"
hl.on("input.keyboard.key", function()
    local f = io.open(dim_state, "r")
    if f then
        f:close()
        hl.exec_cmd(scripts .. "/dim.sh restore")
    end
end)

-- ───────────────────────────── environment ──────────────────────────
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
-- Pointer: Everforest-Cursor (local package infrastructure/cursor, installed system-wide by apply-system.sh so flatpaks see it:
-- hyprcursor SVG build + XCursor build of one artwork). Until it is installed the config falls back to Bibata-Modern-Ice and
-- leaves HYPRCURSOR_THEME unset (a missing hyprcursor theme is never requested). Size 32 = 48 px on the 1.5 panel, 1:1.
local pointer_theme = "Bibata-Modern-Ice"
local function readable(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end
if readable("/usr/share/icons/Everforest-Cursor/manifest.hl") and readable("/usr/share/icons/Everforest-Cursor/cursors/left_ptr") then
    pointer_theme = "Everforest-Cursor"
    hl.env("HYPRCURSOR_THEME", pointer_theme)
end
hl.env("XCURSOR_THEME", pointer_theme)
hl.env("XCURSOR_SIZE", "32")
hl.env("HYPRCURSOR_SIZE", "32")

-- ───────────────────────────── input ────────────────────────────────
-- resolve_binds_by_sym stays at its default (false): binds match layout 1 (us) on ua and ru too
hl.config({
    input = {
        kb_layout = "us,ua,ru",
        kb_options = "grp:caps_toggle",
        follow_mouse = 1,
        sensitivity = -0.1,
        -- faster key repeat for hjkl and backspace: 40 per second after 250 ms (default 25 / 600)
        repeat_rate = 40,
        repeat_delay = 250,
        touchpad = {
            natural_scroll = true,
            clickfinger_behavior = true, -- two-finger click = right click, three fingers = middle
        },
    },
})
-- three-finger swipe changes the workspace
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

-- ───────────────────────────── look ─────────────────────────────────
-- Colours (borders, groups, background) come from the palette: the black fragment is always there as the
-- fallback, the second one is the active variant (~/.local/state/theme/current, flipped by `theme`). A missing
-- or broken fragment is skipped (pcall), black stays in place and `theme init` repairs the link.
for _, path in ipairs({
    home .. "/dotfiles/themes/generated/black/hyprland.lua",
    home .. "/.local/state/theme/current/hyprland.lua",
}) do
    local ok, err = pcall(dofile, path)
    if not ok then
        hl.exec_cmd("notify-send -a hyprland 'Theme fragment skipped' '" .. tostring(err):gsub("'", "") .. "'")
    end
end

-- The pointer hides after 5 s idle; mouse mode (keyboard-driven pointer) turns that off while it is active.
local cursor_idle_timeout = 5

hl.config({
    general = {
        -- Crisp edges on both outputs: Hyprland scales these by the monitor scale and rounds every box to whole
        -- pixels. The border is round(border_size * scale) = 2 px on HDMI-A-1 (1.0) and 3 px on eDP-1 (1.5); the
        -- gaps are even so they stay whole pixels at 1.5 (gaps_in 3 would be 4.5 px). Odd border sizes round up
        -- (1 -> 2 px, 3 -> 5 px at 1.5), so keep the border even.
        gaps_in = 4,
        gaps_out = 4,
        border_size = 2,
        resize_on_border = true,

        layout = "dwindle",
        allow_tearing = false,
    },

    decoration = {
        rounding = 6,                   -- 6 / 9 px radius (outer edge 8 / 12 px), whole pixels on both outputs
        rounding_power = 2,             -- true circle: no border correction offset, smoothest antialiasing

        shadow = {
            enabled = false,            -- no glow around the focused window
        },

        blur = {
            enabled = false,            -- everything is opaque black
        },

        dim_inactive = true,            -- on black only text dims
        dim_strength = 0.10,            -- 0.15 turned the new fg khaki (palette-v2 section 5.3)
        dim_special = 0.5,
    },

    group = {
        groupbar = {
            font_family = "JetBrainsMono Nerd Font",
            font_size = 11,
            height = 18,
            indicator_height = 2,
            rounding = 4,
            gradients = false,
        },
    },

    binds = {
        hide_special_on_workspace_change = true, -- the drop-down terminal and the notes close when you switch workspace
    },

    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        -- safety net: any key or pointer movement wakes a panel that hypridle switched off (dpms off at 1200 s), even when the
        -- on-resume listener of hypridle did not run (a black panel with the screensaver still up)
        key_press_enables_dpms = true,
        mouse_move_enables_dpms = true,
        -- fzf-menu relies on it: a one-shot menu terminal exits after its menu, and the then empty special workspace must close by
        -- itself (the window closes like any window, with its own animation, instead of a workspace toggle)
        close_special_on_empty = true,
    },

    cursor = {
        inactive_timeout = cursor_idle_timeout,
        hide_on_key_press = true,
    },

    render = {
        direct_scanout = 2,             -- fullscreen video/games skip composition
    },

    xwayland = {
        force_zero_scaling = true,      -- no X11 app is in regular use; crisp at scale 1.5
    },

    animations = {
        enabled = true,
    },

    dwindle = {
        preserve_split = true,
    },
})

-- Fast, not off: ~150-200 ms at 120 Hz
hl.curve("snap", { type = "bezier", points = { { 0.2, 0.9 }, { 0.1, 1 } } })
hl.animation({ leaf = "global",           enabled = true, speed = 2,   bezier = "snap" })
hl.animation({ leaf = "windows",          enabled = true, speed = 1.5, bezier = "snap", style = "popin 92%" })
hl.animation({ leaf = "windowsOut",       enabled = true, speed = 1.2, bezier = "snap", style = "popin 92%" })
hl.animation({ leaf = "border",           enabled = true, speed = 2,   bezier = "snap" })
hl.animation({ leaf = "fade",             enabled = true, speed = 1.5, bezier = "snap" })
hl.animation({ leaf = "layers",           enabled = true, speed = 1.2, bezier = "snap", style = "fade" })
hl.animation({ leaf = "workspaces",       enabled = true, speed = 1.8, bezier = "snap", style = "slide" })
-- Special workspaces (fzf-menu server, scratch windows): plain in-place fade, no
-- movement. "slidevert" slid the floating menu up while it faded out on every close.
-- 1.3 ds in (~130 ms) / 1.0 ds out (~100 ms); the snap curve has no overshoot (y <= 1).
hl.animation({ leaf = "specialWorkspaceIn",  enabled = true, speed = 1.3, bezier = "snap", style = "fade" })
hl.animation({ leaf = "specialWorkspaceOut", enabled = true, speed = 1.0, bezier = "snap", style = "fade" })

-- ───────────────────────────── workspaces and rules ─────────────────
-- Smart borders: no frame and no gaps for a lone tiled window
hl.workspace_rule({ workspace = "w[tv1]", gaps_out = 0, gaps_in = 0 })
hl.window_rule({
    name = "smart-borders",
    match = { float = false, workspace = "w[tv1]" },
    border_size = 0,
    rounding = 0,
})

-- Drop-down terminal: SUPER+Z toggles it, tmux session "scratch" is attached or created.
-- (hyprlang added the [workspace ...] prefix to on-created-empty itself; Lua takes the command verbatim.)
hl.workspace_rule({
    workspace = "special:term",
    gaps_out = 48,
    on_created_empty = "[workspace special:term] ghostty -e tmux new-session -A -s scratch",
})
-- Notes scratchpad: SUPER+SHIFT+Z toggles nvim on ~/notes/scratch.md
hl.workspace_rule({
    workspace = "special:notes",
    gaps_out = 48,
    on_created_empty = "[workspace special:notes] ghostty -e sh -c 'mkdir -p ~/notes; exec nvim ~/notes/scratch.md'",
})

-- Floating TUIs (tui)
hl.window_rule({
    name = "float-tui",
    match = { class = "^(float\\.tui)$" },
    float = true,
    center = true,
    size = { "monitor_w*0.6", "monitor_h*0.65" },
})

-- Telegram send confirmation (infrastructure/mcp/confirm: the tgconfirm broker runs ghostty as ITS OWN user with this class and a
-- curses popup inside). Centered, pinned and focus-locked while it is open; no_screen_share makes grim / screencopy / the
-- portal see a black box, so the per-message code cannot be read from a screenshot by an agent.
hl.window_rule({
    name = "float-confirm",
    match = { class = "^(float\\.confirm)$" },
    float = true,
    center = true,
    pin = true,
    stay_focused = true,
    no_screen_share = true,
    size = { "monitor_w*0.5", "monitor_h*0.6" },
})

-- Edit anywhere (SUPER+CTRL+E, scripts/edit-anywhere.sh): a small floating nvim next to the pointer for text fields without vim.
-- The script places it with exec rules (a monitor-relative move clamped to the work area); this rule is the float + size fallback.
hl.window_rule({
    name = "float-edit",
    match = { class = "^(float\\.edit)$" },
    float = true,
    size = { 900, 360 },
})

-- Hidden menu terminals of fzf-menu (~/.local/bin/fzf-menu --server a|b): ONE-SHOT. Each terminal serves exactly one menu and
-- exits, so a menu closes like any window (popin + fade of its last frame, the empty special workspace closes by itself,
-- misc.close_special_on_empty) instead of a workspace toggle with a blank terminal in it. Opening stays hot (~40 ms): a standby
-- terminal waits on the OTHER slot's special workspace (menu-a / menu-b) and takes the next request.
-- Fallback if a menu still shows motion on close: add `no_anim = true,` to both rules (menus then vanish instantly).
for _, slot in ipairs({ "a", "b" }) do
    hl.window_rule({
        name = "fzf-menu-server-" .. slot,
        match = { class = "^(float\\.tui)$", title = "^(fzf-menu-server-" .. slot .. ")$" },
        workspace = "special:menu-" .. slot .. " silent",
        -- no_anim = true,  -- fallback: menus vanish instantly
    })
end

-- Picture-in-picture (Zen/Firefox "Picture-in-Picture", Chromium "Picture in picture"): small, pinned, top right, 16:9
hl.window_rule({
    name = "pip",
    match = { title = "^(Picture.?in.?[Pp]icture)$" },
    float = true,
    pin = true,
    size = { 600, 338 },
    keep_aspect_ratio = true,
    border_size = 0,
    move = { "monitor_w-window_w-40", "monitor_h*0.04" },
})

-- Portal file chooser (GTK) and similar dialogs: floating and centred instead of a tile that resizes everything
hl.window_rule({
    name = "float-portal-dialog",
    match = { class = "^(xdg-desktop-portal-gtk)$" },
    float = true,
    center = true,
})

-- QR code viewer (imv): small floating window
hl.window_rule({
    name = "float-imv",
    match = { class = "^(imv)$" },
    float = true,
    center = true,
    size = { 560, 600 },
})

-- pinentry (rbw master password prompt): small floating dialog instead of a tiled window
hl.window_rule({
    name = "float-pinentry",
    match = { class = "^(org\\.gnupg\\.pinentry-.*|pinentry.*)$" },
    float = true,
    center = true,
    size = { 520, 170 },
    stay_focused = true,
})

-- Camoufox (skw anti-detect browser): keep the persona window size so the page fills the window
hl.window_rule({
    name = "float-camoufox",
    match = { class = "^(camoufox)$" },
    float = true,
    center = true,
})

-- Bitwarden desktop app (Electron, class Bitwarden): a centered floating window instead of a full-width tile.
-- It is started silently (no focus) at login when the SSH agent flag is on; vault.sh app opens it on demand.
hl.window_rule({
    name = "float-bitwarden",
    match = { class = "^([Bb]itwarden|com\\.bitwarden\\.desktop)$" },
    float = true,
    center = true,
    size = { "monitor_w*0.5", "monitor_h*0.75" },
})

hl.layer_rule({
    name = "rofi",
    match = { namespace = "^(rofi)$" },
    no_anim = true,
    dim_around = true,
})

-- Chrome-vs-hypridle idle exemption lives in hypridle.conf (condition_cmd -> idle-allowed.sh there);
-- the windowrule `idleinhibit` was removed from Hyprland in 0.53+.

-- Binds: hl.bind(keys, dispatcher, { description = ..., repeating = true, locked = true, mouse = true })
-- (descriptions feed the SUPER+/ cheatsheet, the hub and docs/keymap.md; keep them free of commas).
local mainMod = "SUPER"

-- Bind registry. A Lua bind shows up as dispatcher "__lua" in `hyprctl binds -j`, so its action cannot be read back from
-- the listing. Wrapping hl.bind records every dispatcher under "<submap>|<mods+key>" (mods in SUPER CTRL ALT SHIFT order,
-- lower case: the text the hub builds from the live table), and `hyprctl eval 'df_bind_run("SUPER+Return")'` replays one.
-- The hub uses it for its keybind rows and the leader menu. Global on purpose: hyprctl eval shares this Lua state.
DF_BINDS = {}
local bind_submap = ""
local MOD_ORDER = { "SUPER", "CTRL", "ALT", "SHIFT" }

local function bind_label(keys)
    local parts = {}
    for part in keys:gmatch("[^+]+") do
        parts[#parts + 1] = part:match("^%s*(.-)%s*$")
    end
    local key = table.remove(parts)
    local present = {}
    for _, mod in ipairs(parts) do
        mod = mod:upper()
        present[mod == "CONTROL" and "CTRL" or mod] = true
    end
    local label = {}
    for _, mod in ipairs(MOD_ORDER) do
        if present[mod] then label[#label + 1] = mod end
    end
    label[#label + 1] = key
    return table.concat(label, "+"):lower()
end

local raw_bind, raw_define_submap = hl.bind, hl.define_submap
hl.bind = function(keys, dispatcher, opts)
    DF_BINDS[bind_submap .. "|" .. bind_label(keys)] = dispatcher
    return raw_bind(keys, dispatcher, opts)
end
hl.define_submap = function(name, reset_or_fn, fn)
    local body = fn or reset_or_fn
    local function tracked(...)
        local outer = bind_submap
        bind_submap = name
        local ok, err = pcall(body, ...)
        bind_submap = outer
        if not ok then error(err, 0) end
    end
    if fn then return raw_define_submap(name, reset_or_fn, tracked) end
    return raw_define_submap(name, tracked)
end

function df_bind_run(label)
    local dispatcher = DF_BINDS["|" .. tostring(label):lower()]
    if not dispatcher then
        hl.exec_cmd("notify-send -a hyprland -u low 'Keybind not found' '" .. tostring(label):gsub("'", "") .. "'")
        return
    end
    if type(dispatcher) == "function" then dispatcher() else hl.dispatch(dispatcher) end
end

-- Catch-all leave for the repeat modes (resize, mouse). Hyprland 0.55/0.56 runs a catchall bind next to the bind that
-- matched (hyprwm/Hyprland#15063) and also on a lone modifier press, so the callback acts only when none of the mode's own
-- keys or a modifier is held. Key codes are evdev + 8 (physical keys, independent of the active layout).
local EVDEV = {
    escape = 1, q = 16, y = 21, u = 22, r = 19, ["return"] = 28, space = 57, f = 33, m = 50,
    h = 35, j = 36, k = 37, l = 38, left = 105, right = 106, up = 103, down = 108,
    lctrl = 29, rctrl = 97, lshift = 42, rshift = 54, lalt = 56, ralt = 100, lsuper = 125, rsuper = 126,
}
local MODIFIER_KEYS = { "lctrl", "rctrl", "lshift", "rshift", "lalt", "ralt", "lsuper", "rsuper" }
local function leave_on_other_key(own_keys, leave)
    return function()
        for _, name in ipairs(own_keys) do
            if hl.is_key_down(EVDEV[name] + 8) then return end
        end
        for _, name in ipairs(MODIFIER_KEYS) do
            if hl.is_key_down(EVDEV[name] + 8) then return end
        end
        leave()
    end
end

-- Typing binds (wtype): the text must not start while the bind's own keys are still down. Hyprland combines the
-- modifiers of all keyboards, so a password typed under a held SUPER+CTRL would fire binds instead of typing. Polls every
-- 30 ms (3 s at most) until `own_keys` and every modifier are up, then runs cmd; gives up with a notification.
local function exec_when_keys_up(cmd, own_keys)
    local tries = 0
    local function poll()
        tries = tries + 1
        local down = false
        for _, name in ipairs(own_keys) do
            if hl.is_key_down(EVDEV[name] + 8) then down = true end
        end
        for _, name in ipairs(MODIFIER_KEYS) do
            if hl.is_key_down(EVDEV[name] + 8) then down = true end
        end
        if not down then
            hl.exec_cmd(cmd)
        elseif tries >= 100 then
            hl.exec_cmd("notify-send -a hyprland -u normal 'Nothing typed' 'Release the modifier keys and press the bind again'")
        else
            hl.timer(poll, { timeout = 30, type = "oneshot" })
        end
    end
    poll()
end

-- Mouse mode: the pointer must stay visible while the keyboard drives it. pointer.sh enters it only when wlrctl exists.
function df_mouse_mode(on)
    hl.config({ cursor = { hide_on_key_press = not on, inactive_timeout = on and 0 or cursor_idle_timeout } })
    hl.dispatch(hl.dsp.submap(on and "mouse" or "reset"))
end

-- --- apps ---
hl.bind("ALT + TAB", hl.dsp.window.cycle_next(), { description = "Cycle windows" })
hl.bind("ALT + SHIFT + TAB", hl.dsp.window.cycle_next({ next = false }), { description = "Cycle windows backwards" })
hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal .. " -e tmux new-session -s \"term-$(date +%s%N)\""), { description = "Terminal (new tmux session)" })
hl.bind(mainMod .. " + SHIFT + Return", hl.dsp.exec_cmd(terminal .. " -e tmux attach"), { description = "Terminal (attach tmux)" })
hl.bind(mainMod .. " + SHIFT + T", hl.dsp.exec_cmd("~/.local/bin/usr menu"), { description = "Terminal as a managed user (picker)" })
hl.bind(mainMod .. " + G", hl.dsp.exec_cmd(browser), { description = "Browser" })
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManagerTerminal), { description = "File manager (yazi)" })
hl.bind(mainMod .. " + SHIFT + E", hl.dsp.exec_cmd(fileManagerGUI), { description = "File manager (nemo)" })
hl.bind(mainMod .. " + space", hl.dsp.exec_cmd(menu), { description = "App launcher" })
hl.bind(mainMod .. " + T", hl.dsp.exec_cmd(pinned .. " click telegram"), { description = "Telegram" })
hl.bind(mainMod .. " + S", hl.dsp.exec_cmd(pinned .. " click ytm"), { description = "YouTube Music" })
hl.bind(mainMod .. " + N", hl.dsp.exec_cmd(pinned .. " click obsidian"), { description = "Obsidian" })
hl.bind(mainMod .. " + O", hl.dsp.exec_cmd(wallpaper .. " --force"), { description = "Reload wallpaper" })
hl.bind(mainMod .. " + B", hl.dsp.exec_cmd("~/.config/waybar/scripts/bar.sh mode toggle"), { description = "Bar compact or full" })
hl.bind(mainMod .. " + CTRL + B", hl.dsp.exec_cmd("~/.config/waybar/scripts/bar.sh hide toggle"), { description = "Hide or show the bar" })

-- --- session and system ---
hl.bind(mainMod .. " + Escape", hl.dsp.exec_cmd("lock-screen"), { description = "Lock screen (password; layout reset to us)" })
hl.bind(mainMod .. " + SHIFT + Escape", hl.dsp.exec_cmd(scripts .. "/powermenu.sh"), { description = "Power menu" })
hl.bind("XF86PowerOff", hl.dsp.exec_cmd(scripts .. "/powermenu.sh"), { description = "Power menu" })
hl.bind(mainMod .. " + SHIFT + U", hl.dsp.exec_cmd("~/.local/bin/sysup open"), { description = "System update (sysup: install everything now)" })
hl.bind(mainMod .. " + CTRL + I", hl.dsp.exec_cmd(scripts .. "/idle-toggle.sh"), { description = "Toggle idle (hypridle)" })
hl.bind(mainMod .. " + SHIFT + N", hl.dsp.exec_cmd("pkill -x hyprsunset || hyprsunset -t 4500; rm -f $XDG_RUNTIME_DIR/waybar-cache/toggles.json; pkill -o -u $(id -u) -RTMIN+8 -x waybar"), { description = "Toggle night light" })
hl.bind(mainMod .. " + X", hl.dsp.exec_cmd("dunstctl close"), { description = "Dismiss notification" })
hl.bind(mainMod .. " + SHIFT + X", hl.dsp.exec_cmd(scripts .. "/notif-history.sh"), { description = "Notification history (fzf)" })
hl.bind(mainMod .. " + CTRL + X", hl.dsp.exec_cmd("dunstctl set-paused toggle; rm -f $XDG_RUNTIME_DIR/waybar-cache/toggles.json; pkill -o -u $(id -u) -RTMIN+8 -x waybar"), { description = "Toggle do-not-disturb" })
hl.bind(mainMod .. " + ALT + X", hl.dsp.exec_cmd("dunstctl context"), { description = "Notification actions menu" })

-- --- TUIs and pickers ---
hl.bind(mainMod .. " + A", hl.dsp.exec_cmd(tui .. " wiremix"), { description = "Audio mixer (wiremix)" })
hl.bind(mainMod .. " + SHIFT + A", hl.dsp.exec_cmd(scripts .. "/audio-picker.sh"), { description = "Audio output/input picker" })
hl.bind(mainMod .. " + SHIFT + B", hl.dsp.exec_cmd(tui .. " bluetui"), { description = "Bluetooth (bluetui)" })
hl.bind(mainMod .. " + I", hl.dsp.exec_cmd(scripts .. "/wifi.sh"), { description = "Wi-Fi picker (fzf, nmcli)" })
hl.bind(mainMod .. " + D", hl.dsp.exec_cmd(tui .. " btop"), { description = "System monitor (btop)" })
hl.bind(mainMod .. " + P", hl.dsp.exec_cmd(terminal .. " -e ~/.config/tmux/scripts/sessionizer.sh"), { description = "Project sessions (tmux)" })
hl.bind(mainMod .. " + C", hl.dsp.exec_cmd(scripts .. "/clipboard.sh"), { description = "Clipboard history" })
hl.bind(mainMod .. " + SHIFT + C", hl.dsp.exec_cmd("hyprpicker -a"), { description = "Color picker" })
hl.bind(mainMod .. " + period", hl.dsp.exec_cmd(scripts .. "/emoji.sh"), { description = "Emoji picker" })
hl.bind(mainMod .. " + SHIFT + period", hl.dsp.exec_cmd(scripts .. "/snippets.sh"), { description = "Snippets picker" })
-- dictation (Voxtype): toggle, or hold F9 (the release bind has no description: it is the other half of the press bind and
-- would be a second row for the same key; it comes first so the bind registry keeps the press bind)
hl.bind("F9", hl.dsp.exec_cmd(scripts .. "/dictation.sh stop"), { release = true })
hl.bind("F9", hl.dsp.exec_cmd(scripts .. "/dictation.sh start"), { description = "Dictation: hold F9 to dictate" })
hl.bind(mainMod .. " + ALT + D", hl.dsp.exec_cmd(scripts .. "/dictation.sh toggle"), { description = "Dictation on or off (Voxtype)" })
hl.bind(mainMod .. " + ALT + SHIFT + D", hl.dsp.exec_cmd(scripts .. "/dictation.sh cycle"), { description = "Dictation: next language (ru uk en)" })
hl.bind(mainMod .. " + ALT + T", hl.dsp.exec_cmd(scripts .. "/reminder.sh set"), { description = "New reminder (25 tea or 14:30 standup)" })
hl.bind(mainMod .. " + CTRL + ALT + T", hl.dsp.exec_cmd(scripts .. "/reminder.sh list"), { description = "Reminders: list and cancel" })
hl.bind(mainMod .. " + CTRL + period", hl.dsp.exec_cmd(scripts .. "/transcode.sh"), { description = "Transcode a picture or video for sharing" })
hl.bind(mainMod .. " + CTRL + E", hl.dsp.exec_cmd(scripts .. "/edit-anywhere.sh open"), { description = "Edit anywhere: nvim at the pointer then paste (Ctrl+S)" })
hl.bind(mainMod .. " + CTRL + V", hl.dsp.exec_cmd(scripts .. "/paste-plain.sh"), { description = "Paste clipboard as plain text" })
hl.bind(mainMod .. " + ALT + V", hl.dsp.exec_cmd(scripts .. "/clipboard.sh --paste-last-image"), { description = "Paste last screenshot or image" })
hl.bind(mainMod .. " + CTRL + P", hl.dsp.exec_cmd(scripts .. "/vault.sh passwords"), { description = "Passwords (Bitwarden via rbw and fzf)" })
hl.bind(mainMod .. " + CTRL + O", hl.dsp.exec_cmd(scripts .. "/vault.sh totp"), { description = "2FA codes (copy the current code)" })
hl.bind(mainMod .. " + CTRL + SHIFT + P", hl.dsp.exec_cmd(scripts .. "/vault.sh browse"), { description = "Vault browser (every item, folders, trash)" })
hl.bind(mainMod .. " + CTRL + U", function() exec_when_keys_up(scripts .. "/vault.sh user-pass", { "u" }) end, { description = "Type the Linux password of the current user (terminal or polkit)" })
hl.bind(mainMod .. " + equal", hl.dsp.exec_cmd(scripts .. "/calc.sh"), { description = "Calculator (qalc)" })
-- AI hotkeys (ai-ask.sh): context goes to a Claude session in a floating terminal; the AI drafts, the owner sends (Telegram: only after the popup confirmation)
hl.bind(mainMod .. " + CTRL + A", hl.dsp.exec_cmd(scripts .. "/ai-ask.sh window"), { description = "AI: ask about the focused window" })
hl.bind(mainMod .. " + ALT + A", hl.dsp.exec_cmd(scripts .. "/ai-ask.sh selection"), { description = "AI: question about the selected text" })
hl.bind(mainMod .. " + CTRL + T", hl.dsp.exec_cmd(scripts .. "/ai-ask.sh telegram"), { description = "AI: Telegram digest (unread allowlisted chats)" })
hl.bind(mainMod .. " + slash", hl.dsp.exec_cmd("~/.local/bin/keymap menu"), { description = "Shortcut search (every key of every tool)" })
hl.bind(mainMod .. " + SHIFT + slash", hl.dsp.exec_cmd("~/.local/bin/keymap page"), { description = "Shortcut reference page (browser window)" })
hl.bind(mainMod .. " + M", hl.dsp.exec_cmd("~/.config/hub/hub open"), { description = "Utility hub (fzf)" })
hl.bind(mainMod .. " + semicolon", hl.dsp.exec_cmd("~/.config/hub/leader"), { description = "Leader menu (which-key)" })

-- --- capture ---
hl.bind("Print", hl.dsp.exec_cmd(scripts .. "/shot.sh region"), { description = "Screenshot region" })
hl.bind("SHIFT + Print", hl.dsp.exec_cmd(scripts .. "/shot.sh monitor"), { description = "Screenshot active monitor" })
hl.bind(mainMod .. " + Print", hl.dsp.exec_cmd(scripts .. "/shot.sh window"), { description = "Screenshot active window" })
hl.bind(mainMod .. " + CTRL + S", hl.dsp.exec_cmd(scripts .. "/capture.sh"), { description = "Capture menu (screenshot - OCR - QR - record - GIF)" })
hl.bind(mainMod .. " + SHIFT + O", hl.dsp.exec_cmd(scripts .. "/capture.sh ocr"), { description = "OCR region to clipboard (rus+eng)" })
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.exec_cmd("grim -g \"$(slurp)\" - | satty -f - --copy-command wl-copy --output-filename ~/pics/screenshots/%F_%T.png"), { description = "Screenshot region then annotate" })
hl.bind("ALT + S", hl.dsp.exec_cmd(scripts .. "/shot.sh region"), { description = "Screenshot region (clipboard + file)" })
hl.bind("SHIFT + ALT + S", hl.dsp.exec_cmd("grim -g \"$(slurp)\" - | satty -f - --copy-command wl-copy --output-filename ~/pics/screenshots/%F_%T.png"), { description = "Screenshot region then annotate (satty)" })
hl.bind("CTRL + ALT + S", hl.dsp.exec_cmd(scripts .. "/freeze-shot.sh save"), { description = "Frozen screen region screenshot (clipboard + file)" })
hl.bind("CTRL + SHIFT + ALT + S", hl.dsp.exec_cmd(scripts .. "/freeze-shot.sh annotate"), { description = "Frozen screen region screenshot then annotate (satty)" })
hl.bind(mainMod .. " + R", hl.dsp.exec_cmd(scripts .. "/rec-toggle.sh"), { description = "Record screen (toggle)" })
hl.bind(mainMod .. " + SHIFT + R", hl.dsp.exec_cmd(scripts .. "/rec-toggle.sh region"), { description = "Record region (toggle)" })
hl.bind(mainMod .. " + ALT + R", hl.dsp.exec_cmd(scripts .. "/rec-toggle.sh --mic"), { description = "Record screen with system sound and mic (toggle)" })

-- --- windows ---
hl.bind(mainMod .. " + W", hl.dsp.exec_cmd(scripts .. "/safe-close.sh"), { description = "Close window (twice for browsers and terminals)" })
hl.bind(mainMod .. " + SHIFT + W", hl.dsp.exec_cmd(scripts .. "/window-menu.sh"), { description = "Window action menu" })
hl.bind(mainMod .. " + SHIFT + space", hl.dsp.exec_cmd(scripts .. "/window-switcher.sh"), { description = "Window switcher" })
hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }), { description = "Toggle floating" })
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen({ mode = "fullscreen" }), { description = "Fullscreen" })
hl.bind(mainMod .. " + SHIFT + F", hl.dsp.window.fullscreen({ mode = "maximized" }), { description = "Maximize (keep bar)" })
hl.bind(mainMod .. " + SHIFT + P", hl.dsp.window.pin(), { description = "Pin floating window" })
hl.bind(mainMod .. " + U", hl.dsp.focus({ urgent_or_last = true }), { description = "Focus urgent or last window" })
hl.bind(mainMod .. " + Y", hl.dsp.group.toggle(), { description = "Toggle group (tabs)" })
hl.bind(mainMod .. " + SHIFT + Y", hl.dsp.group.next(), { description = "Next tab in group" })

hl.bind(mainMod .. " + H", hl.dsp.focus({ direction = "left" }), { description = "Focus left" })
hl.bind(mainMod .. " + L", hl.dsp.focus({ direction = "right" }), { description = "Focus right" })
hl.bind(mainMod .. " + K", hl.dsp.focus({ direction = "up" }), { description = "Focus up" })
hl.bind(mainMod .. " + J", hl.dsp.focus({ direction = "down" }), { description = "Focus down" })

hl.bind(mainMod .. " + SHIFT + H", hl.dsp.window.move({ direction = "left" }), { description = "Move window left" })
hl.bind(mainMod .. " + SHIFT + L", hl.dsp.window.move({ direction = "right" }), { description = "Move window right" })
hl.bind(mainMod .. " + SHIFT + K", hl.dsp.window.move({ direction = "up" }), { description = "Move window up" })
hl.bind(mainMod .. " + SHIFT + J", hl.dsp.window.move({ direction = "down" }), { description = "Move window down" })

-- Group tabs and relative workspaces (vim grammar: SUPER+ALT = tab / workspace axis, see docs/keymap.md)
hl.bind(mainMod .. " + ALT + H", hl.dsp.group.prev(), { description = "Previous tab in group" })
hl.bind(mainMod .. " + ALT + L", hl.dsp.group.next(), { description = "Next tab in group" })
hl.bind(mainMod .. " + ALT + J", hl.dsp.focus({ workspace = "m+1" }), { description = "Next workspace on this monitor" })
hl.bind(mainMod .. " + ALT + K", hl.dsp.focus({ workspace = "m-1" }), { description = "Previous workspace on this monitor" })
hl.bind(mainMod .. " + ALT + SHIFT + H", hl.dsp.window.move({ into_group = "left" }), { description = "Move window into the group on the left" })
hl.bind(mainMod .. " + ALT + SHIFT + L", hl.dsp.window.move({ into_group = "right" }), { description = "Move window into the group on the right" })
hl.bind(mainMod .. " + ALT + SHIFT + K", hl.dsp.window.move({ into_group = "up" }), { description = "Move window into the group above" })
hl.bind(mainMod .. " + ALT + SHIFT + J", hl.dsp.window.move({ into_group = "down" }), { description = "Move window into the group below" })
hl.bind(mainMod .. " + CTRL + Y", hl.dsp.window.move({ out_of_group = true }), { description = "Move window out of its group" })

-- --- resize: held keys repeat (binde); the submap "resize" is shown by waybar ---
hl.bind(mainMod .. " + left", hl.dsp.window.resize({ x = -20, y = 0, relative = true }), { repeating = true, description = "Resize left" })
hl.bind(mainMod .. " + right", hl.dsp.window.resize({ x = 20, y = 0, relative = true }), { repeating = true, description = "Resize right" })
hl.bind(mainMod .. " + up", hl.dsp.window.resize({ x = 0, y = -20, relative = true }), { repeating = true, description = "Resize up" })
hl.bind(mainMod .. " + down", hl.dsp.window.resize({ x = 0, y = 20, relative = true }), { repeating = true, description = "Resize down" })
hl.bind(mainMod .. " + SHIFT + left", hl.dsp.window.resize({ x = -50, y = 0, relative = true }), { repeating = true, description = "Resize left (big)" })
hl.bind(mainMod .. " + SHIFT + right", hl.dsp.window.resize({ x = 50, y = 0, relative = true }), { repeating = true, description = "Resize right (big)" })
hl.bind(mainMod .. " + SHIFT + up", hl.dsp.window.resize({ x = 0, y = -50, relative = true }), { repeating = true, description = "Resize up (big)" })
hl.bind(mainMod .. " + SHIFT + down", hl.dsp.window.resize({ x = 0, y = 50, relative = true }), { repeating = true, description = "Resize down (big)" })
hl.bind(mainMod .. " + CTRL + H", hl.dsp.window.resize({ x = -40, y = 0, relative = true }), { repeating = true, description = "Resize left" })
hl.bind(mainMod .. " + CTRL + L", hl.dsp.window.resize({ x = 40, y = 0, relative = true }), { repeating = true, description = "Resize right" })
hl.bind(mainMod .. " + CTRL + K", hl.dsp.window.resize({ x = 0, y = -40, relative = true }), { repeating = true, description = "Resize up" })
hl.bind(mainMod .. " + CTRL + J", hl.dsp.window.resize({ x = 0, y = 40, relative = true }), { repeating = true, description = "Resize down" })

hl.bind(mainMod .. " + CTRL + R", hl.dsp.submap("resize"), { description = "Resize mode (Esc to leave)" })
hl.define_submap("resize", function()
    hl.bind("h", hl.dsp.window.resize({ x = -40, y = 0, relative = true }), { repeating = true, description = "Resize left" })
    hl.bind("l", hl.dsp.window.resize({ x = 40, y = 0, relative = true }), { repeating = true, description = "Resize right" })
    hl.bind("k", hl.dsp.window.resize({ x = 0, y = -40, relative = true }), { repeating = true, description = "Resize up" })
    hl.bind("j", hl.dsp.window.resize({ x = 0, y = 40, relative = true }), { repeating = true, description = "Resize down" })
    hl.bind("left", hl.dsp.window.resize({ x = -40, y = 0, relative = true }), { repeating = true, description = "Resize left" })
    hl.bind("right", hl.dsp.window.resize({ x = 40, y = 0, relative = true }), { repeating = true, description = "Resize right" })
    hl.bind("up", hl.dsp.window.resize({ x = 0, y = -40, relative = true }), { repeating = true, description = "Resize up" })
    hl.bind("down", hl.dsp.window.resize({ x = 0, y = 40, relative = true }), { repeating = true, description = "Resize down" })
    hl.bind("escape", hl.dsp.submap("reset"), { description = "Leave resize mode" })
    hl.bind("Return", hl.dsp.submap("reset"), { description = "Leave resize mode" })
    hl.bind("catchall", leave_on_other_key(
        { "h", "j", "k", "l", "left", "right", "up", "down", "escape", "return" },
        function() hl.dispatch(hl.dsp.submap("reset")) end), { description = "Leave resize mode (any other key)" })
end)

-- --- keyboard pointer (wl-kbptr + wlrctl, AUR): pointer.sh shows a notification when a tool is missing ---
hl.bind(mainMod .. " + apostrophe", hl.dsp.exec_cmd(scripts .. "/pointer.sh hint"), { description = "Pointer hint: click by keyboard" })
hl.bind(mainMod .. " + CTRL + apostrophe", hl.dsp.exec_cmd(scripts .. "/pointer.sh drag"), { description = "Pointer hint drag: select or move by keyboard" })
hl.bind(mainMod .. " + ALT + M", hl.dsp.exec_cmd(scripts .. "/pointer.sh mode"), { description = "Mouse mode (hjkl move - space click - Esc leave)" })
hl.define_submap("mouse", function()
    local function ptr(args) return hl.dsp.exec_cmd(scripts .. "/pointer.sh " .. args) end
    local step, far, wheel = 25, 150, 10
    hl.bind("h", ptr("move -" .. step .. " 0"), { repeating = true, description = "Pointer left" })
    hl.bind("l", ptr("move " .. step .. " 0"), { repeating = true, description = "Pointer right" })
    hl.bind("k", ptr("move 0 -" .. step), { repeating = true, description = "Pointer up" })
    hl.bind("j", ptr("move 0 " .. step), { repeating = true, description = "Pointer down" })
    hl.bind("SHIFT + H", ptr("move -" .. far .. " 0"), { repeating = true, description = "Pointer left (big step)" })
    hl.bind("SHIFT + L", ptr("move " .. far .. " 0"), { repeating = true, description = "Pointer right (big step)" })
    hl.bind("SHIFT + K", ptr("move 0 -" .. far), { repeating = true, description = "Pointer up (big step)" })
    hl.bind("SHIFT + J", ptr("move 0 " .. far), { repeating = true, description = "Pointer down (big step)" })
    hl.bind("space", ptr("click left"), { description = "Left click" })
    hl.bind("Return", ptr("click left"), { description = "Left click" })
    hl.bind("r", ptr("click right"), { description = "Right click" })
    hl.bind("m", ptr("click middle"), { description = "Middle click" })
    hl.bind("y", ptr("scroll " .. wheel .. " 0"), { repeating = true, description = "Scroll down" })
    hl.bind("u", ptr("scroll -" .. wheel .. " 0"), { repeating = true, description = "Scroll up" })
    hl.bind("f", ptr("hint-in-mode"), { description = "Pointer hint: jump by label" })
    hl.bind("escape", function() df_mouse_mode(false) end, { description = "Leave mouse mode" })
    hl.bind("q", function() df_mouse_mode(false) end, { description = "Leave mouse mode" })
    hl.bind("catchall", leave_on_other_key(
        { "h", "j", "k", "l", "space", "return", "r", "m", "y", "u", "f", "escape", "q" },
        function() df_mouse_mode(false) end), { description = "Leave mouse mode (any other key)" })
end)

-- --- scratchpads ---
hl.bind(mainMod .. " + grave", hl.dsp.workspace.toggle_special("scratch"), { description = "Toggle scratch workspace" })
hl.bind(mainMod .. " + SHIFT + grave", hl.dsp.window.move({ workspace = "special:scratch" }), { description = "Send window to scratch" })
hl.bind(mainMod .. " + Z", hl.dsp.workspace.toggle_special("term"), { description = "Drop-down terminal (tmux scratch)" })
hl.bind(mainMod .. " + SHIFT + Z", hl.dsp.workspace.toggle_special("notes"), { description = "Notes scratchpad (nvim)" })

-- --- monitors ---
hl.bind(mainMod .. " + CTRL + Delete", hl.dsp.exec_cmd(scripts .. "/lid.sh panel toggle"), { description = "Laptop panel on or off (needs an external monitor)" })
hl.bind(mainMod .. " + CTRL + ALT + Delete", hl.dsp.exec_cmd(scripts .. "/lid.sh mirror toggle"), { description = "Mirror the laptop panel to the external monitor" })
hl.bind(mainMod .. " + CTRL + Z", hl.dsp.exec_cmd(scripts .. "/cursor-zoom.sh in"), { repeating = true, description = "Zoom the screen in around the pointer" })
hl.bind(mainMod .. " + CTRL + SHIFT + Z", hl.dsp.exec_cmd(scripts .. "/cursor-zoom.sh out"), { repeating = true, description = "Zoom the screen out" })
hl.bind(mainMod .. " + CTRL + ALT + Z", hl.dsp.exec_cmd(scripts .. "/cursor-zoom.sh reset"), { description = "Reset the screen zoom" })
hl.bind(mainMod .. " + bracketleft", hl.dsp.focus({ monitor = "-1" }), { description = "Focus previous monitor" })
hl.bind(mainMod .. " + bracketright", hl.dsp.focus({ monitor = "+1" }), { description = "Focus next monitor" })
hl.bind(mainMod .. " + SHIFT + bracketleft", hl.dsp.window.move({ monitor = "-1" }), { description = "Move window to previous monitor" })
hl.bind(mainMod .. " + SHIFT + bracketright", hl.dsp.window.move({ monitor = "+1" }), { description = "Move window to next monitor" })
hl.bind(mainMod .. " + CTRL + bracketleft", hl.dsp.workspace.move({ monitor = "-1" }), { description = "Move workspace to previous monitor" })
hl.bind(mainMod .. " + CTRL + bracketright", hl.dsp.workspace.move({ monitor = "+1" }), { description = "Move workspace to next monitor" })

-- Workspaces 1-10 on SUPER+digit, 11-20 on SUPER+ALT+digit; SHIFT moves the active window
for ws = 1, 20 do
    local digit = tostring(ws % 10)
    local alt = ws > 10 and " + ALT" or ""
    hl.bind(mainMod .. alt .. " + " .. digit, hl.dsp.focus({ workspace = ws }), { description = "Workspace " .. ws })
    hl.bind(mainMod .. " + SHIFT" .. alt .. " + " .. digit, hl.dsp.window.move({ workspace = ws }),
        { description = "Move window to workspace " .. ws })
end
hl.bind(mainMod .. " + TAB", hl.dsp.focus({ workspace = "previous" }), { description = "Previous workspace" })

hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))

hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- --- hardware keys (swayosd draws the OSD; plain tools are the fallback) ---
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("swayosd-client --output-volume raise --max-volume 140 || wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%+"), { repeating = true, locked = true, description = "Volume up" })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("swayosd-client --output-volume lower || wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), { repeating = true, locked = true, description = "Volume down" })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("swayosd-client --output-volume mute-toggle || wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true, description = "Mute output" })
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("swayosd-client --input-volume mute-toggle || wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"), { locked = true, description = "Mute microphone" })
hl.bind(mainMod .. " + SHIFT + M", hl.dsp.exec_cmd(scripts .. "/mic-mute-all.sh"), { description = "Mute all microphones" })
hl.bind(mainMod .. " + XF86AudioRaiseVolume", hl.dsp.exec_cmd(scripts .. "/win-volume.sh up"), { repeating = true, locked = true, description = "Focused app volume up" })
hl.bind(mainMod .. " + XF86AudioLowerVolume", hl.dsp.exec_cmd(scripts .. "/win-volume.sh down"), { repeating = true, locked = true, description = "Focused app volume down" })
hl.bind(mainMod .. " + XF86AudioMute", hl.dsp.exec_cmd(scripts .. "/win-volume.sh mute"), { locked = true, description = "Focused app mute" })
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd(scripts .. "/brightness.sh up"), { repeating = true, locked = true, description = "Brightness up (focused monitor)" })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(scripts .. "/brightness.sh down"), { repeating = true, locked = true, description = "Brightness down (focused monitor)" })
-- fine steps: ALT = 1 %, SHIFT on the brightness keys = 100 % / 1 %; SHIFT+Mute = next output device
hl.bind("ALT + XF86AudioRaiseVolume", hl.dsp.exec_cmd("swayosd-client --output-volume +1 --max-volume 140 || wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 1%+"), { repeating = true, locked = true, description = "Volume up 1 percent" })
hl.bind("ALT + XF86AudioLowerVolume", hl.dsp.exec_cmd("swayosd-client --output-volume -1 || wpctl set-volume @DEFAULT_AUDIO_SINK@ 1%-"), { repeating = true, locked = true, description = "Volume down 1 percent" })
hl.bind("ALT + XF86MonBrightnessUp", hl.dsp.exec_cmd(scripts .. "/brightness.sh up --step 1"), { repeating = true, locked = true, description = "Brightness up 1 percent" })
hl.bind("ALT + XF86MonBrightnessDown", hl.dsp.exec_cmd(scripts .. "/brightness.sh down --step 1"), { repeating = true, locked = true, description = "Brightness down 1 percent" })
hl.bind("SHIFT + XF86MonBrightnessUp", hl.dsp.exec_cmd(scripts .. "/brightness.sh max"), { locked = true, description = "Brightness 100 percent" })
hl.bind("SHIFT + XF86MonBrightnessDown", hl.dsp.exec_cmd(scripts .. "/brightness.sh min"), { locked = true, description = "Brightness minimum (1 percent)" })
hl.bind("SHIFT + XF86AudioMute", hl.dsp.exec_cmd(scripts .. "/audio-picker.sh --next"), { locked = true, description = "Switch to the next audio output" })
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true, description = "Play or pause" })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl pause"), { locked = true, description = "Pause" })
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"), { locked = true, description = "Next track" })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"), { locked = true, description = "Previous track" })

-- --- lid: with another monitor active only the laptop panel is switched off; "keep working with the lid closed"
-- (hub / waybar toggle, lid.sh) holds a logind inhibitor so closing the lid does not suspend ---
hl.bind("switch:on:Lid Switch", hl.dsp.exec_cmd(scripts .. "/lid.sh event close"), { locked = true })
hl.bind("switch:off:Lid Switch", hl.dsp.exec_cmd(scripts .. "/lid.sh event open"), { locked = true })

-- --- text consoles: Ctrl+Alt+F1..F6 ---
-- Hyprland switches the VT itself on the XF86Switch_VT_n keysyms. These binds are a second path through logind (the active
-- session may switch its seat), so the rescue console works without the keysym too. logind starts autovt@ttyN (a getty)
-- on a VT that has no session. Only F2 is described (hub and cheatsheet row); F1 goes back to the graphical VT.
local vt_switch = "busctl call org.freedesktop.login1 /org/freedesktop/login1/seat/seat0 org.freedesktop.login1.Seat SwitchTo u "
for n = 1, 6 do
    hl.bind("CTRL + ALT + F" .. n, hl.dsp.exec_cmd(vt_switch .. n), {
        locked = true,
        description = n == 2 and "Text console on TTY2 (rescue; Ctrl+Alt+F1 returns)" or nil,
    })
end
