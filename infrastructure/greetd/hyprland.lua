-- Greeter compositor: a minimal Hyprland that only hosts the Quickshell login screen (/etc/greetd/greeter).
-- greetd runs it as user "greeter" through /usr/local/lib/greeter/greeter-session. Installed as /etc/greetd/hyprland.lua.
-- GREETER_ROOT points the config paths and GREETER_LIB the helper scripts at the repo (infrastructure/greetd) for nested
-- tests; they default to /etc/greetd and /usr/local/lib/greeter.
local root = os.getenv("GREETER_ROOT") or "/etc/greetd"
local lib = os.getenv("GREETER_LIB") or "/usr/local/lib/greeter"

-- Same monitor rules as the session (/etc/greetd/monitors.lua is a copy of .config/hypr/monitors.lua).
for _, rule in ipairs(dofile(root .. "/monitors.lua")) do
    hl.monitor(rule)
end

-- Pointer: the session's cursor when it is installed (see hyprland.lua), Bibata otherwise; never request a missing theme.
local function readable(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end
local pointer_theme = "Bibata-Modern-Ice"
if readable("/usr/share/icons/Everforest-Cursor/manifest.hl") and readable("/usr/share/icons/Everforest-Cursor/cursors/left_ptr") then
    pointer_theme = "Everforest-Cursor"
    hl.env("HYPRCURSOR_THEME", pointer_theme)
end
hl.env("XCURSOR_THEME", pointer_theme)
hl.env("XCURSOR_SIZE", "32")
hl.env("HYPRCURSOR_SIZE", "32")

hl.config({
    input = {
        -- the session's layout scheme: us, ua, ru; Caps switches (the greeter shows the active one)
        kb_layout = "us,ua,ru",
        kb_options = "grp:caps_toggle",
        follow_mouse = 1,
        touchpad = { natural_scroll = true },
    },
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        disable_hyprland_guiutils_check = true,
        background_color = "rgb(000000)",
        key_press_enables_dpms = true,
        mouse_move_enables_dpms = true,
    },
    ecosystem = {
        no_update_news = true,
        no_donation_nag = true,
    },
    animations = { enabled = false },
    cursor = { inactive_timeout = 3 },
})

-- Closing the lid at the login screen turns the panel off; logind still decides about suspend.
hl.bind("switch:on:Lid Switch", hl.dsp.dpms({ action = "off", monitor = "eDP-1" }), { locked = true })
hl.bind("switch:off:Lid Switch", hl.dsp.dpms({ action = "on", monitor = "eDP-1" }), { locked = true })

-- run-qs starts Quickshell, watches that it came up and exits this Hyprland when the greeter is done.
hl.on("hyprland.start", function()
    hl.exec_cmd(lib .. "/run-qs")
end)
