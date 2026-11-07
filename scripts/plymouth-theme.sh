#!/usr/bin/env bash
# Tela de boot Plymouth com identidade Arch: logo azul #1793D1 sobre grafite,
# senha do disco pedida na tela gráfica. Baseado no tema "spinner" oficial.
# Executar como root (também funciona dentro do arch-chroot). Idempotente.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
THEMES=/usr/share/plymouth/themes
NAME=arch-vivobook
DIR="$THEMES/$NAME"

[[ $EUID -eq 0 ]] || { echo "execute como root" >&2; exit 1; }
pacman -Q plymouth &>/dev/null || pacman -S --needed --noconfirm plymouth

# Tema: cópia do spinner com logo, cores e posições próprias
rm -rf "$DIR"
cp -r "$THEMES/spinner" "$DIR"
mv "$DIR/spinner.plymouth" "$DIR/$NAME.plymouth"
install -m 644 "$REPO_DIR/config/plymouth/watermark.png" "$DIR/watermark.png"
sed -i -E \
  -e '/^Name\[/d' \
  -e 's|^Name=.*|Name=Arch Vivobook|' \
  -e 's|^Description=.*|Description=Logo do Arch Linux sobre grafite (#1793D1)|' \
  -e "s|^ImageDir=.*|ImageDir=$DIR|" \
  -e 's|^WatermarkVerticalAlignment=.*|WatermarkVerticalAlignment=.40|' \
  -e 's|^DialogVerticalAlignment=.*|DialogVerticalAlignment=.72|' \
  -e 's|^VerticalAlignment=.*|VerticalAlignment=.80|' \
  -e 's|^BackgroundStartColor=.*|BackgroundStartColor=0x101418|' \
  -e 's|^BackgroundEndColor=.*|BackgroundEndColor=0x101418|' \
  -e 's|^ProgressBarForegroundColor=.*|ProgressBarForegroundColor=0x1793d1|' \
  -e 's|^Title=Installing Updates...|Title=Instalando atualizações...|' \
  -e 's|^Title=Upgrading System...|Title=Atualizando o sistema...|' \
  -e 's|^Title=Upgrading Firmware...|Title=Atualizando o firmware...|' \
  -e 's|^Title=Resetting System...|Title=Restaurando o sistema...|' \
  -e 's|^SubTitle=Do not turn off your computer|SubTitle=Não desligue o computador|' \
  "$DIR/$NAME.plymouth"

mkdir -p /etc/plymouth
cat > /etc/plymouth/plymouthd.conf <<EOF
[Daemon]
Theme=$NAME
ShowDelay=0
EOF

# Hook do plymouth no initramfs (antes do sd-encrypt → senha na tela gráfica)
CONF=/etc/mkinitcpio.conf.d/10-vivobook.conf
if [[ -f $CONF ]] && ! grep -q 'plymouth' "$CONF"; then
  sed -i 's/(base systemd /(base systemd plymouth /' "$CONF"
fi

# "splash" na linha de comando embutida na UKI
if [[ -f /etc/kernel/cmdline ]] && ! grep -qw splash /etc/kernel/cmdline; then
  sed -i 's/$/ splash/' /etc/kernel/cmdline
fi

# greetd só assume o tty1 depois que o Plymouth sai da tela
mkdir -p /etc/systemd/system/greetd.service.d
cat > /etc/systemd/system/greetd.service.d/plymouth.conf <<'EOF'
[Unit]
After=plymouth-quit-wait.service
EOF

mkinitcpio -P

# Com Secure Boot configurado, as UKIs recriadas precisam de nova assinatura
if [[ -d /var/lib/sbctl/keys || -d /usr/share/secureboot/keys ]]; then
  for f in /efi/EFI/Linux/*.efi; do sbctl sign -s "$f"; done
fi

echo "==> Tema Plymouth '$NAME' ativo."
