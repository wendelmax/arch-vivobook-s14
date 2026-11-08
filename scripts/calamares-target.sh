#!/usr/bin/env bash
# Fecha a configuração do sistema instalado pelo Calamares: fstab, cmdline da
# UKI, initramfs systemd, systemd-boot, zram e serviços.
# Roda no live (dontChroot) e recebe a raiz do sistema instalado como $1.
set -Eeuo pipefail
trap 'echo "ERRO: linha $LINENO: $BASH_COMMAND (status $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MNT="${1:-}"
[[ $EUID -eq 0 ]] || die "execute como root"
[[ -n $MNT && -d $MNT ]] || die "uso: $0 <raiz-do-sistema-instalado>"
findmnt "$MNT" >/dev/null || die "$MNT não está montado"
[[ -d $MNT/etc ]] || die "$MNT não parece um sistema Linux (sem /etc)"
findmnt "$MNT/efi" >/dev/null || die "a partição EFI não está montada em $MNT/efi"

step "fstab"
# O mount do Calamares deixa /proc, /sys, /dev e /run montados dentro do
# destino; genfstab -p + o filtro abaixo não deixam esses mounts no fstab.
genfstab -U -p "$MNT" | awk '$2 !~ /^\/(proc|sys|dev|run)(\/|$)/' > "$MNT/etc/fstab"
# subvolid fixo atrapalha a restauração de snapshots; montar só pelo nome
sed -i -E 's/subvolid=[0-9]+,//' "$MNT/etc/fstab"

# O módulo users do Calamares grava hostname/hosts; garante o mínimo caso
# alguma versão tenha pulado essa parte.
if [[ ! -s $MNT/etc/hostname ]]; then
  echo archlinux > "$MNT/etc/hostname"
fi
HOST_NAME="$(cat "$MNT/etc/hostname")"
if ! grep -q '^127\.0\.0\.1' "$MNT/etc/hosts" 2>/dev/null; then
  cat > "$MNT/etc/hosts" <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOST_NAME.localdomain $HOST_NAME
EOF
fi

# Fonte do console com acentos (o teclado já foi gravado pelo Calamares)
if [[ -f $MNT/etc/vconsole.conf ]]; then
  grep -q '^FONT=' "$MNT/etc/vconsole.conf" || echo 'FONT=ter-v20n' >> "$MNT/etc/vconsole.conf"
else
  printf 'KEYMAP=br-abnt2\nFONT=ter-v20n\n' > "$MNT/etc/vconsole.conf"
fi

# ---------------------------------------------------------------- cmdline/UKI
SRC="$(findmnt -no SOURCE "$MNT")"; SRC="${SRC%%[*}"
FSTYPE="$(findmnt -no FSTYPE "$MNT")"
LUKS_BACKING="$(luks_backing_device "$MNT" || true)"
MAPPER=""
[[ $SRC == /dev/mapper/* ]] && MAPPER="${SRC#/dev/mapper/}"

step "Linha de comando da UKI"
CMDLINE=()
if [[ -n $LUKS_BACKING ]]; then
  # O nome do mapper do Calamares é preservado para o initramfs recriá-lo.
  [[ -n $MAPPER ]] || die "não consegui identificar o mapper LUKS de $MNT"
  LUKS_UUID="$(cryptsetup luksUUID "$LUKS_BACKING")"
  CMDLINE+=("rd.luks.name=$LUKS_UUID=$MAPPER")
  CMDLINE+=("rd.luks.options=$LUKS_UUID=tpm2-device=auto,discard")
  CMDLINE+=("root=/dev/mapper/$MAPPER")
else
  ROOT_UUID="$(blkid -s UUID -o value "$SRC" 2>/dev/null || true)"
  [[ -n $ROOT_UUID ]] || die "não consegui identificar o UUID da raiz $SRC"
  CMDLINE+=("root=UUID=$ROOT_UUID")
fi
[[ $FSTYPE == btrfs ]] && CMDLINE+=("rootflags=subvol=@")
CMDLINE+=("rw" "zswap.enabled=0" "quiet")
mkdir -p "$MNT/etc/kernel"
printf '%s\n' "${CMDLINE[*]}" > "$MNT/etc/kernel/cmdline"

# initramfs systemd + desbloqueio LUKS (senha ou TPM2)
mkdir -p "$MNT/etc/mkinitcpio.conf.d"
cat > "$MNT/etc/mkinitcpio.conf.d/10-arch.conf" <<'EOF'
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
EOF

# linux-lts gera UKI direto na ESP (kernel de reserva)
mkdir -p "$MNT/etc/mkinitcpio.d" "$MNT/efi/EFI/Linux"
cat > "$MNT/etc/mkinitcpio.d/linux-lts.preset" <<'EOF'
ALL_kver="/boot/vmlinuz-linux-lts"
PRESETS=('default')
default_uki="/efi/EFI/Linux/arch-linux-lts.efi"
EOF

# Swap comprimida em RAM
mkdir -p "$MNT/etc/systemd" "$MNT/etc/sysctl.d"
cat > "$MNT/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF
cat > "$MNT/etc/sysctl.d/99-zram.conf" <<'EOF'
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF

step "chroot: UKI, bootloader e serviços"
arch-chroot "$MNT" /bin/bash -e <<'EOF'
rm -f /boot/initramfs-linux-lts*.img
mkinitcpio -P
bootctl install --esp-path=/efi || bootctl install --esp-path=/efi --no-variables
systemctl enable NetworkManager systemd-timesyncd fstrim.timer systemd-boot-update.service
EOF

cat > "$MNT/efi/loader/loader.conf" <<'EOF'
default arch-linux-lts.efi
timeout 3
console-mode max
editor no
EOF

step "Sistema instalado: $(findmnt -no SOURCE "$MNT") (${FSTYPE:-?})"
