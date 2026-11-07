#!/usr/bin/env bash
# Instalado como /usr/local/sbin/vivobook-secureboot e executado a cada boot
# pelo vivobook-secureboot.service até concluir:
#   1. firmware em Setup Mode  → registra as chaves do sbctl
#   2. Secure Boot ativo       → registra o TPM2 (PCR 7) e remove a chave temporária
# O andamento aparece como notificação no Hyprland (/run/vivobook-status,
# recriado a cada boot enquanto houver pendência).
set -euo pipefail

STATE=/var/lib/vivobook
KEY="$STATE/enroll.key"
STATUS=/run/vivobook-status
GUID=8be4df61-93ca-11d2-aa0d-00e098032b8c

# Partição LUKS por trás do / (vale para o layout próprio e o do archinstall)
root_src="$(findmnt -no SOURCE /)"; root_src="${root_src%%[*}"
DEV="$(cryptsetup status "${root_src#/dev/mapper/}" | awk '$1 == "device:" {print $2}')"
[[ -b $DEV ]] || { echo "partição LUKS do / não encontrada" >&2; exit 1; }

efivar_is_1() {
  local f="/sys/firmware/efi/efivars/$1-$GUID"
  [[ -r $f ]] && [[ $(od -An -t u1 "$f" | awk '{print $NF}') == 1 ]]
}
status() { echo "$*" > "$STATUS"; chmod 644 "$STATUS"; echo "$*"; }

if efivar_is_1 SetupMode; then
  sbctl enroll-keys --microsoft
  touch "$STATE/enrolled"
  status "Chaves do Secure Boot registradas. Reinicie, entre no BIOS (F2) e ATIVE o Secure Boot."
  exit 0
fi

if ! efivar_is_1 SecureBoot; then
  if [[ -f $STATE/enrolled ]]; then
    status "Falta ativar o Secure Boot: reinicie, BIOS (F2) → Security → Secure Boot Control = Enabled."
  else
    status "Para ativar o Secure Boot: BIOS (F2) → Security → Secure Boot → Key Management → apagar todas as chaves e reiniciar."
  fi
  exit 0
fi

# Secure Boot ativo com as nossas chaves → vincula o desbloqueio ao TPM
systemd-cryptenroll "$DEV" --unlock-key-file="$KEY" --wipe-slot=tpm2 \
  --tpm2-device=auto --tpm2-pcrs=7
cryptsetup luksRemoveKey "$DEV" "$KEY"
shred -u "$KEY"
status "TPM ativado: a partir do próximo boot o disco desbloqueia sozinho."
