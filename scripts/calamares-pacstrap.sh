#!/usr/bin/env bash
# Instala a base do sistema no destino já particionado/montado pelo Calamares.
# Roda no live (módulo shellprocess com dontChroot) e recebe a raiz do sistema
# instalado como $1 (${ROOT} do Calamares).
#
# Responsabilidade deste script: pacotes base + diretórios e espelhos.
# fstab, initramfs/UKI, systemd-boot e serviços ficam em calamares-target.sh.
set -Eeuo pipefail
trap 'echo "ERRO: linha $LINENO: $BASH_COMMAND (status $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/packages.sh
source "$SCRIPT_DIR/lib/packages.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MNT="${1:-}"
[[ $EUID -eq 0 ]] || die "execute como root"
[[ -n $MNT && -d $MNT ]] || die "uso: $0 <raiz-do-sistema-instalado>"
findmnt "$MNT" >/dev/null || die "$MNT não está montado (o Calamares montou o destino?)"
findmnt "$MNT/efi" >/dev/null || die "a partição EFI não está montada em $MNT/efi"

step "Espelhos (Brasil)"
if command -v reflector >/dev/null; then
  reflector --country Brazil --protocol https --latest 10 --sort rate \
    --save /etc/pacman.d/mirrorlist || warn "reflector falhou, usando os espelhos atuais"
fi

step "Instalando pacotes base (pode levar alguns minutos)"
pacstrap -K "$MNT" "${PACKAGES[@]}"

# Usa no sistema instalado a mesma lista de espelhos que funcionou no live.
if [[ -f /etc/pacman.d/mirrorlist ]]; then
  install -Dm 644 /etc/pacman.d/mirrorlist "$MNT/etc/pacman.d/mirrorlist"
fi

step "Criando diretórios do boot e do initramfs"
install -d "$MNT/etc/X11/xorg.conf.d" "$MNT/etc/mkinitcpio.conf.d" \
  "$MNT/etc/mkinitcpio.d" "$MNT/etc/kernel" "$MNT/etc/systemd" \
  "$MNT/efi/EFI/Linux" "$MNT/efi/loader"
