#!/usr/bin/env bash
# Instalação pelo Calamares (interface gráfica) com o layout do projeto:
# ESP de 1 GiB em /efi + LUKS2 + Btrfs com os mesmos subvolumes, systemd-boot
# + UKI, linux-lts e Hyprland. O Calamares cuida do disco/criptografia, do
# usuário/senhas, hostname, idioma, fuso e teclado; a base é instalada por
# calamares-pacstrap.sh e o boot por calamares-target.sh. Depois que a janela
# fecha, as etapas extras (Wi-Fi, Plymouth, Hyprland, kernel, Secure Boot/TPM)
# rodam no terminal, como nos outros instaladores.
#
# Executar como root no ambiente live (o auto.sh chama este script na opção 2).
# Aceita as mesmas respostas VB_* dos outros instaladores; com VB_MODE=gui o
# assistente pula o menu. Para o TPM, VB_LUKS_PASS pode trazer a senha do disco
# (se não servir, ela é pedida de novo depois do Calamares).
set -Eeuo pipefail
trap 'echo "ERRO: linha $LINENO: $BASH_COMMAND (status $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LOG=/root/arch-install.log
CALAMARES_LOG="$HOME/.cache/calamares/session.log"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/stages.sh
source "$SCRIPT_DIR/lib/stages.sh"

[[ $EUID -eq 0 ]] || die "execute como root"
[[ -d /sys/firmware/efi/efivars ]] || die "o sistema não iniciou em modo UEFI"
command -v calamares >/dev/null || die "Calamares não encontrado nesta ISO (gere com iso/build.sh)"
command -v startx >/dev/null || die "Xorg/xinit não encontrados nesta ISO"
ping -c1 -W3 archlinux.org >/dev/null 2>&1 || die "sem internet — conecte com iwctl"

cat <<'EOF'

=====================================================================
 Instalação gráfica (Calamares) com o layout do projeto

 1. Responda as etapas extras abaixo (menu no terminal).
 2. O Calamares abre em seguida: particione, crie o usuário e instale.
 3. Ao terminar, feche o Calamares (não reinicie): as etapas extras
    (Wi-Fi, Plymouth, Hyprland, kernel, Secure Boot/TPM) continuam
    automaticamente no terminal.
=====================================================================
EOF

ask_optional_stages

# ---------------------------------------------------------------- Calamares
step "Preparando o instalador gráfico"
sync_clock
# Os scripts usados pelo Calamares (shellprocess) ficam sempre no repo ativo.
rm -rf /run/arch-install
ln -s "$REPO_DIR" /run/arch-install

# Usa as configurações da versão mais recente dos scripts (quando baixados).
if [[ -d $REPO_DIR/iso/calamares ]]; then
  mkdir -p /etc/calamares
  cp -a "$REPO_DIR/iso/calamares/." /etc/calamares/
fi
mkdir -p /etc/calamares/branding/archlinux
cp -f "$REPO_DIR/config/plymouth/watermark.png" \
  /etc/calamares/branding/archlinux/watermark.png 2>/dev/null || true

# Interface em português (o Calamares usa os arquivos de tradução do Qt).
if ! locale -a 2>/dev/null | grep -qi '^pt_BR\.utf8$'; then
  sed -i 's/^#[[:space:]]*\(pt_BR\.UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true
  locale-gen 2>/dev/null || warn "não foi possível gerar o locale pt_BR.UTF-8"
fi

# Sessão X: openbox + Calamares (o arquivo vem do repositório; fallback inline)
if [[ -f $REPO_DIR/iso/xinitrc ]]; then
  install -m 755 "$REPO_DIR/iso/xinitrc" /root/.xinitrc
else
  cat > /root/.xinitrc <<'EOF'
#!/bin/sh
xsetroot -solid '#101418' 2>/dev/null || true
setxkbmap br abnt2 2>/dev/null || true
openbox-session &
exec calamares
EOF
  chmod 755 /root/.xinitrc
fi

step "Abrindo o Calamares (fecha a janela para continuar)"
LANG=pt_BR.UTF-8 LC_ALL=pt_BR.UTF-8 startx -- -nolisten tcp || true

if [[ ! -f /run/arch-install-calamares-ok || ! -s /run/arch-install-root ]]; then
  echo "A instalação gráfica foi cancelada ou não chegou ao fim." >&2
  echo "O sistema pode ter ficado montado; reinicie o live para começar de novo." >&2
  exit 1
fi

MNT="$(cat /run/arch-install-root)"
[[ -d $MNT/etc ]] || die "destino gravado pelo Calamares inválido: $MNT"
findmnt "$MNT" >/dev/null || die "o sistema instalado não está mais montado em $MNT"

exec > >(tee -a "$LOG") 2>&1
trap stages_cleanup EXIT

USERNAME="$(awk -F: '$3 >= 1000 && $3 < 60000 { print $1; exit }' "$MNT/etc/passwd")"
[[ -n $USERNAME ]] || die "nenhum usuário comum criado no Calamares"
ROOT="$(luks_backing_device "$MNT")"
MAPPER=""
SRC="$(findmnt -no SOURCE "$MNT")"; SRC="${SRC%%[*}"
[[ $SRC == /dev/mapper/* ]] && MAPPER="${SRC#/dev/mapper/}"
step "Sistema instalado: usuário $USERNAME, LUKS ${ROOT:-(nenhum)}, mapper ${MAPPER:-(nenhum)}"

if (( DO_SB )); then
  if [[ -z $ROOT ]]; then
    warn "disco sem criptografia LUKS — Secure Boot/TPM ignorados"
    DO_SB=0
  else
    # A senha foi definida dentro do Calamares; VB_LUKS_PASS pode tê-la adiantado.
    LUKS_PASS="${VB_LUKS_PASS:-}"
    until [[ -n $LUKS_PASS ]] \
      && printf '%s' "$LUKS_PASS" | cryptsetup open --test-passphrase --key-file=- "$ROOT" 2>/dev/null; do
      echo "Informe a senha da criptografia definida no Calamares (para preparar o TPM)." > /dev/tty
      LUKS_PASS="$(ask_secret "Senha da criptografia do disco" < /dev/tty)"
    done
  fi
fi

run_stages

cp "$LOG" "$MNT/var/log/arch-install.log" 2>/dev/null || true
if [[ -f $CALAMARES_LOG ]]; then
  cp "$CALAMARES_LOG" "$MNT/var/log/arch-calamares.log" 2>/dev/null || true
fi
print_summary

step "Desmontando o sistema instalado"
umount -R "$MNT" 2>/dev/null || warn "não foi possível desmontar tudo em $MNT"
if [[ -n $MAPPER ]]; then
  cryptsetup close "$MAPPER" 2>/dev/null || warn "não foi possível fechar o mapeamento $MAPPER"
fi
