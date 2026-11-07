-- Ajustes do ASUS Vivobook S14 (S3407CA) + identidade visual Arch Linux.
-- Carregado no fim do hyprland.lua com require("vivobook"): sobrescreve o padrão.
-- Referência: https://wiki.hypr.land/configuring/

local wallpaper = "@WALLPAPER@"

-- Tela 14" 1920x1200 — escala 1.25 (1536x960 lógicos). Use 1 para mais espaço.
hl.monitor({
    output   = "eDP-1",
    mode     = "1920x1200@60",
    position = "0x0",
    scale    = 1.25,
})

hl.config({
    xwayland = {
        force_zero_scaling = true,
    },

    input = {
        kb_layout = "br",
        touchpad = {
            natural_scroll       = true,
            tap_to_click         = true,
            disable_while_typing = true,
        },
    },

    -- Paleta Arch: azul #1793D1 sobre grafite
    general = {
        gaps_in     = 4,
        gaps_out    = 8,
        border_size = 2,
        col = {
            active_border   = { colors = { "rgba(1793d1ff)", "rgba(4fb3e8ff)" }, angle = 45 },
            inactive_border = "rgba(333c43aa)",
        },
    },

    decoration = {
        rounding = 6,
    },

    misc = {
        disable_hyprland_logo    = true,
        disable_splash_rendering = true,
        force_default_wallpaper  = 0,
        background_color         = "rgb(101418)",
    },
})

hl.on("hyprland.start", function()
    if wallpaper ~= "" then
        hl.exec_cmd("swaybg -m fill -i " .. wallpaper)
    end
    hl.exec_cmd("waybar")
    hl.exec_cmd("mako")
    hl.exec_cmd("nm-applet --indicator")
    hl.exec_cmd("blueman-applet")
    hl.exec_cmd("hypridle")
    hl.exec_cmd("systemctl --user start hyprpolkitagent")
    -- Avisos da configuração automática de Secure Boot/TPM (se houver pendência)
    hl.exec_cmd([[sh -c 'sleep 4; [ -s /run/vivobook-status ] && notify-send -u critical "Secure Boot / TPM" "$(cat /run/vivobook-status)"']])
end)

-- Bloquear tela
hl.bind("SUPER + L", hl.dsp.exec_cmd("loginctl lock-session"))
-- Captura de área para a área de transferência
hl.bind("Print", hl.dsp.exec_cmd([[sh -c 'grim -g "$(slurp)" - | wl-copy']]))
