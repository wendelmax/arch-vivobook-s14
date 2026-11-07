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
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-$HOME/build}"
REPO_URL="https://github.com/CachyOS/linux-cachyos.git"
LOCALMOD="${LOCALMOD:-n}"

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

export _use_llvm_lto=thin      # Clang + ThinLTO
export _HZ_ticks=1000          # latência baixa p/ desktop
export _preempt=full
export _tickrate=full
export _hugepage=always
export _localmodcfg="$LOCALMOD"
export _build_zfs=n _build_nvidia=n _build_nvidia_open=n
export MAKEFLAGS="-j$(nproc)"

PKGBASE="$(makepkg --printsrcinfo | awk -F' = ' '/^pkgbase/ {print $2; exit}')"
UKI="/efi/EFI/Linux/arch-${PKGBASE}.efi"
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
sudo sed -i -E "s|^default .*|default arch-${PKGBASE}.efi|" /efi/loader/loader.conf

# Se o Secure Boot já estiver configurado, garante a assinatura da nova UKI
if sudo test -d /var/lib/sbctl/keys || sudo test -d /usr/share/secureboot/keys; then
  sudo sbctl sign -s "$UKI"
fi

echo "==> Kernel instalado. Reinicie e confira com: uname -r"
