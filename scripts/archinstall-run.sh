#!/usr/bin/env bash
# Instalação pelo archinstall oficial, com as configurações do projeto já
# carregadas no menu (disco, LUKS, Btrfs, UKI, pt_BR, rede, áudio...). Você
# revisa/ajusta o que quiser, define usuário e senhas e manda instalar.
# Ao terminar, escolha "Sair" no archinstall: este script continua com as
# etapas próprias (Wi-Fi, Plymouth Arch, Hyprland, kernel nativo, Secure Boot+TPM).
#
# Executar como root no ambiente live. Aceita as mesmas respostas VB_* do
# install.sh; com VB_CONFIRM=APAGAR roda o archinstall em modo --silent.
set -euo pipefail

DISK="${DISK:-/dev/nvme0n1}"
HOST_NAME="${VB_HOSTNAME:-${HOST_NAME:-vivobook}}"
MNT=/mnt
LOG=/root/vivobook-install.log
CFG_DIR=/root/archinstall

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/stages.sh
source "$SCRIPT_DIR/lib/stages.sh"

[[ $EUID -eq 0 ]] || die "execute como root"
[[ -d /sys/firmware/efi/efivars ]] || die "o sistema não iniciou em modo UEFI"
[[ -b $DISK ]] || die "disco $DISK não encontrado (Intel VMD ainda ativo no BIOS?)"
command -v archinstall >/dev/null || die "archinstall não encontrado no live"
ping -c1 -W3 archlinux.org >/dev/null 2>&1 || die "sem internet — conecte com iwctl"

cat <<'EOF'

=====================================================================
 Instalação via archinstall (com as configurações do Vivobook)
 1. Responda as perguntas das etapas extras abaixo.
 2. No menu do archinstall, revise tudo e defina usuário/senhas.
 3. Ao final do archinstall, escolha "Sair" (NÃO reiniciar) para
    concluir as etapas extras.
=====================================================================
EOF

ask_optional_stages
LUKS_PASS="${VB_LUKS_PASS:-}"
if (( DO_SB )) && [[ -z $LUKS_PASS ]]; then
  echo
  echo "A senha do disco será pré-preenchida no archinstall e usada para preparar o TPM."
  LUKS_PASS="$(ask_secret "Senha da criptografia do disco")"
fi

# ---------------------------------------------------------------- archinstall
step "Gerando configuração do archinstall para $DISK"
GEN=(python3 "$SCRIPT_DIR/archinstall-config.py" --disk "$DISK" --out "$CFG_DIR" --hostname "$HOST_NAME")
[[ -n $LUKS_PASS ]] && GEN+=(--luks-password "$LUKS_PASS")
if [[ -n ${VB_CONFIRM:-} ]]; then
  [[ $VB_CONFIRM == APAGAR ]] || die "cancelado"
  GEN+=(--user "$VB_USERNAME" --password "$VB_USER_PASS" --root-password "${VB_ROOT_PASS:-$VB_USER_PASS}")
fi
"${GEN[@]}"

AI=(archinstall --config "$CFG_DIR/user_configuration.json")
[[ -f $CFG_DIR/user_credentials.json ]] && AI+=(--creds "$CFG_DIR/user_credentials.json")
[[ -n ${VB_CONFIRM:-} ]] && AI+=(--silent)

umount -R "$MNT" 2>/dev/null || true
"${AI[@]}" || die "o archinstall terminou com erro (log em /var/log/archinstall)"
# Credenciais não ficam no live depois de usadas
rm -f "$CFG_DIR/user_credentials.json"

findmnt "$MNT" >/dev/null || die "o sistema instalado não está montado em $MNT (o archinstall foi cancelado?)"

# ---------------------------------------------------------------- etapas extras
exec > >(tee -a "$LOG") 2>&1
trap stages_cleanup EXIT

USERNAME="$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}' "$MNT/etc/passwd")"
[[ -n $USERNAME ]] || die "nenhum usuário comum criado no archinstall"
ROOT="$(luks_backing_device "$MNT")"
step "Sistema instalado: usuário $USERNAME, partição LUKS ${ROOT:-(nenhuma)}"

if (( DO_SB )); then
  if [[ -z $ROOT ]]; then
    warn "disco sem criptografia LUKS — Secure Boot/TPM ignorados"
    DO_SB=0
  else
    # A senha pode ter sido trocada no menu do archinstall
    until printf '%s' "$LUKS_PASS" | cryptsetup open --test-passphrase --key-file=- "$ROOT" 2>/dev/null; do
      echo "A senha do disco não confere (alterada no archinstall?)." > /dev/tty
      LUKS_PASS="$(ask_secret "Senha da criptografia do disco" < /dev/tty)"
    done
  fi
fi

run_stages --tweaks

cp "$LOG" "$MNT/var/log/vivobook-install.log" 2>/dev/null || true
print_summary
