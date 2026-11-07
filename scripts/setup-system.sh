#!/usr/bin/env bash
# Pós-instalação — parte de SISTEMA (root).
# Funciona no sistema já iniciado ou dentro do arch-chroot durante a instalação.
#   NONINTERACTIVE=1  não pergunta nada ao pacman
set -euo pipefail
trap 'echo "ERRO: setup-system.sh linha $LINENO: $BASH_COMMAND (status $?)" >&2' ERR

BATTERY_LIMIT="${BATTERY_LIMIT:-80}"
PAC=(--needed)
[[ -n ${NONINTERACTIVE:-} ]] && PAC+=(--noconfirm)

[[ $EUID -eq 0 ]] || { echo "execute como root" >&2; exit 1; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

PKGS=(
  # GPU Intel
  mesa vulkan-intel intel-media-driver libva-utils intel-gpu-tools
  # Áudio
  pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber pavucontrol
  # Bluetooth
  bluez bluez-utils blueman
  # Energia
  power-profiles-daemon thermald
  # Snapshots
  snapper snap-pac
  # Hyprland
  hyprland uwsm xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
  hyprpolkitagent hyprlock hypridle swaybg
  waybar wofi mako libnotify kitty thunar gvfs
  greetd greetd-tuigreet network-manager-applet
  brightnessctl playerctl grim slurp wl-clipboard
  qt5-wayland qt6-wayland
  # Identidade Arch
  archlinux-wallpaper fastfetch
  noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono-nerd
  # Utilidades
  firefox btop
)

step "Pacotes"
pacman -Syu "${PAC[@]}" "${PKGS[@]}"

step "Serviços"
systemctl enable bluetooth.service power-profiles-daemon.service \
  thermald.service greetd.service

step "Login (greetd + tuigreet)"
cat > /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-session --asterisks --greeting 'Arch Linux'"
user = "greeter"
EOF
install -d -o greeter -g greeter /var/cache/tuigreet

step "Snapshots (snapper)"
if [[ ! -f /etc/snapper/configs/root ]]; then
  # snapper quer criar o próprio .snapshots; trocamos pelo subvolume @snapshots do fstab
  umount /.snapshots
  rmdir /.snapshots
  snapper --no-dbus -c root create-config /
  btrfs subvolume delete /.snapshots
  mkdir /.snapshots
  mount /.snapshots
  chmod 750 /.snapshots
  snapper --no-dbus -c root set-config \
    TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=0 \
    TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0 NUMBER_LIMIT=10 ALLOW_GROUPS=wheel
fi
systemctl enable snapper-timeline.timer snapper-cleanup.timer

step "Limite de carga da bateria (${BATTERY_LIMIT}%)"
cat > /etc/systemd/system/battery-limit.service <<EOF
[Unit]
Description=Limite de carga da bateria (${BATTERY_LIMIT}%)
After=multi-user.target suspend.target hibernate.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/class/power_supply/BAT*/charge_control_end_threshold; do [ -w "\$f" ] && echo ${BATTERY_LIMIT} > "\$f"; done'

[Install]
WantedBy=multi-user.target suspend.target hibernate.target
EOF
systemctl enable battery-limit.service
