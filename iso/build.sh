#!/usr/bin/env bash
# Gera uma ISO do Arch Linux (perfil oficial releng) com os scripts deste
# repositório embutidos e o instalador automático iniciando no tty1.
#
# Executar como root num Arch Linux (ex.: WSL "archlinux"):
#   bash iso/build.sh
#
# Opcional — Wi-Fi já configurado na ISO (NÃO compartilhe a ISO gerada):
#   WIFI_SSID="MinhaRede" WIFI_PASS="senha" bash iso/build.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/out}"
WORK="${WORK:-/var/tmp/archiso-vivobook}"   # precisa estar num FS Linux (não /mnt/c)

[[ $EUID -eq 0 ]] || { echo "execute como root" >&2; exit 1; }

echo "==> Dependências"
pacman -Syu --needed --noconfirm archiso git

echo "==> Perfil"
rm -rf "$WORK"
mkdir -p "$WORK" "$OUT_DIR"
cp -r /usr/share/archiso/configs/releng "$WORK/profile"
P="$WORK/profile"

sed -i 's/^iso_name=.*/iso_name="archlinux-vivobook"/' "$P/profiledef.sh"
printf '%s\n' git terminus-font >> "$P/packages.x86_64"

# Scripts e configs do repositório
DEST="$P/airootfs/root/arch-linux"
mkdir -p "$DEST"
cp -r "$REPO_DIR/scripts" "$REPO_DIR/config" "$REPO_DIR/GUIA.md" "$REPO_DIR/README.md" "$DEST/"

{
  echo 'file_permissions+=(["/root/arch-linux"]="0:0:755")'
  for f in "$DEST"/scripts/*.sh; do
    echo "file_permissions+=([\"/root/arch-linux/scripts/$(basename "$f")\"]=\"0:0:755\")"
  done
} >> "$P/profiledef.sh"

# Instalador automático só no tty1 (os outros consoles ficam livres)
cat >> "$P/airootfs/root/.zlogin" <<'EOF'

if [[ $(tty) == /dev/tty1 && -z ${VIVOBOOK_AUTO_DONE:-} ]]; then
  export VIVOBOOK_AUTO_DONE=1
  bash /root/arch-linux/scripts/auto.sh
fi
EOF

# Wi-Fi opcional embutido (perfil do iwd)
if [[ -n ${WIFI_SSID:-} && -n ${WIFI_PASS:-} ]]; then
  if [[ $WIFI_SSID =~ ^[A-Za-z0-9_\ -]+$ ]]; then
    name="$WIFI_SSID"
  else
    name="=$(printf '%s' "$WIFI_SSID" | od -An -tx1 | tr -d ' \n')"
  fi
  mkdir -p "$P/airootfs/var/lib/iwd"
  printf '[Security]\nPassphrase=%s\n' "$WIFI_PASS" > "$P/airootfs/var/lib/iwd/$name.psk"
  {
    echo 'file_permissions+=(["/var/lib/iwd"]="0:0:700")'
    echo "file_permissions+=([\"/var/lib/iwd/$name.psk\"]=\"0:0:600\")"
  } >> "$P/profiledef.sh"
  echo "==> Wi-Fi \"$WIFI_SSID\" embutido — não compartilhe esta ISO."
fi

echo "==> Gerando ISO (alguns minutos)"
mkarchiso -v -w "$WORK/work" -o "$OUT_DIR" "$P"
rm -rf "$WORK"

ls -lh "$OUT_DIR"/*.iso
echo "==> Pronto. Copie a ISO para o pendrive Ventoy (ou grave com Rufus em modo DD)."
