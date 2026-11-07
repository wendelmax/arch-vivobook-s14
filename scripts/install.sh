#!/usr/bin/env bash
# Fase 1 — instalação base do Arch Linux no ASUS Vivobook S14 (S3407CA).
# Executar como root no ambiente live do Arch ISO.
#
#   LUKS2 + Btrfs (subvolumes p/ snapper) + systemd-boot + UKI + linux-lts
#
# ATENÇÃO: APAGA TODO O DISCO definido em DISK.
set -euo pipefail

DISK="${DISK:-/dev/nvme0n1}"
HOST_NAME="${HOST_NAME:-vivobook}"
TIMEZONE="${TIMEZONE:-America/Sao_Paulo}"
KEYMAP="${KEYMAP:-br-abnt2}"
LOCALE="${LOCALE:-pt_BR.UTF-8}"
MOUNT_OPTS="noatime,compress=zstd:1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PACKAGES=(
  base base-devel linux-lts linux-lts-headers linux-firmware intel-ucode
  sof-firmware alsa-ucm-conf
  btrfs-progs cryptsetup dosfstools tpm2-tss sbctl
  networkmanager zram-generator reflector
  sudo nano neovim git man-db man-pages bash-completion terminus-font
)

die()  { echo "ERRO: $*" >&2; exit 1; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || die "execute como root"
[[ -d /sys/firmware/efi/efivars ]] || die "o sistema não iniciou em modo UEFI"
[[ -b $DISK ]] || die "disco $DISK não encontrado (Intel VMD ainda ativo no BIOS?)"
ping -c1 -W3 archlinux.org >/dev/null 2>&1 || die "sem internet — conecte com iwctl"

if [[ $DISK == *nvme* || $DISK == *mmcblk* ]]; then
  ESP="${DISK}p1"; ROOT="${DISK}p2"
else
  ESP="${DISK}1";  ROOT="${DISK}2"
fi

read -rp "Nome do usuário: " USERNAME
[[ $USERNAME =~ ^[a-z_][a-z0-9_-]*$ ]] || die "nome de usuário inválido"

lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL "$DISK"
echo
echo "TODOS os dados em $DISK serão APAGADOS."
read -rp "Digite APAGAR para continuar: " confirm
[[ $confirm == APAGAR ]] || die "cancelado"

step "Relógio"
timedatectl set-ntp true

step "Particionando $DISK (EFI 1 GiB + LUKS)"
umount -R /mnt 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+1G -t1:ef00 -c1:EFI -n2:0:0 -t2:8309 -c2:cryptroot "$DISK"
partprobe "$DISK"
udevadm settle

step "Formatando partição EFI"
mkfs.fat -F32 -n EFI "$ESP"

step "Criptografia LUKS2 — escolha a senha de desbloqueio (guarde-a!)"
cryptsetup luksFormat --type luks2 --label cryptroot "$ROOT"
cryptsetup open --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue \
  --persistent "$ROOT" cryptroot
LUKS_UUID="$(cryptsetup luksUUID "$ROOT")"

step "Btrfs + subvolumes"
mkfs.btrfs -f -L arch /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
for sv in @ @home @snapshots @var_log @var_cache @var_tmp; do
  btrfs subvolume create "/mnt/$sv"
done
umount /mnt

mount -o "$MOUNT_OPTS,subvol=@" /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,var/log,var/cache,var/tmp,efi}
mount -o "$MOUNT_OPTS,subvol=@home"      /dev/mapper/cryptroot /mnt/home
mount -o "$MOUNT_OPTS,subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
mount -o "$MOUNT_OPTS,subvol=@var_log"   /dev/mapper/cryptroot /mnt/var/log
mount -o "$MOUNT_OPTS,subvol=@var_cache" /dev/mapper/cryptroot /mnt/var/cache
mount -o "$MOUNT_OPTS,subvol=@var_tmp"   /dev/mapper/cryptroot /mnt/var/tmp
chmod 1777 /mnt/var/tmp
mount -o umask=0077 "$ESP" /mnt/efi

step "Espelhos (Brasil)"
reflector --country Brazil --protocol https --latest 10 --sort rate \
  --save /etc/pacman.d/mirrorlist || echo "aviso: reflector falhou, usando lista atual"

step "Instalando pacotes base"
pacstrap -K /mnt "${PACKAGES[@]}"

step "fstab"
genfstab -U /mnt >> /mnt/etc/fstab
# subvolid fixo atrapalha restauração de snapshots; montar só por nome
sed -i -E 's/subvolid=[0-9]+,//' /mnt/etc/fstab

step "Configuração do sistema"
echo "$HOST_NAME" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOST_NAME.localdomain $HOST_NAME
EOF

printf '%s UTF-8\nen_US.UTF-8 UTF-8\n' "$LOCALE" >> /mnt/etc/locale.gen
echo "LANG=$LOCALE" > /mnt/etc/locale.conf
printf 'KEYMAP=%s\nFONT=ter-v20n\n' "$KEYMAP" > /mnt/etc/vconsole.conf

echo '%wheel ALL=(ALL:ALL) ALL' > /mnt/etc/sudoers.d/10-wheel
chmod 440 /mnt/etc/sudoers.d/10-wheel

# initramfs systemd + desbloqueio LUKS (senha ou TPM2)
mkdir -p /mnt/etc/mkinitcpio.conf.d
cat > /mnt/etc/mkinitcpio.conf.d/10-vivobook.conf <<'EOF'
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
EOF

# Linha de comando embutida na UKI
mkdir -p /mnt/etc/kernel
echo "rd.luks.name=$LUKS_UUID=cryptroot rd.luks.options=$LUKS_UUID=tpm2-device=auto,discard root=/dev/mapper/cryptroot rootflags=subvol=@ rw zswap.enabled=0 quiet" \
  > /mnt/etc/kernel/cmdline

# linux-lts gera UKI direto na ESP (kernel de reserva)
cat > /mnt/etc/mkinitcpio.d/linux-lts.preset <<'EOF'
ALL_kver="/boot/vmlinuz-linux-lts"
PRESETS=('default')
default_uki="/efi/EFI/Linux/arch-linux-lts.efi"
EOF
mkdir -p /mnt/efi/EFI/Linux

# Swap comprimida em RAM
cat > /mnt/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF
cat > /mnt/etc/sysctl.d/99-zram.conf <<'EOF'
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF

step "chroot: fuso, locale, usuário, UKI, bootloader"
arch-chroot /mnt /bin/bash -e <<EOF
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
locale-gen
useradd -m -G wheel -s /bin/bash $USERNAME
rm -f /boot/initramfs-linux-lts*.img
mkinitcpio -P
bootctl install --esp-path=/efi
systemctl enable NetworkManager systemd-timesyncd fstrim.timer systemd-boot-update.service
EOF

cat > /mnt/efi/loader/loader.conf <<'EOF'
default arch-linux-lts.efi
timeout 3
console-mode max
editor no
EOF

step "Senhas"
echo "Senha do root:"
until arch-chroot /mnt passwd; do :; done
echo "Senha do usuário $USERNAME:"
until arch-chroot /mnt passwd "$USERNAME"; do :; done

step "Copiando scripts para /home/$USERNAME/arch-linux"
cp -r "$REPO_DIR" "/mnt/home/$USERNAME/arch-linux"
arch-chroot /mnt chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/arch-linux"

step "Pronto"
cat <<EOF
Instalação base concluída. Próximos passos:
  umount -R /mnt && cryptsetup close cryptroot && reboot
Depois do boot: entre como $USERNAME e siga o GUIA.md (Fase 2).
EOF
