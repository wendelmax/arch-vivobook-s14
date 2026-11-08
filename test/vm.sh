#!/usr/bin/env bash
# Testa a ISO personalizada numa VM QEMU parecida com o notebook:
# UEFI com Secure Boot em Setup Mode, TPM2 emulado (swtpm) e disco NVMe.
#
# Executar como root num Arch com /dev/kvm (ex.: WSL "archlinux"):
#   test/vm.sh install         instala sem perguntas (test/answers.env) e desliga
#                              (VM_ANSWERS_EXTRA="VB_KERNEL=1" sobrescreve respostas;
#                               VM_MEM/VM_CPUS ajustam a VM)
#   test/vm.sh gui             abre a ISO no Calamares via VNC para testar a
#                              instalação gráfica (VM_VNC_DISPLAY=1 → 127.0.0.1:5901)
#   test/vm.sh boot            inicia o disco instalado em segundo plano
#   test/vm.sh type <texto>    digita texto + Enter na VM (ex.: senha do LUKS)
#   test/vm.sh key <tecla>     envia uma tecla (ex.: ret, esc, ctrl-alt-f2)
#   test/vm.sh shot <arq.png>  captura a tela
#   test/vm.sh stop            desliga a VM
#   test/vm.sh reset           apaga disco, TPM e NVRAM (volta ao "notebook novo")
#
# Os scripts usados na instalação vêm do commit atual deste repositório
# (servido por HTTP para a VM), então commite antes de testar. Para testar
# mudanças ainda não commitadas: VM_WORKTREE=1 (o harness cria um commit
# temporário só dentro da VM, sem tocar no repositório).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
VM="${VM_DIR:-/var/tmp/arch-vm}"
MEM="${VM_MEM:-5G}"
CPUS="${VM_CPUS:-8}"
PORT="${VM_HTTP_PORT:-8000}"
if [[ $(uname -s) == Darwin ]]; then
  # macOS (Homebrew: qemu swtpm xorriso). Em Apple Silicon não há KVM: o
  # x86_64 é emulado (TCG), então tudo fica bem mais lento.
  QEMU_SHARE="$(brew --prefix qemu 2>/dev/null || echo /opt/homebrew)/share/qemu"
  CODE="$QEMU_SHARE/edk2-x86_64-secure-code.fd"
  VARS_TEMPLATE="$QEMU_SHARE/edk2-i386-vars.fd"
  VM="${VM_DIR:-$HOME/.cache/arch-vm}"
else
  CODE=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd
  VARS_TEMPLATE=/usr/share/edk2/x64/OVMF_VARS.4m.fd
  [[ $EUID -eq 0 ]] || { echo "execute como root" >&2; exit 1; }
fi
# Aceleração: KVM no Linux; sem ela, emulação TCG (lenta, mas funciona).
if [[ -e /dev/kvm ]]; then
  ACCEL=(-enable-kvm -cpu host)
else
  echo "aviso: sem /dev/kvm — usando emulação TCG (lenta)" >&2
  ACCEL=(-accel tcg,thread=multi,tb-size=1024 -cpu max)
fi

deps() {
  command -v qemu-system-x86_64 >/dev/null && command -v swtpm >/dev/null \
    && [[ -f $CODE ]] && command -v osirrox >/dev/null && return
  if [[ $(uname -s) == Darwin ]]; then
    brew install qemu swtpm xorriso
  else
    pacman -S --needed --noconfirm qemu-base edk2-ovmf swtpm libisoburn python
  fi
}

monitor() {   # envia um comando ao monitor do QEMU
  python3 - "$VM/monitor.sock" "$*" <<'EOF'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
time.sleep(0.2); s.recv(65536)
s.sendall((sys.argv[2] + "\n").encode()); time.sleep(0.3)
try:
    out = s.recv(65536).decode(errors="replace")
    print("\n".join(l for l in out.splitlines() if l and not l.startswith("(qemu)")))
except Exception:
    pass
EOF
}

prepare() {
  deps
  mkdir -p "$VM/tpm" "$VM/www"
  [[ -f $VM/disk.qcow2 ]] || qemu-img create -q -f qcow2 "$VM/disk.qcow2" 64G
  [[ -f $VM/vars.fd ]]    || cp "$VARS_TEMPLATE" "$VM/vars.fd"
  pkill -f "swtpm socket --tpmstate dir=$VM/tpm" 2>/dev/null || true
  swtpm socket --tpm2 --tpmstate dir="$VM/tpm" \
    --ctrl type=unixio,path="$VM/swtpm.sock" --log file="$VM/swtpm.log" --daemon
  for _ in $(seq 1 20); do [[ -S $VM/swtpm.sock ]] && break; sleep 0.2; done
}

qemu_common() {
  QEMU=(qemu-system-x86_64 "${ACCEL[@]}" -machine q35,smm=on -smp "$CPUS" -m "$MEM"
    -global driver=cfi.pflash01,property=secure,value=on
    -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on
    -drive if=pflash,format=raw,unit=1,file="$VM/vars.fd"
    -chardev socket,id=chrtpm,path="$VM/swtpm.sock"
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0
    -drive file="$VM/disk.qcow2",if=none,id=nvm,format=qcow2 -device nvme,serial=archnvme,drive=nvm
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0
    -vga std -display none
    -monitor unix:"$VM/monitor.sock",server,nowait
    -qmp unix:"$VM/qmp.sock",server,nowait)
}

latest_iso() { ls -t "$REPO_DIR"/iso/out/*.iso 2>/dev/null | head -1; }

extract_boot() {   # kernel/initramfs/entrada da ISO para boot direto
  local iso="$1"
  osirrox -indev "$iso" -extract /arch/boot/x86_64/vmlinuz-linux "$VM/vmlinuz" \
    -extract /arch/boot/x86_64/initramfs-linux.img "$VM/initramfs.img" \
    -extract /loader/entries/01-archiso-linux.conf "$VM/entry.conf" >/dev/null 2>&1
}

serve_repo() {   # $1 = arquivo de respostas; demais args = linhas VB_* extras
  local out="$1"; shift
  rm -rf "$VM/www/repo.git"
  if [[ ${VM_WORKTREE:-} == 1 ]]; then
    # Inclui alterações não commitadas num commit temporário (só na VM).
    local src="$VM/repo-src"
    rm -rf "$src"
    git clone -q "$REPO_DIR" "$src"
    tar -C "$REPO_DIR" --exclude='./.git' --exclude='./iso/out' -cf - . | tar -C "$src" -xf -
    git -C "$src" add -A
    git -C "$src" -c user.name=arch-test -c user.email=test@localhost \
      commit -qm "working tree para teste em VM"
    git clone -q --bare "$src" "$VM/www/repo.git"
  else
    git -c safe.directory='*' clone -q --bare "$REPO_DIR" "$VM/www/repo.git"
  fi
  git -C "$VM/www/repo.git" update-server-info
  cp "$SCRIPT_DIR/answers.env" "$out"
  echo "VB_REPO_URL=http://10.0.2.2:$PORT/repo.git" >> "$out"
  # Sobrescritas pontuais, ex.: VM_ANSWERS_EXTRA="VB_KERNEL=1"
  [[ -n ${VM_ANSWERS_EXTRA:-} ]] && printf '%s\n' $VM_ANSWERS_EXTRA >> "$out"
  local line; for line in "$@"; do printf '%s\n' "$line" >> "$out"; done
  python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$VM/www" >"$VM/http.log" 2>&1 &
  HTTP_PID=$!
  trap 'kill "${HTTP_PID:-}" 2>/dev/null || true' EXIT
}

cmd_install() {
  local iso="${ISO:-$(latest_iso)}"
  [[ -f $iso ]] || { echo "ISO não encontrada (gere com iso/build.sh)" >&2; exit 1; }
  prepare

  extract_boot "$iso"
  local opts; opts="$(sed -n 's/^options[[:space:]]*//p' "$VM/entry.conf")"

  serve_repo "$VM/www/answers.env"

  echo "==> Instalando na VM (acompanhe: tail -f $VM/serial-install.log)"
  qemu_common
  "${QEMU[@]}" -drive file="$iso",media=cdrom,readonly=on,if=ide \
    -kernel "$VM/vmlinuz" -initrd "$VM/initramfs.img" \
    -append "$opts arch.answers=http://10.0.2.2:$PORT/answers.env console=tty0 console=ttyS0,115200" \
    -serial file:"$VM/serial-install.log"

  if grep -q 'ARCH-INSTALL: OK' "$VM/serial-install.log"; then
    echo "==> RESULTADO: instalação OK"
  else
    echo "==> RESULTADO: instalação FALHOU (veja $VM/serial-install.log)"; exit 1
  fi
}

cmd_gui() {   # instalação gráfica manual: Calamares no tty1 via VNC
  local iso="${ISO:-$(latest_iso)}"
  [[ -f $iso ]] || { echo "ISO não encontrada (gere com iso/build.sh)" >&2; exit 1; }
  prepare

  extract_boot "$iso"
  local opts; opts="$(sed -n 's/^options[[:space:]]*//p' "$VM/entry.conf")"

  serve_repo "$VM/www/answers-gui.env" "VB_MODE=gui"

  echo "==> VNC: 127.0.0.1:590${VM_VNC_DISPLAY:-1} (ex.: vncviewer 127.0.0.1:590${VM_VNC_DISPLAY:-1})"
  echo "    Use o Calamares na janela; o terminal (etapas extras/LUKS) aparece na mesma tela."
  echo "    Log do terminal: $VM/serial-gui.log"
  qemu_common
  "${QEMU[@]}" -drive file="$iso",media=cdrom,readonly=on,if=ide \
    -kernel "$VM/vmlinuz" -initrd "$VM/initramfs.img" \
    -append "$opts arch.answers=http://10.0.2.2:$PORT/answers-gui.env console=tty0 console=ttyS0,115200" \
    -serial file:"$VM/serial-gui.log" \
    -vnc "127.0.0.1:${VM_VNC_DISPLAY:-1}" \
    -device qemu-xhci -device usb-tablet || true

  if grep -q 'ARCH-INSTALL: OK' "$VM/serial-gui.log"; then
    echo "==> RESULTADO: instalação gráfica OK"
  else
    echo "==> RESULTADO: instalação gráfica não concluída (veja $VM/serial-gui.log)"; exit 1
  fi
}

cmd_boot() {
  prepare
  qemu_common
  # VM_SERIAL=none simula o notebook (sem porta serial, que faz o Plymouth usar modo texto)
  "${QEMU[@]}" -serial "${VM_SERIAL:-file:$VM/serial-boot.log}" -daemonize -pidfile "$VM/qemu.pid"
  echo "==> VM iniciada (pid $(cat "$VM/qemu.pid")). Use: type/key/shot/stop"
}

cmd_type() {
  local text="$*" c
  for ((i = 0; i < ${#text}; i++)); do
    c="${text:i:1}"
    case $c in
      [a-z0-9]) monitor "sendkey $c" >/dev/null ;;
      [A-Z])    monitor "sendkey shift-${c,,}" >/dev/null ;;
      ' ')      monitor "sendkey spc" >/dev/null ;;
      '-')      monitor "sendkey minus" >/dev/null ;;
      '.')      monitor "sendkey dot" >/dev/null ;;
      # posições do teclado ABNT2 (console da VM em br-abnt2)
      '/')      monitor "sendkey ro" >/dev/null ;;
      ':')      monitor "sendkey shift-slash" >/dev/null ;;
      '=')      monitor "sendkey equal" >/dev/null ;;
      '_')      monitor "sendkey shift-minus" >/dev/null ;;
      '*')      monitor "sendkey shift-8" >/dev/null ;;
      '@')      monitor "sendkey shift-2" >/dev/null ;;
      ',')      monitor "sendkey comma" >/dev/null ;;
      '\')      monitor "sendkey less" >/dev/null ;;
      '|')      monitor "sendkey shift-less" >/dev/null ;;
      "'")      monitor "sendkey grave_accent" >/dev/null ;;
      '"')      monitor "sendkey shift-grave_accent" >/dev/null ;;
      '$')      monitor "sendkey shift-4" >/dev/null ;;
      '>')      monitor "sendkey shift-dot" >/dev/null ;;
      '<')      monitor "sendkey shift-comma" >/dev/null ;;
      *) echo "caractere não suportado: $c" >&2; exit 1 ;;
    esac
  done
  monitor "sendkey ret" >/dev/null
}

case "${1:-}" in
  install) cmd_install ;;
  gui)     cmd_gui ;;
  boot)    cmd_boot ;;
  type)    shift; cmd_type "$@" ;;
  key)     monitor "sendkey $2" ;;
  shot)    monitor "screendump $2 -f png"; echo "$2" ;;
  stop)    monitor quit || true; pkill -f "swtpm socket --tpmstate dir=$VM/tpm" || true ;;
  reset)   pkill -f "qemu-system-x86_64.*$VM" || true
           pkill -f "swtpm socket --tpmstate dir=$VM/tpm" || true
           rm -rf "$VM"; echo "VM apagada." ;;
  *) sed -n '2,21p' "$0"; exit 1 ;;
esac
