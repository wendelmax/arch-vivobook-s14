#!/usr/bin/env bash
# Assistente que abre sozinho no tty1 da ISO personalizada:
# teclado → Wi-Fi → scripts mais recentes → install.sh → reboot.
# Ctrl+C a qualquer momento volta para o shell normal do live ISO.
#
# Instalação sem perguntas: inicie a ISO com o parâmetro
#   vivobook.answers=<URL ou caminho de um arquivo com variáveis VB_*>
# (ver scripts/install.sh). Extras aceitos no arquivo:
#   VB_REPO_URL=<repo git>   origem dos scripts (padrão: GitHub)
#   VB_NO_FETCH=1            usa só os scripts embutidos na ISO
#   VB_AFTER=reboot|poweroff ação no fim, sem esperar Enter
#   VB_SERIAL=1              espelha a saída em /dev/ttyS0 (testes em VM)
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

ANSWERS=""
for arg in $(< /proc/cmdline); do
  case $arg in vivobook.answers=*) ANSWERS="${arg#*=}" ;; esac
done

WIFI=""
for d in /sys/class/net/*; do [[ -d $d/wireless ]] && WIFI="${d##*/}"; done

echo "==> Verificando conexão..."
for _ in $(seq 1 30); do online && break; sleep 1; done   # cabo ou perfil Wi-Fi embutido

until online; do
  [[ -n $WIFI ]] || { echo "Nenhuma placa Wi-Fi encontrada. Conecte um cabo/USB e pressione Enter."; read -r; continue; }
  iwctl station "$WIFI" scan; sleep 3
  iwctl station "$WIFI" get-networks
  read -rp "Rede Wi-Fi (SSID): " SSID
  read -rsp "Senha: " PASS; echo
  iwctl --passphrase "$PASS" station "$WIFI" connect "$SSID"
  for _ in $(seq 1 10); do online && break; sleep 1; done
  if online; then
    export WIFI_SSID="$SSID" WIFI_PASS="$PASS"   # install.sh salva no sistema instalado
  else
    echo "Não conectou. Tente novamente."
  fi
done
echo "==> Conectado."

if [[ -n $ANSWERS ]]; then
  echo "==> Respostas automáticas: $ANSWERS"
  if [[ $ANSWERS == http* ]]; then
    curl -fsSL "$ANSWERS" -o /root/answers.env || { echo "Falha ao baixar as respostas."; exit 1; }
    ANSWERS=/root/answers.env
  fi
  set -a; source "$ANSWERS"; set +a
fi
[[ ${VB_SERIAL:-} == 1 && -w /dev/ttyS0 ]] && exec > >(tee -a /dev/ttyS0) 2>&1

DIR="$EMBEDDED"
if [[ ${VB_NO_FETCH:-} != 1 ]]; then
  REPO_URL="${VB_REPO_URL:-$REPO_URL}"
  echo "==> Buscando a versão mais recente dos scripts ($REPO_URL)..."
  rm -rf "$LATEST"
  if git clone -q --depth 1 "$REPO_URL" "$LATEST" 2>/dev/null && [[ -f $LATEST/scripts/install.sh ]]; then
    DIR="$LATEST"
    echo "    usando $(git -C "$LATEST" log -1 --format='%h %cs %s')"
  else
    echo "    indisponível; usando a cópia embutida na ISO."
  fi
fi

if [[ -z ${VB_CONFIRM:-} ]]; then
  echo
  read -rp "Pressione Enter para iniciar a instalação (Ctrl+C cancela)... " _
fi
if ! bash "$DIR/scripts/install.sh"; then
  echo "VIVOBOOK-INSTALL: FALHOU"
  echo "A instalação falhou. Você está no shell do live ISO (log: /root/vivobook-install.log)."
  exit 1
fi
echo "VIVOBOOK-INSTALL: OK"

umount -R /mnt 2>/dev/null
cryptsetup close cryptroot 2>/dev/null
case ${VB_AFTER:-} in
  poweroff) poweroff ;;
  reboot)   reboot ;;
  *)
    echo
    read -rp "Instalação concluída. Remova o pendrive e pressione Enter para reiniciar... " _
    reboot
    ;;
esac
