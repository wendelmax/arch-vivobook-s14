#!/usr/bin/env bash
# Gera uma ISO do Arch Linux (perfil oficial releng) com os scripts deste
# repositório embutidos, o instalador automático no tty1 e o instalador
# gráfico (Calamares + Xorg/openbox) disponível na opção 2 do menu.
#
# Executar como root num Arch Linux x86_64 (ex.: WSL "archlinux"):
#   bash iso/build.sh
#
# O Calamares é compilado do AUR na primeira vez (pode levar ~15 min). Para
# reutilizar um pacote já compilado (ou compilar em outra máquina):
#   CALAMARES_PKG=/caminho/calamares-3.4.2-2-x86_64.pkg.tar.zst bash iso/build.sh
#
# Opcional — Wi-Fi já configurado na ISO (NÃO compartilhe a ISO gerada):
#   WIFI_SSID="MinhaRede" WIFI_PASS="senha" bash iso/build.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/out}"
WORK="${WORK:-/var/tmp/archiso-custom}"   # precisa estar num FS Linux (não /mnt/c)

[[ $EUID -eq 0 ]] || { echo "execute como root" >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo "a ISO x86_64 só pode ser gerada em x86_64" >&2; exit 1; }

# Compila o Calamares do AUR (não existe nos repositórios oficiais).
# O PKGBUILD do AUR não declara python, que é necessário para os módulos
# mount/localecfg/hwclock e para as bindings Python do Calamares.
build_calamares() {
  CAL_PKG=""
  if [[ -n ${CALAMARES_PKG:-} ]]; then
    [[ -f $CALAMARES_PKG ]] || { echo "CALAMARES_PKG não encontrado: $CALAMARES_PKG" >&2; exit 1; }
    CAL_PKG="$CALAMARES_PKG"
    return
  fi

  pacman -S --needed --noconfirm \
    base-devel cmake ninja python extra-cmake-modules libglvnd \
    kcoreaddons kpmcore libpwquality qt6-declarative qt6-svg qt6-tools \
    qt6-translations yaml-cpp

  local dir="$WORK/aur-calamares" pkg
  rm -rf "$dir"
  git clone -q https://aur.archlinux.org/calamares.git "$dir"
  # python em depends (runtime) e makedepends (bindings/módulos Python)
  sed -i "/^depends=(/a\\  'python'" "$dir/PKGBUILD"
  sed -i "/^makedepends=(/a\\  'python'" "$dir/PKGBUILD"

  id builder >/dev/null 2>&1 \
    || useradd -m -s /bin/bash builder
  chown -R builder:builder "$dir"
  ( cd "$dir" && runuser -u builder -- env HOME=/home/builder makepkg -f --noconfirm )

  pkg="$(ls -t "$dir"/calamares-[0-9]*.pkg.tar.zst 2>/dev/null | head -1)"
  [[ -f $pkg ]] || { echo "pacote do Calamares não foi gerado em $dir" >&2; exit 1; }
  # Os módulos usados pelo nosso settings.conf precisam existir no pacote.
  local listing f
  listing="$(bsdtar -tf "$pkg")"
  local m
  for m in welcome locale keyboard partition users summary mount machineid \
           localecfg hwclock shellprocess finished; do
    grep -qxF "usr/lib/calamares/modules/$m/module.desc" <<<"$listing" \
      || { echo "pacote do Calamares sem o módulo $m (PKGBUILD mudou?)" >&2; exit 1; }
  done
  for f in usr/bin/calamares; do
    grep -qxF "$f" <<<"$listing" \
      || { echo "pacote do Calamares sem $f (PKGBUILD mudou?)" >&2; exit 1; }
  done
  CAL_PKG="$pkg"
}

# Em container (Docker/Podman) o sandbox do pacman 7 falha ("error restricting
# syscalls via seccomp"); desliga-o no host de build e no perfil da ISO.
in_container() { [[ -f /.dockerenv || -f /run/.containerenv ]]; }
no_sandbox() { grep -q '^DisableSandbox' "$1" || sed -i '/^\[options\]/a DisableSandbox' "$1"; }
in_container && no_sandbox /etc/pacman.conf

echo "==> Dependências"
pacman -Syu --needed --noconfirm archiso git base-devel cmake ninja python

echo "==> Perfil"
rm -rf "$WORK"
mkdir -p "$WORK" "$OUT_DIR"
cp -r /usr/share/archiso/configs/releng "$WORK/profile"
P="$WORK/profile"

sed -i 's/^iso_name=.*/iso_name="archlinux-custom"/' "$P/profiledef.sh"
in_container && no_sandbox "$P/pacman.conf"

echo "==> Calamares (AUR; na primeira vez leva ~15 min)"
build_calamares
[[ -f $CAL_PKG ]] || { echo "pacote do Calamares não encontrado" >&2; exit 1; }

add_pkg() {
  local p
  for p in "$@"; do
    grep -qxF "$p" "$P/packages.x86_64" || echo "$p" >> "$P/packages.x86_64"
  done
}
# git/terminal do assistente + Calamares e suas dependências de runtime.
# Xorg/openbox: Calamares roda em X11 no tty1 (não em Wayland).
add_pkg git terminus-font python reflector \
  kcoreaddons kpmcore libpwquality qt6-declarative qt6-svg yaml-cpp \
  xorg-server xorg-xinit xorg-xsetroot xorg-setxkbmap xorg-xrandr xorg-xset \
  os-prober python-pyxdg \
  xkeyboard-config openbox mesa hicolor-icon-theme ttf-dejavu qt6-translations \
  btrfs-progs cryptsetup dosfstools parted gptfdisk

# Scripts e configs do repositório
DEST="$P/airootfs/root/arch-linux"
mkdir -p "$DEST/iso"
cp -r "$REPO_DIR/scripts" "$REPO_DIR/config" "$REPO_DIR/GUIA.md" "$REPO_DIR/README.md" "$DEST/"
# Versão embutida (commit e data): o auto.sh só troca por scripts baixados
# da internet se eles forem desta versão ou mais novos.
git -c safe.directory='*' -C "$REPO_DIR" log -1 --format='%H %ct' > "$DEST/VERSION" 2>/dev/null \
  || echo "unknown 0" > "$DEST/VERSION"
cp -r "$REPO_DIR/iso/calamares" "$DEST/iso/"
cp "$REPO_DIR/iso/xinitrc" "$DEST/iso/"

{
  echo 'file_permissions+=(["/root/arch-linux"]="0:0:755")'
  echo 'file_permissions+=(["/root/.xinitrc"]="0:0:755")'
  for f in "$DEST"/scripts/*.sh; do
    echo "file_permissions+=([\"/root/arch-linux/scripts/$(basename "$f")\"]=\"0:0:755\")"
  done
} >> "$P/profiledef.sh"

# Pacote + configuração do Calamares embutidos (instalados no customize).
install -Dm 644 "$CAL_PKG" "$P/airootfs/root/calamares.pkg.tar.zst"
CFG="$P/airootfs/root/calamares-config"
rm -rf "$CFG"
cp -r "$SCRIPT_DIR/calamares" "$CFG"
install -Dm 644 "$REPO_DIR/config/plymouth/watermark.png" \
  "$CFG/branding/archlinux/watermark.png"

# Sessão X do instalador gráfico
install -Dm 755 "$SCRIPT_DIR/xinitrc" "$P/airootfs/root/.xinitrc"

# Roda dentro do chroot do airootfs, depois que os pacotes foram instalados.
cat > "$P/airootfs/root/customize_airootfs.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# Instala o Calamares compilado do AUR (as dependências já estão na ISO) e
# sobrepõe a configuração padrão com a do projeto. O merge mantém os .conf
# dos módulos que não personalizamos (summary, hwclock, localecfg...).
# O airootfs não é ponto de montagem no chroot do mkarchiso: sem CheckSpace,
# senão o pacman falha com "could not determine root mount point /".
sed '/^CheckSpace/d' /etc/pacman.conf > /tmp/pacman-nocheck.conf
pacman --config /tmp/pacman-nocheck.conf -U --noconfirm /root/calamares.pkg.tar.zst
rm -f /tmp/pacman-nocheck.conf
mkdir -p /etc/calamares
cp -a /root/calamares-config/. /etc/calamares/
rm -rf /root/calamares-config /root/calamares.pkg.tar.zst
# Interface em português já gerada no live
if ! locale -a | grep -qi '^pt_BR\.utf8$'; then
  sed -i 's/^#[[:space:]]*\(pt_BR\.UTF-8\)/\1/' /etc/locale.gen
  locale-gen
fi
EOF
chmod 755 "$P/airootfs/root/customize_airootfs.sh"

# Instalador automático só no tty1 (os outros consoles ficam livres)
cat >> "$P/airootfs/root/.zlogin" <<'EOF'

if [[ $(tty) == /dev/tty1 && -z ${ARCH_AUTO_DONE:-} ]]; then
  export ARCH_AUTO_DONE=1
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
