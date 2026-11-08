#!/usr/bin/env bash
# Tela de boot Plymouth com identidade Arch: logo azul #1793D1 sobre grafite,
# senha do disco pedida na tela gráfica. Baseado no tema "spinner" oficial.
# Executar como root (também funciona dentro do arch-chroot). Idempotente.
set -euo pipefail
trap 'echo "ERRO: plymouth-theme.sh linha $LINENO: $BASH_COMMAND (status $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
THEMES=/usr/share/plymouth/themes
NAME=arch-linux
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
  -e 's|^Name=.*|Name=Arch Linux|' \
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

# Hook do plymouth no initramfs (antes do sd-encrypt → senha na tela gráfica).
# Lê os HOOKS efetivos (mkinitcpio.conf + drop-ins, como o mkinitcpio faz) e,
# se faltar o plymouth, grava um drop-in final com ele logo após systemd/udev.
effective_hooks() {
  bash -c 'source /etc/mkinitcpio.conf
           for f in /etc/mkinitcpio.conf.d/*.conf; do [ -e "$f" ] && source "$f"; done
           echo "${HOOKS[*]}"'
}
HOOKS_NOW="$(effective_hooks)"
if [[ " $HOOKS_NOW " != *" plymouth "* ]]; then
  NEW=()
  for h in $HOOKS_NOW; do
    NEW+=("$h")
    [[ $h == systemd || $h == udev ]] && NEW+=(plymouth)
  done
  [[ " ${NEW[*]} " == *" plymouth "* ]] || NEW=(base plymouth "${NEW[@]:1}")
  echo "HOOKS=(${NEW[*]})" > /etc/mkinitcpio.conf.d/90-plymouth.conf
fi

# "splash" na linha de comando embutida na UKI. ignore-serial-consoles evita o
# modo texto quando o firmware anuncia console serial (o systemd-stub adiciona
# console=uart... nesse caso, e o Plymouth então desiste do modo gráfico).
if [[ -f /etc/kernel/cmdline ]]; then
  grep -qw quiet  /etc/kernel/cmdline || sed -i 's/$/ quiet/'  /etc/kernel/cmdline
  grep -qw splash /etc/kernel/cmdline || sed -i 's/$/ splash/' /etc/kernel/cmdline
  grep -q 'plymouth.ignore-serial-consoles' /etc/kernel/cmdline \
    || sed -i 's/$/ plymouth.ignore-serial-consoles/' /etc/kernel/cmdline
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
  ESP="$(bootctl --print-esp-path 2>/dev/null || echo /efi)"
  for f in "$ESP"/EFI/Linux/*.efi; do sbctl sign -s "$f"; done
fi

echo "==> Tema Plymouth '$NAME' ativo."
