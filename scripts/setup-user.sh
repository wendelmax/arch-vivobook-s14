#!/usr/bin/env bash
# Pós-instalação — parte de USUÁRIO: paru e configs do Hyprland com identidade Arch.
# Executar como o usuário comum (também via "sudo -u USER -H" no chroot).
#   NONINTERACTIVE=1  não pergunta nada ao makepkg
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
MK=(--syncdeps --install)
[[ -n ${NONINTERACTIVE:-} ]] && MK+=(--noconfirm)

[[ $EUID -ne 0 ]] || { echo "execute como usuário comum" >&2; exit 1; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

step "AUR helper (paru)"
if ! command -v paru >/dev/null; then
  tmp="$(mktemp -d)"
  git clone https://aur.archlinux.org/paru.git "$tmp/paru"
  (cd "$tmp/paru" && makepkg "${MK[@]}")
  rm -rf "$tmp"
fi

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
