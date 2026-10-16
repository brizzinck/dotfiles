-- Static monitor rules, loaded by hyprland.lua and by lid.sh (re-enables the laptop panel after the lid opens).
return {
    { output = "HDMI-A-1", mode = "2560x1440@144", position = "0x0",    scale = 1 },
    { output = "eDP-1",    mode = "2880x1800@120", position = "0x1440", scale = 1.5 },
    { output = "",         mode = "preferred",     position = "auto",   scale = 1 },
}
