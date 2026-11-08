# Pacotes da instalação base, compartilhados pelos instaladores (source).
# shellcheck shell=bash
PACKAGES=(
  base base-devel linux-lts linux-lts-headers linux-firmware intel-ucode
  sof-firmware alsa-ucm-conf
  btrfs-progs cryptsetup dosfstools tpm2-tss sbctl
  networkmanager zram-generator reflector plymouth
  sudo nano neovim git man-db man-pages bash-completion terminus-font
)
