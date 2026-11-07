# Etapas aplicadas sobre um Arch recém-instalado e montado em $MNT (source).
# Usadas pelo install.sh (layout próprio) e pelo archinstall-run.sh (layout do
# archinstall): ESP, partição LUKS e usuário são detectados, não presumidos.
#
# Variáveis esperadas: MNT, SCRIPT_DIR, REPO_DIR, USERNAME, ROOT (partição LUKS),
#   LUKS_PASS (se DO_SB), DO_POST, DO_KERNEL, DO_SB, WIFI_SSID/WIFI_PASS (opcionais)
# shellcheck shell=bash

SB_ENROLLED=0
RECOVERY_KEY=""

in_target()      { arch-chroot "$MNT" "$@"; }
as_user()        { arch-chroot "$MNT" sudo -u "$USERNAME" -H env NONINTERACTIVE=1 SNAP_PAC_SKIP=y "$@"; }
target_esp()     { in_target bootctl --print-esp-path 2>/dev/null || echo /efi; }
stages_cleanup() { rm -f "$MNT/etc/sudoers.d/99-install" 2>/dev/null || true; }

stage_copy_repo() {
  step "Copiando scripts para /home/$USERNAME/arch-linux"
  rm -rf "$MNT/home/$USERNAME/arch-linux"
  cp -r "$REPO_DIR" "$MNT/home/$USERNAME/arch-linux"
  in_target chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/arch-linux"
  U_DIR="/home/$USERNAME/arch-linux/scripts"
}

stage_tweaks() {   # ajustes que o install.sh já faz na base (para o fluxo archinstall)
  step "Ajustes do sistema (zram, sudo do grupo wheel)"
  [[ -f $MNT/etc/sysctl.d/99-zram.conf ]] || cat > "$MNT/etc/sysctl.d/99-zram.conf" <<'EOF'
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF
  if [[ -f $MNT/etc/kernel/cmdline ]] && ! grep -q 'zswap.enabled' "$MNT/etc/kernel/cmdline"; then
    sed -i 's/$/ zswap.enabled=0/' "$MNT/etc/kernel/cmdline"
  fi
  in_target systemctl enable fstrim.timer systemd-boot-update.service || true
}

stage_plymouth() {
  step "Tela de boot (Plymouth com identidade Arch)"
  in_target bash "$U_DIR/plymouth-theme.sh" \
    || warn "tema do Plymouth falhou — rode: sudo ~/arch-linux/scripts/plymouth-theme.sh"
}

stage_wifi() {
  [[ -n ${WIFI_SSID:-} && -n ${WIFI_PASS:-} ]] || return 0
  step "Salvando Wi-Fi \"$WIFI_SSID\" no NetworkManager"
  local nm
  nm="$MNT/etc/NetworkManager/system-connections/wifi-$(printf '%s' "$WIFI_SSID" | tr -c 'A-Za-z0-9_-' '_').nmconnection"
  mkdir -p "$(dirname "$nm")"
  cat > "$nm" <<EOF
[connection]
id=$WIFI_SSID
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$WIFI_SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PASS

[ipv4]
method=auto

[ipv6]
method=auto
EOF
  chmod 600 "$nm"
}

# As etapas seguintes rodam como usuário e precisam de sudo sem senha
# (removido no fim). SNAP_PAC_SKIP: sem snapshots do snap-pac na instalação.
stage_temp_sudo() {
  printf 'Defaults env_keep += "SNAP_PAC_SKIP"\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$USERNAME" \
    > "$MNT/etc/sudoers.d/99-install"
  chmod 440 "$MNT/etc/sudoers.d/99-install"
}

stage_sb_keys() {
  (( DO_SB )) || return 0
  step "Secure Boot: criando chaves (sbctl)"
  in_target sbctl create-keys
  install -d -m 700 "$MNT/var/lib/vivobook"
  if efivar_is_1 SetupMode; then
    if in_target sbctl enroll-keys --microsoft; then
      SB_ENROLLED=1
      touch "$MNT/var/lib/vivobook/enrolled"
    else
      warn "não foi possível registrar as chaves agora; o sistema tenta de novo no boot"
    fi
  fi
}

stage_post() {
  (( DO_POST )) || return 0
  step "Pós-instalação: sistema"
  in_target env NONINTERACTIVE=1 SNAP_PAC_SKIP=y bash "$U_DIR/setup-system.sh" \
    || warn "pós-instalação (sistema) falhou — rode ~/arch-linux/scripts/post-install.sh depois"
  step "Pós-instalação: usuário"
  as_user bash "$U_DIR/setup-user.sh" \
    || warn "pós-instalação (usuário) falhou — rode ~/arch-linux/scripts/post-install.sh depois"
}

stage_kernel() {
  (( DO_KERNEL )) || return 0
  step "Kernel otimizado (-march=native) — ~30–40 min"
  in_target pacman -S --needed --noconfirm base-devel git \
    || warn "não foi possível instalar base-devel/git para compilar o kernel"
  as_user bash "$U_DIR/build-kernel.sh" \
    || warn "compilação do kernel falhou — linux-lts segue como padrão; rode build-kernel.sh depois"
}

stage_sb_finish() {
  (( DO_SB )) || return 0
  local esp key
  esp="$(target_esp)"

  # Desbloqueio pelo TPM precisa da opção no cmdline (layout do archinstall não tem)
  if [[ -f $MNT/etc/kernel/cmdline ]] && ! grep -q 'tpm2-device' "$MNT/etc/kernel/cmdline"; then
    step "Habilitando desbloqueio via TPM2 na linha de comando do kernel"
    sed -i 's/$/ rd.luks.options=tpm2-device=auto/' "$MNT/etc/kernel/cmdline"
    in_target mkinitcpio -P
  fi

  step "Secure Boot: assinando bootloader e kernels"
  in_target /bin/bash -e <<EOF
sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi
bootctl install --esp-path=$esp
for f in $esp/EFI/Linux/*.efi; do sbctl sign -s "\$f"; done
sbctl verify || true
EOF

  step "TPM2: preparando registro automático no primeiro boot com Secure Boot ativo"
  key="$MNT/var/lib/vivobook/enroll.key"
  install -d -m 700 "$MNT/var/lib/vivobook"
  dd if=/dev/urandom of="$key" bs=64 count=1 status=none
  chmod 400 "$key"
  printf '%s' "$LUKS_PASS" | cryptsetup luksAddKey --batch-mode --key-file=- "$ROOT" "$key"
  RECOVERY_KEY="$(systemd-cryptenroll --unlock-key-file="$key" --recovery-key "$ROOT" 2>/dev/null \
    | grep -Eo '([cbdefghijklnrtuv]{8}-){7}[cbdefghijklnrtuv]{8}' | head -1 || true)"
  [[ -n $RECOVERY_KEY ]] || warn "não foi possível gerar a chave de recuperação; gere depois com: sudo systemd-cryptenroll $ROOT --recovery-key"

  install -m 755 "$SCRIPT_DIR/firstboot-secureboot.sh" "$MNT/usr/local/sbin/vivobook-secureboot"
  cat > "$MNT/etc/systemd/system/vivobook-secureboot.service" <<'EOF'
[Unit]
Description=Secure Boot + TPM2 (configuração automática do Vivobook)
After=local-fs.target
ConditionPathExists=/var/lib/vivobook/enroll.key

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vivobook-secureboot

[Install]
WantedBy=multi-user.target
EOF
  in_target systemctl enable vivobook-secureboot.service
}

# Todas as etapas pós-base, na ordem
run_stages() {
  stage_copy_repo
  [[ ${1:-} == --tweaks ]] && stage_tweaks
  stage_plymouth
  stage_wifi
  stage_temp_sudo
  stage_sb_keys
  stage_post
  stage_kernel
  stage_sb_finish
  stages_cleanup
}

print_summary() {
  {
    echo
    echo "====================================================================="
    echo " Instalação concluída."
    echo "====================================================================="
    if ((${#WARNINGS[@]})); then
      echo " Avisos:"
      printf '   - %s\n' "${WARNINGS[@]}"
      echo
    fi
    if (( DO_SB )); then
      if (( SB_ENROLLED )); then
        echo " Secure Boot: chaves já registradas. Ao reiniciar, entre no BIOS (F2)"
        echo "   e ATIVE 'Secure Boot Control'. No boot seguinte o TPM é registrado"
        echo "   sozinho; a partir daí o disco desbloqueia sem senha."
      else
        echo " Secure Boot: o firmware não estava em Setup Mode. Ao reiniciar, BIOS (F2) →"
        echo "   Security → Secure Boot → Key Management → apagar todas as chaves."
        echo "   O sistema registra as chaves no boot e avisa quando ativar o Secure Boot."
      fi
      echo
    fi
    if [[ -n $RECOVERY_KEY ]]; then
      echo " CHAVE DE RECUPERAÇÃO DO DISCO — anote/fotografe e guarde FORA do notebook:"
      echo
      echo "   $RECOVERY_KEY"
      echo
    fi
    echo " Log: /var/log/vivobook-install.log"
  } > /dev/tty
}
