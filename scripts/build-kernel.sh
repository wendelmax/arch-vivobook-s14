#!/usr/bin/env bash
# Compila e instala o kernel linux-cachyos otimizado para ESTE processador
# (-march=native → Intel Core Ultra 5 225H / Arrow Lake), com Clang ThinLTO.
#
# Só o código-fonte do kernel vem do projeto CachyOS; o sistema continua
# sendo Arch Linux puro (repositórios e identidade oficiais).
#
# Executar como usuário comum. Pede sudo para instalar.
# Variáveis opcionais:
#   LOCALMOD=y   compila só os módulos em uso (requer modprobed-db, ~3x mais rápido)
#   BUILD_DIR=…  diretório de build (padrão ~/build, precisa de ~25 GB)
#   NONINTERACTIVE=1  sem perguntas (usado pelo install.sh no chroot)
#   BUILD_ONLY=1 só compila (pacotes ficam no diretório de build), sem instalar
set -euo pipefail
trap 'echo "ERRO: build-kernel.sh linha $LINENO: $BASH_COMMAND (status $?)" >&2' ERR

BUILD_DIR="${BUILD_DIR:-$HOME/build}"
REPO_URL="https://github.com/CachyOS/linux-cachyos.git"
LOCALMOD="${LOCALMOD:-n}"
BUILD_ONLY="${BUILD_ONLY:-}"

[[ $EUID -ne 0 ]] || { echo "não execute como root" >&2; exit 1; }

mkdir -p "$BUILD_DIR"
if [[ -d $BUILD_DIR/linux-cachyos/.git ]]; then
  git -C "$BUILD_DIR/linux-cachyos" pull --ff-only
else
  git clone --depth 1 "$REPO_URL" "$BUILD_DIR/linux-cachyos"
fi
cd "$BUILD_DIR/linux-cachyos/linux-cachyos"

# O nome da opção "native" mudou entre versões do PKGBUILD
if grep -q 'native_intel' PKGBUILD; then
  export _processor_opt=native_intel
elif grep -qw 'native' PKGBUILD; then
  export _processor_opt=native
else
  echo "AVISO: opção 'native' não encontrada no PKGBUILD — verifique _processor_opt" >&2
fi

# Opções do PKGBUILD do CachyOS (ele compara com "yes"/"no")
export _use_llvm_lto=thin      # Clang + ThinLTO
export _preempt=full           # latência baixa p/ desktop
export _tickrate=full
export _hugepage=always
export _build_zfs=no _build_nvidia_open=no
export MAKEFLAGS="-j$(nproc)"
if [[ $LOCALMOD =~ ^(y|yes|1)$ ]]; then
  export _localmodcfg=yes
  for db in "${XDG_DATA_HOME:-$HOME/.local/share}/modprobed-db/modprobed.db" "$HOME/.config/modprobed.db"; do
    [[ -f $db ]] && { export _localmodcfg_path="$db"; break; }
  done
  [[ -n ${_localmodcfg_path:-} ]] || { echo "LOCALMOD=y, mas a base do modprobed-db não foi encontrada" >&2; exit 1; }
else
  export _localmodcfg=no
fi

# Dependências de build com versão mínima (ex.: pahole>=1:1.32-2) que os
# repositórios oficiais do Arch ainda não têm. Imprime as que faltam.
missing_versioned_deps() {
  local dep name req have
  while read -r dep; do
    name="${dep%%>=*}"; req="${dep#*>=}"
    have="$(pacman -Si "$name" 2>/dev/null | awk -F': ' '/^Version/ {print $2; exit}')"
    if [[ -z $have ]] || (( $(vercmp "$have" "$req") < 0 )); then
      echo "$name>=$req (repositórios: ${have:-ausente})"
    fi
  done < <(awk -F' = ' '/^\tmakedepends = .*>=/ {print $2}' <<<"$1")
}

# (sem pipe direto para o awk: ele sai cedo e o SIGPIPE derruba o script com pipefail)
SRCINFO="$(makepkg --printsrcinfo)"
MISSING="$(missing_versioned_deps "$SRCINFO")"
if [[ -n $MISSING && $_use_llvm_lto != none ]]; then
  echo "AVISO: o build com Clang/ThinLTO precisa de versões que o Arch ainda não publicou:" >&2
  sed 's/^/  - /' <<<"$MISSING" >&2
  echo "AVISO: compilando com GCC (-march=native continua; só o ThinLTO fica de fora)." >&2
  export _use_llvm_lto=none
  SRCINFO="$(makepkg --printsrcinfo)"
fi
PKGBASE="$(awk -F' = ' '/^pkgbase/ {print $2; exit}' <<<"$SRCINFO")"
[[ -n $PKGBASE ]] || { echo "não foi possível ler o pkgbase do PKGBUILD" >&2; exit 1; }

if [[ -n $BUILD_ONLY ]]; then
  echo "==> pkgbase: $PKGBASE | processor_opt: ${_processor_opt:-?} | só compilação"
  MK=(--syncdeps --cleanbuild)
  [[ -n ${NONINTERACTIVE:-} ]] && MK+=(--noconfirm)
  makepkg "${MK[@]}"
  ls -1 ./*.pkg.tar.zst
  exit 0
fi

ESP="$(sudo bootctl --print-esp-path 2>/dev/null || echo /efi)"
UKI="${ESP}/EFI/Linux/arch-${PKGBASE}.efi"
echo "==> pkgbase: $PKGBASE | processor_opt: ${_processor_opt:-?} | UKI: $UKI"

# Preset criado antes da instalação → mkinitcpio gera a UKI na ESP
sudo tee "/etc/mkinitcpio.d/${PKGBASE}.preset" >/dev/null <<EOF
ALL_kver="/boot/vmlinuz-${PKGBASE}"
PRESETS=('default')
default_uki="${UKI}"
EOF

MK=(--syncdeps --install --cleanbuild --clean)
[[ -n ${NONINTERACTIVE:-} ]] && MK+=(--noconfirm)
makepkg "${MK[@]}"

# Torna o kernel otimizado o padrão no systemd-boot (linux-lts fica de reserva)
LOADER="${ESP}/loader/loader.conf"
if sudo grep -q '^default ' "$LOADER" 2>/dev/null; then
  sudo sed -i -E "s|^default .*|default arch-${PKGBASE}.efi|" "$LOADER"
else
  echo "default arch-${PKGBASE}.efi" | sudo tee -a "$LOADER" >/dev/null
fi

# Se o Secure Boot já estiver configurado, garante a assinatura da nova UKI
if sudo test -d /var/lib/sbctl/keys || sudo test -d /usr/share/secureboot/keys; then
  sudo sbctl sign -s "$UKI"
fi

echo "==> Kernel instalado. Reinicie e confira com: uname -r"
