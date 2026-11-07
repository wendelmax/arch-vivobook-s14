#!/usr/bin/env bash
# Assistente que abre sozinho no tty1 da ISO personalizada:
# teclado → Wi-Fi → scripts mais recentes → install.sh → reboot.
# Ctrl+C a qualquer momento volta para o shell normal do live ISO.
set -uo pipefail

REPO_URL="https://github.com/wendelmax/arch-vivobook-s14"
EMBEDDED="/root/arch-linux"
LATEST="/root/arch-latest"

loadkeys br-abnt2
setfont ter-v24n 2>/dev/null || true
clear

cat <<'EOF'
   ___             __      __   _               __
  / _ | ________  / /  ___ \ \ / (_)  _____    / /  ___  ___  / /__
 / __ |/ __/ __/ / _ \/___/ \ V / / |/ / _ \  / _ \/ _ \/ _ \/  '_/
/_/ |_/_/  \__/ /_//_/       \_/_/|___/\___/ /_.__/\___/\___/_/\_\

  Instalador automático — Arch Linux no ASUS Vivobook S14 (S3407CA)
  Ctrl+C para sair para o shell.

EOF

online() { ping -c1 -W3 archlinux.org &>/dev/null; }

WIFI=""
for d in /sys/class/net/*; do [[ -d $d/wireless ]] && WIFI="${d##*/}"; done

echo "==> Verificando conexão..."
for _ in $(seq 1 15); do online && break; sleep 1; done   # perfil Wi-Fi embutido conecta sozinho

until online; do
  [[ -n $WIFI ]] || { echo "Nenhuma placa Wi-Fi encontrada. Conecte um cabo/USB e pressione Enter."; read -r; continue; }
  iwctl station "$WIFI" scan; sleep 3
  iwctl station "$WIFI" get-networks
  read -rp "Rede Wi-Fi (SSID): " SSID
  read -rsp "Senha: " PASS; echo
  iwctl --passphrase "$PASS" station "$WIFI" connect "$SSID"
  for _ in $(seq 1 10); do online && break; sleep 1; done
  online || echo "Não conectou. Tente novamente."
done
echo "==> Conectado."

DIR="$EMBEDDED"
echo "==> Buscando a versão mais recente dos scripts..."
rm -rf "$LATEST"
if git clone -q --depth 1 "$REPO_URL" "$LATEST" 2>/dev/null && [[ -f $LATEST/scripts/install.sh ]]; then
  DIR="$LATEST"
  echo "    usando $REPO_URL ($(git -C "$LATEST" log -1 --format='%h %cs'))"
else
  echo "    GitHub indisponível; usando a cópia embutida na ISO."
fi

echo
read -rp "Pressione Enter para iniciar a instalação (Ctrl+C cancela)... " _
bash "$DIR/scripts/install.sh" || { echo "A instalação falhou. Você está no shell do live ISO."; exit 1; }

umount -R /mnt 2>/dev/null
cryptsetup close cryptroot 2>/dev/null
echo
read -rp "Instalação concluída. Remova o pendrive e pressione Enter para reiniciar... " _
reboot
