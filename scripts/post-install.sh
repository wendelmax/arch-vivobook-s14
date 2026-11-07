#!/usr/bin/env bash
# Fase 2 — pós-instalação: Hyprland com identidade Arch, energia, snapshots
# e ajustes do ASUS Vivobook S14. Executar como usuário comum (usa sudo).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BATTERY_LIMIT="${BATTERY_LIMIT:-80}"

[[ $EUID -ne 0 ]] || { echo "execute como usuário comum (o script usa sudo)" >&2; exit 1; }
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
  waybar wofi mako kitty thunar gvfs
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
sudo pacman -Syu --needed "${PKGS[@]}"

step "AUR helper (paru)"
if ! command -v paru >/dev/null; then
  tmp="$(mktemp -d)"
  git clone https://aur.archlinux.org/paru.git "$tmp/paru"
  (cd "$tmp/paru" && makepkg -si)
  rm -rf "$tmp"
fi

step "Serviços"
sudo systemctl enable bluetooth.service power-profiles-daemon.service \
  thermald.service greetd.service

step "Login (greetd + tuigreet)"
sudo tee /etc/greetd/config.toml >/dev/null <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-session --asterisks --greeting 'Arch Linux'"
user = "greeter"
EOF
sudo install -d -o greeter -g greeter /var/cache/tuigreet

step "Snapshots (snapper)"
if [[ ! -f /etc/snapper/configs/root ]]; then
  sudo umount /.snapshots
  sudo rmdir /.snapshots
  sudo snapper -c root create-config /
  sudo btrfs subvolume delete /.snapshots
  sudo mkdir /.snapshots
  sudo mount -a
  sudo chmod 750 /.snapshots
  sudo snapper -c root set-config \
    TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=0 \
    TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0 NUMBER_LIMIT=10 ALLOW_GROUPS=wheel
fi
sudo systemctl enable snapper-timeline.timer snapper-cleanup.timer

step "Limite de carga da bateria (${BATTERY_LIMIT}%)"
sudo tee /etc/systemd/system/battery-limit.service >/dev/null <<EOF
[Unit]
Description=Limite de carga da bateria (${BATTERY_LIMIT}%)
After=multi-user.target suspend.target hibernate.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/class/power_supply/BAT*/charge_control_end_threshold; do [ -w "\$f" ] && echo ${BATTERY_LIMIT} > "\$f"; done'

[Install]
WantedBy=multi-user.target suspend.target hibernate.target
EOF
sudo systemctl enable battery-limit.service

step "Configuração do Hyprland (identidade Arch)"
CFG="$HOME/.config"
mkdir -p "$CFG/hypr" "$CFG/waybar" "$CFG/mako" "$CFG/kitty"

if [[ ! -f $CFG/hypr/hyprland.conf ]]; then
  if [[ -f /usr/share/hypr/hyprland.conf ]]; then
    cp /usr/share/hypr/hyprland.conf "$CFG/hypr/hyprland.conf"
    sed -i 's/^\$fileManager = .*/$fileManager = thunar/' "$CFG/hypr/hyprland.conf"
  else
    echo "AVISO: modelo do hyprland.conf não encontrado; abra o Hyprland uma vez e rode este script de novo."
  fi
fi

# Wallpaper oficial do Arch (primeiro que existir no pacote archlinux-wallpaper)
WALL=""
for f in /usr/share/backgrounds/archlinux/{simple.png,archwave.png,small.png} \
         /usr/share/backgrounds/archlinux/*; do
  [[ -f $f ]] && { WALL="$f"; break; }
done

cp "$REPO_DIR/config/hypr/hypridle.conf" "$CFG/hypr/"
sed "s|@WALLPAPER@|${WALL}|" "$REPO_DIR/config/hypr/vivobook.conf" > "$CFG/hypr/vivobook.conf"
sed "s|@WALLPAPER@|${WALL}|" "$REPO_DIR/config/hypr/hyprlock.conf" > "$CFG/hypr/hyprlock.conf"
cp "$REPO_DIR/config/waybar/config.jsonc" "$REPO_DIR/config/waybar/style.css" "$CFG/waybar/"
cp "$REPO_DIR/config/mako/config"  "$CFG/mako/config"
cp "$REPO_DIR/config/kitty/kitty.conf" "$CFG/kitty/kitty.conf"

if [[ -f $CFG/hypr/hyprland.conf ]] && ! grep -q 'vivobook.conf' "$CFG/hypr/hyprland.conf"; then
  echo 'source = ~/.config/hypr/vivobook.conf' >> "$CFG/hypr/hyprland.conf"
fi

# fastfetch com o logo do Arch ao abrir o terminal
grep -q 'fastfetch' "$HOME/.bashrc" 2>/dev/null || echo '[[ $- == *i* ]] && fastfetch' >> "$HOME/.bashrc"

step "Pronto"
cat <<'EOF'
Reinicie. No tuigreet, escolha a sessão "Hyprland (uwsm-managed)" (F3 troca a sessão).
Atalhos padrão: SUPER+Q terminal | SUPER+R menu | SUPER+E arquivos | SUPER+C fecha janela
Depois, compile o kernel otimizado: ~/arch-linux/scripts/build-kernel.sh
EOF
