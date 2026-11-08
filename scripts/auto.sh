#!/usr/bin/env bash
# Assistente que abre sozinho no tty1 da ISO personalizada:
# teclado → Wi-Fi → scripts mais recentes → install.sh → reboot.
# Ctrl+C a qualquer momento volta para o shell normal do live ISO.
#
# Instalação sem perguntas: inicie a ISO com o parâmetro
#   arch.answers=<URL ou caminho de um arquivo com variáveis VB_*>
# (ver scripts/install.sh). Extras aceitos no arquivo:
#   VB_REPO_URL=<repo git>   origem dos scripts (padrão: GitHub)
#   VB_NO_FETCH=1            usa só os scripts embutidos na ISO
#   VB_AFTER=reboot|poweroff ação no fim, sem esperar Enter
#   VB_SERIAL=1              espelha a saída em /dev/ttyS0 (testes em VM)
#   VB_MODE=auto|gui|archinstall instalador (sem o menu de escolha)
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

  Instalador automático — Arch Linux
  Ctrl+C para sair para o shell.

EOF

online() { ping -c1 -W3 archlinux.org &>/dev/null; }

ANSWERS=""
for arg in $(< /proc/cmdline); do
  case $arg in arch.answers=*) ANSWERS="${arg#*=}" ;; esac
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
  echo "==> Buscando a versão mais recente dos scripts..."
  rm -rf "$LATEST"
  # --depth não funciona em servidores HTTP simples (ex.: teste em VM): tenta sem
  if { git clone -q --depth 1 "$REPO_URL" "$LATEST" 2>/dev/null \
       || { rm -rf "$LATEST"; git clone -q "$REPO_URL" "$LATEST" 2>/dev/null; }; } \
     && [[ -f $LATEST/scripts/install.sh ]]; then
    # Nunca troca por uma versão mais antiga que a da ISO (ex.: ISO gerada de
    # uma branch ainda não mesclada na main).
    emb_ts=0; [[ -f $EMBEDDED/VERSION ]] && read -r _ emb_ts < "$EMBEDDED/VERSION"
    new_ts="$(git -C "$LATEST" log -1 --format='%ct')"
    if (( ${new_ts:-0} >= ${emb_ts:-0} )); then
      DIR="$LATEST"
      echo "    usando $(git -C "$LATEST" log -1 --format='%h %cs %s')"
    else
      echo "    a versão online é mais antiga que a da ISO; usando a cópia embutida."
    fi
  else
    echo "    indisponível; usando a cópia embutida na ISO."
  fi
fi

GUI=0
command -v calamares >/dev/null && GUI=1

valid_mode() {
  case $1 in
    auto|archinstall) return 0 ;;
    gui) (( GUI )) ;;
    *) return 1 ;;
  esac
}

MODE="${VB_MODE:-}"
if [[ -n $MODE ]] && ! valid_mode "$MODE"; then
  if [[ $MODE == gui ]]; then
    echo "Calamares não está disponível nesta ISO — use a opção automática." >&2
    exit 1
  fi
  MODE=""
fi

until valid_mode "$MODE"; do
  if (( GUI )); then
    cat <<'EOF'

Como instalar?
  1) Automática             — perguntas no início, depois segue sozinha (recomendada)
  2) Gráfica (Calamares)     — disco/criptografia/usuário numa interface;
                               as etapas extras continuam no terminal
  3) archinstall             — menu oficial com as nossas configurações pré-carregadas,
                               para revisar/ajustar tudo antes de instalar
  4) Sair para o shell
EOF
    read -rp "Opção [1]: " op
    case ${op:-1} in
      1) MODE=auto ;;
      2) MODE=gui ;;
      3) MODE=archinstall ;;
      4) exit 0 ;;
    esac
  else
    cat <<'EOF'

Como instalar?
  1) Automática             — perguntas no início, depois segue sozinha (recomendada)
  2) archinstall             — menu oficial com as nossas configurações pré-carregadas,
                               para revisar/ajustar tudo antes de instalar
  3) Sair para o shell
EOF
    read -rp "Opção [1]: " op
    case ${op:-1} in
      1) MODE=auto ;;
      2) MODE=archinstall ;;
      3) exit 0 ;;
    esac
  fi
done

case $MODE in
  auto)        INSTALLER="$DIR/scripts/install.sh" ;;
  gui)         INSTALLER="$DIR/scripts/gui.sh" ;;
  archinstall) INSTALLER="$DIR/scripts/archinstall-run.sh" ;;
esac

if ! bash "$INSTALLER"; then
  echo "ARCH-INSTALL: FALHOU"
  echo "A instalação falhou. Você está no shell do live ISO (log: /root/arch-install.log)."
  exit 1
fi
echo "ARCH-INSTALL: OK"

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
