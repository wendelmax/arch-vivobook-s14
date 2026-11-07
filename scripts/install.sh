#!/usr/bin/env bash
# Instalação completa do Arch Linux no ASUS Vivobook S14 (S3407CA).
# Executar como root no ambiente live do Arch ISO.
#
# Todas as perguntas são feitas no início; depois a instalação segue sozinha:
#   base (LUKS2 + Btrfs + systemd-boot + UKI + linux-lts) → Wi-Fi salvo →
#   [Hyprland + visual Arch] → [kernel -march=native] → [Secure Boot + TPM2]
#
# ATENÇÃO: APAGA TODO O DISCO definido em DISK.
# Variáveis opcionais: DISK, HOST_NAME, TIMEZONE, KEYMAP, LOCALE, WIFI_SSID, WIFI_PASS
# Respostas prontas (sem perguntas): VB_USERNAME, VB_HOSTNAME, VB_USER_PASS,
#   VB_ROOT_PASS, VB_LUKS_PASS, VB_POST, VB_KERNEL, VB_SB (1/0), VB_CONFIRM=APAGAR
set -euo pipefail

DISK="${DISK:-/dev/nvme0n1}"
HOST_NAME="${HOST_NAME:-vivobook}"
TIMEZONE="${TIMEZONE:-America/Sao_Paulo}"
KEYMAP="${KEYMAP:-br-abnt2}"
LOCALE="${LOCALE:-pt_BR.UTF-8}"
MOUNT_OPTS="noatime,compress=zstd:1"
LOG=/root/vivobook-install.log
GUID=8be4df61-93ca-11d2-aa0d-00e098032b8c

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PACKAGES=(
  base base-devel linux-lts linux-lts-headers linux-firmware intel-ucode
  sof-firmware alsa-ucm-conf
  btrfs-progs cryptsetup dosfstools tpm2-tss sbctl
  networkmanager zram-generator reflector plymouth
  sudo nano neovim git man-db man-pages bash-completion terminus-font
)

die()  { echo "ERRO: $*" >&2; exit 1; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
WARNINGS=()
warn() { echo "AVISO: $*" >&2; WARNINGS+=("$*"); }

ask_secret() {   # $1 = descrição; imprime a senha confirmada em stdout
  local a b
  while :; do
    read -rsp "$1: " a; echo >&2
    read -rsp "Repita: " b; echo >&2
    [[ -n $a && $a == "$b" ]] && { printf '%s' "$a"; return; }
    echo "Senhas vazias ou diferentes, tente de novo." >&2
  done
}
ask_yes() { local a; read -rp "$1 [S/n] " a; [[ -z $a || $a =~ ^[SsYy] ]]; }
efivar_is_1() {
  local f="/sys/firmware/efi/efivars/$1-$GUID"
  [[ -r $f ]] && [[ $(od -An -t u1 "$f" | awk '{print $NF}') == 1 ]]
}

# Wi-Fi conectado no live via iwd (quando não veio por WIFI_SSID/WIFI_PASS)
detect_iwd_wifi() {
  local f name pass
  for f in /var/lib/iwd/*.psk; do
    [[ -f $f ]] || continue
    pass="$(sed -n 's/^Passphrase=//p' "$f")"
    [[ -n $pass ]] || continue
    name="$(basename "$f" .psk)"
    if [[ $name == =* ]]; then name="$(printf '%s' "${name#=}" | sed 's/../\\x&/g')"; name="$(printf '%b' "$name")"; fi
    WIFI_SSID="$name"; WIFI_PASS="$pass"
    return
  done
}

# ---------------------------------------------------------------- verificações
[[ $EUID -eq 0 ]] || die "execute como root"
[[ -d /sys/firmware/efi/efivars ]] || die "o sistema não iniciou em modo UEFI"
[[ -b $DISK ]] || die "disco $DISK não encontrado (Intel VMD ainda ativo no BIOS?)"
ping -c1 -W3 archlinux.org >/dev/null 2>&1 || die "sem internet — conecte com iwctl"

if [[ $DISK == *nvme* || $DISK == *mmcblk* ]]; then
  ESP="${DISK}p1"; ROOT="${DISK}p2"
else
  ESP="${DISK}1";  ROOT="${DISK}2"
fi

# ---------------------------------------------------------------- perguntas
cat <<'EOF'

=====================================================================
 Responda as perguntas abaixo. Depois disso a instalação segue sozinha
 (a etapa do kernel otimizado leva ~30–40 min).
=====================================================================
EOF

# Cada resposta pode vir pronta de uma variável VB_* (modo sem perguntas,
# usado por "vivobook.answers=" no boot e pelos testes em VM).
yes_or_ask() {   # $1 = valor VB_* (1/0 ou vazio), $2 = pergunta
  if [[ -n $1 ]]; then [[ $1 == 1 ]]; else ask_yes "$2"; fi
}

USERNAME="${VB_USERNAME:-}"
until [[ $USERNAME =~ ^[a-z_][a-z0-9_-]*$ ]]; do
  read -rp "Nome do usuário (minúsculas): " USERNAME
done
if [[ -n ${VB_HOSTNAME:-} ]]; then
  HOST_NAME="$VB_HOSTNAME"
else
  read -rp "Nome do computador [$HOST_NAME]: " h; HOST_NAME="${h:-$HOST_NAME}"
fi
USER_PASS="${VB_USER_PASS:-$(ask_secret "Senha do usuário $USERNAME")}"
ROOT_PASS="${VB_ROOT_PASS:-$(ask_secret "Senha do root (administração/emergência)")}"
LUKS_PASS="${VB_LUKS_PASS:-$(ask_secret "Senha da criptografia do disco (pedida no boot até o TPM ser ativado)")}"

echo
yes_or_ask "${VB_POST:-}"   "Instalar Hyprland + visual Arch + apps (pós-instalação)?"      && DO_POST=1   || DO_POST=0
yes_or_ask "${VB_KERNEL:-}" "Compilar o kernel otimizado para este CPU agora (+30–40 min)?" && DO_KERNEL=1 || DO_KERNEL=0
yes_or_ask "${VB_SB:-}"     "Configurar Secure Boot + desbloqueio automático pelo TPM?"     && DO_SB=1     || DO_SB=0

[[ -n ${WIFI_SSID:-} ]] || detect_iwd_wifi
if [[ -z ${WIFI_SSID:-} && -z ${VB_CONFIRM:-} ]] && ask_yes "Salvar uma rede Wi-Fi no sistema instalado?"; then
  read -rp "  SSID: " WIFI_SSID
  WIFI_PASS="$(ask_secret "  Senha do Wi-Fi")"
fi

echo
echo "Resumo:"
echo "  Disco ........... $DISK (será APAGADO)"
echo "  Usuário/host .... $USERNAME @ $HOST_NAME"
echo "  Wi-Fi salvo ..... ${WIFI_SSID:-(nenhum)}"
echo "  Pós-instalação .. $( ((DO_POST))   && echo sim || echo não)"
echo "  Kernel nativo ... $( ((DO_KERNEL)) && echo sim || echo não)"
echo "  Secure Boot/TPM . $( ((DO_SB))     && echo sim || echo não)"
echo
lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL "$DISK"
echo
confirm="${VB_CONFIRM:-}"
[[ -n $confirm ]] || read -rp "Digite APAGAR para começar: " confirm
[[ $confirm == APAGAR ]] || die "cancelado"

# A partir daqui tudo vai para o log (senhas nunca são impressas)
exec > >(tee -a "$LOG") 2>&1
cleanup() { rm -f /mnt/etc/sudoers.d/99-install 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------- base
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

step "Criptografia LUKS2"
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --batch-mode --type luks2 \
  --label cryptroot --key-file=- "$ROOT"
printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- --allow-discards \
  --perf-no_read_workqueue --perf-no_write_workqueue --persistent "$ROOT" cryptroot
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
  --save /etc/pacman.d/mirrorlist || warn "reflector falhou, usando a lista de espelhos atual"

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
printf 'root:%s\n%s:%s\n' "$ROOT_PASS" "$USERNAME" "$USER_PASS" | arch-chroot /mnt chpasswd

step "Copiando scripts para /home/$USERNAME/arch-linux"
cp -r "$REPO_DIR" "/mnt/home/$USERNAME/arch-linux"
arch-chroot /mnt chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/arch-linux"
U_DIR="/home/$USERNAME/arch-linux/scripts"

step "Tela de boot (Plymouth com identidade Arch)"
arch-chroot /mnt bash "$U_DIR/plymouth-theme.sh" \
  || warn "tema do Plymouth falhou — rode: sudo ~/arch-linux/scripts/plymouth-theme.sh"

# ---------------------------------------------------------------- Wi-Fi
if [[ -n ${WIFI_SSID:-} && -n ${WIFI_PASS:-} ]]; then
  step "Salvando Wi-Fi \"$WIFI_SSID\" no NetworkManager"
  nm="/mnt/etc/NetworkManager/system-connections/wifi-$(printf '%s' "$WIFI_SSID" | tr -c 'A-Za-z0-9_-' '_').nmconnection"
  cat > "$nm" <<EOF
[connection]
id=$WIFI_SSID
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$WIFI_SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PASS

[ipv4]
method=auto

[ipv6]
method=auto
EOF
  chmod 600 "$nm"
fi

# Etapas seguintes rodam como usuário e precisam de sudo sem senha (removido no fim)
# (SNAP_PAC_SKIP: sem snapshots do snap-pac durante a instalação)
printf 'Defaults env_keep += "SNAP_PAC_SKIP"\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$USERNAME" \
  > /mnt/etc/sudoers.d/99-install
chmod 440 /mnt/etc/sudoers.d/99-install

# ---------------------------------------------------------------- Secure Boot (chaves)
SB_ENROLLED=0
if (( DO_SB )); then
  step "Secure Boot: criando chaves (sbctl)"
  arch-chroot /mnt sbctl create-keys
  install -d -m 700 /mnt/var/lib/vivobook
  if efivar_is_1 SetupMode; then
    if arch-chroot /mnt sbctl enroll-keys --microsoft; then
      SB_ENROLLED=1
      touch /mnt/var/lib/vivobook/enrolled
    else
      warn "não foi possível registrar as chaves agora; o sistema tenta de novo no boot"
    fi
  fi
fi

# ---------------------------------------------------------------- pós-instalação
if (( DO_POST )); then
  step "Pós-instalação: sistema"
  arch-chroot /mnt env NONINTERACTIVE=1 SNAP_PAC_SKIP=y bash "$U_DIR/setup-system.sh" \
    || warn "pós-instalação (sistema) falhou — rode ~/arch-linux/scripts/post-install.sh depois"
  step "Pós-instalação: usuário"
  arch-chroot /mnt sudo -u "$USERNAME" -H env NONINTERACTIVE=1 SNAP_PAC_SKIP=y bash "$U_DIR/setup-user.sh" \
    || warn "pós-instalação (usuário) falhou — rode ~/arch-linux/scripts/post-install.sh depois"
fi

# ---------------------------------------------------------------- kernel
if (( DO_KERNEL )); then
  step "Kernel otimizado (-march=native) — ~30–40 min"
  arch-chroot /mnt sudo -u "$USERNAME" -H env NONINTERACTIVE=1 SNAP_PAC_SKIP=y bash "$U_DIR/build-kernel.sh" \
    || warn "compilação do kernel falhou — linux-lts segue como padrão; rode build-kernel.sh depois"
fi

# ---------------------------------------------------------------- Secure Boot (assinaturas + TPM)
RECOVERY_KEY=""
if (( DO_SB )); then
  step "Secure Boot: assinando bootloader e kernels"
  arch-chroot /mnt /bin/bash -e <<'EOF'
sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi
bootctl install --esp-path=/efi
for f in /efi/EFI/Linux/*.efi; do sbctl sign -s "$f"; done
sbctl verify || true
EOF

  step "TPM2: preparando registro automático no primeiro boot com Secure Boot ativo"
  KEY=/mnt/var/lib/vivobook/enroll.key
  dd if=/dev/urandom of="$KEY" bs=64 count=1 status=none
  chmod 400 "$KEY"
  printf '%s' "$LUKS_PASS" | cryptsetup luksAddKey --batch-mode --key-file=- "$ROOT" "$KEY"
  RECOVERY_KEY="$(systemd-cryptenroll --unlock-key-file="$KEY" --recovery-key "$ROOT" 2>/dev/null \
    | grep -Eo '([cbdefghijklnrtuv]{8}-){7}[cbdefghijklnrtuv]{8}' | head -1 || true)"
  [[ -n $RECOVERY_KEY ]] || warn "não foi possível gerar a chave de recuperação; gere depois com: sudo systemd-cryptenroll /dev/disk/by-partlabel/cryptroot --recovery-key"

  install -m 755 "$SCRIPT_DIR/firstboot-secureboot.sh" /mnt/usr/local/sbin/vivobook-secureboot
  cat > /mnt/etc/systemd/system/vivobook-secureboot.service <<'EOF'
[Unit]
Description=Secure Boot + TPM2 (configuração automática do Vivobook)
After=local-fs.target
ConditionPathExists=/var/lib/vivobook/enroll.key

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vivobook-secureboot

[Install]
WantedBy=multi-user.target
EOF
  arch-chroot /mnt systemctl enable vivobook-secureboot.service
fi

# ---------------------------------------------------------------- fim
cleanup
cp "$LOG" /mnt/var/log/vivobook-install.log 2>/dev/null || true

{
  echo
  echo "====================================================================="
  echo " Instalação concluída."
  echo "====================================================================="
  if ((${#WARNINGS[@]})); then
    echo " Avisos:"
    printf '   - %s\n' "${WARNINGS[@]}"
    echo
  fi
  if (( DO_SB )); then
    if (( SB_ENROLLED )); then
      echo " Secure Boot: chaves já registradas. Ao reiniciar, entre no BIOS (F2)"
      echo "   e ATIVE 'Secure Boot Control'. No boot seguinte o TPM é registrado"
      echo "   sozinho; a partir daí o disco desbloqueia sem senha."
    else
      echo " Secure Boot: o firmware não estava em Setup Mode. Ao reiniciar, BIOS (F2) →"
      echo "   Security → Secure Boot → Key Management → apagar todas as chaves."
      echo "   O sistema registra as chaves no boot e avisa quando ativar o Secure Boot."
    fi
    echo
  fi
  if [[ -n $RECOVERY_KEY ]]; then
    echo " CHAVE DE RECUPERAÇÃO DO DISCO — anote/fotografe e guarde FORA do notebook:"
    echo
    echo "   $RECOVERY_KEY"
    echo
  fi
  echo " Log: /var/log/vivobook-install.log"
} > /dev/tty
