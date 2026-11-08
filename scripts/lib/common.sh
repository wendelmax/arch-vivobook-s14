# Funções comuns aos instaladores (source, não executar).
# shellcheck shell=bash

GUID=8be4df61-93ca-11d2-aa0d-00e098032b8c
WARNINGS=()

die()  { echo "ERRO: $*" >&2; exit 1; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { echo "AVISO: $*" >&2; WARNINGS+=("$*"); }

# Relógio certo é obrigatório para o pacman: com a hora atrasada (comum
# depois do Windows, que grava o RTC em hora local), assinaturas recentes
# parecem "do futuro" e o pacstrap falha com "required key missing from
# keyring"/"keyring is not writable". Tenta NTP; se não sincronizar, usa a
# hora do cabeçalho HTTP de um servidor HTTPS.
sync_clock() {
  local i d
  timedatectl set-ntp true 2>/dev/null || true
  for i in $(seq 1 20); do
    [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] && return 0
    sleep 1
  done
  for url in https://archlinux.org https://www.google.com https://cloudflare.com; do
    d="$(curl -sI --max-time 10 "$url" | tr -d '\r' | sed -n 's/^[Dd]ate: //p' | head -1)"
    if [[ -n $d ]] && date -u -s "$d" >/dev/null 2>&1; then
      hwclock --systohc --utc 2>/dev/null || true
      echo "    relógio ajustado pela hora de $url: $(date -u '+%F %T UTC')"
      return 0
    fi
  done
  warn "não foi possível acertar o relógio; se o pacstrap falhar com erro de chave, ajuste a hora (date -s)"
}

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

# Resposta pronta (VB_*=1/0) ou pergunta. $1 = valor VB_*, $2 = pergunta
yes_or_ask() {
  if [[ -n $1 ]]; then [[ $1 == 1 ]]; else ask_yes "$2"; fi
}

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
    if [[ $name == =* ]]; then
      name="$(printf '%s' "${name#=}" | sed 's/../\\x&/g')"
      name="$(printf '%b' "$name")"
    fi
    WIFI_SSID="$name"; WIFI_PASS="$pass"
    return
  done
}

# Partição LUKS por trás do sistema de arquivos montado em $1 (ex.: /mnt ou /)
luks_backing_device() {
  local src name
  src="$(findmnt -no SOURCE "$1")"; src="${src%%[*}"      # tira "[/@]" do btrfs
  name="${src#/dev/mapper/}"
  cryptsetup status "$name" 2>/dev/null | awk '$1 == "device:" {print $2}'
}

# Pergunta as etapas opcionais e o Wi-Fi (respeitando VB_*). Define DO_POST,
# DO_KERNEL, DO_SB, WIFI_SSID, WIFI_PASS.
ask_optional_stages() {
  echo
  yes_or_ask "${VB_POST:-}"   "Instalar Hyprland + visual Arch + apps (pós-instalação)?"      && DO_POST=1   || DO_POST=0
  yes_or_ask "${VB_KERNEL:-}" "Compilar o kernel otimizado para este CPU agora (+30–40 min)?" && DO_KERNEL=1 || DO_KERNEL=0
  yes_or_ask "${VB_SB:-}"     "Configurar Secure Boot + desbloqueio automático pelo TPM?"     && DO_SB=1     || DO_SB=0

  [[ -n ${WIFI_SSID:-} ]] || detect_iwd_wifi
  if [[ -z ${WIFI_SSID:-} && -z ${VB_CONFIRM:-} ]] && ask_yes "Salvar uma rede Wi-Fi no sistema instalado?"; then
    read -rp "  SSID: " WIFI_SSID
    WIFI_PASS="$(ask_secret "  Senha do Wi-Fi")"
  fi
}
