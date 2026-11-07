#!/usr/bin/env bash
# Secure Boot com chaves próprias (sbctl) + desbloqueio LUKS via TPM2.
#
#   sudo ./secureboot-tpm.sh keys   # com o firmware em Setup Mode
#   sudo ./secureboot-tpm.sh tpm    # depois de ativar o Secure Boot no BIOS
set -euo pipefail

EFIVARS=/sys/firmware/efi/efivars
GUID=8be4df61-93ca-11d2-aa0d-00e098032b8c

[[ $EUID -eq 0 ]] || { echo "execute com sudo" >&2; exit 1; }

# Partição LUKS por trás do / e ESP (vale para o layout próprio e o do archinstall)
root_src="$(findmnt -no SOURCE /)"; root_src="${root_src%%[*}"
LUKS_DEV="$(cryptsetup status "${root_src#/dev/mapper/}" | awk '$1 == "device:" {print $2}')"
ESP="$(bootctl --print-esp-path 2>/dev/null || echo /efi)"

efivar_is_1() {
  local f="$EFIVARS/$1-$GUID"
  [[ -r $f ]] && [[ $(od -An -t u1 "$f" | awk '{print $NF}') == 1 ]]
}

case "${1:-}" in
  keys)
    if ! efivar_is_1 SetupMode; then
      echo "Firmware não está em Setup Mode."
      echo "BIOS (F2) → Security → Secure Boot → Key Management → apagar todas as chaves."
      exit 1
    fi
    [[ -d /var/lib/sbctl/keys || -d /usr/share/secureboot/keys ]] || sbctl create-keys
    sbctl enroll-keys --microsoft
    sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
      /usr/lib/systemd/boot/efi/systemd-bootx64.efi
    bootctl install --esp-path="$ESP"
    for f in "$ESP"/EFI/Linux/*.efi; do sbctl sign -s "$f"; done
    sbctl verify
    echo
    echo "Agora reinicie, ATIVE o Secure Boot no BIOS e rode: sudo $0 tpm"
    ;;
  tpm)
    efivar_is_1 SecureBoot || { echo "Secure Boot não está ativo" >&2; exit 1; }
    echo "Chave de recuperação — ANOTE e guarde FORA do notebook:"
    systemd-cryptenroll "$LUKS_DEV" --recovery-key
    systemd-cryptenroll "$LUKS_DEV" --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7
    echo "Pronto: o disco será desbloqueado pelo TPM enquanto o Secure Boot estiver íntegro."
    ;;
  *)
    echo "uso: sudo $0 {keys|tpm}" >&2
    exit 1
    ;;
esac
