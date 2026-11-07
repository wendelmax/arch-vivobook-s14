# Guia de instalação — Arch Linux no ASUS Vivobook S14 (S3407CA)

Arch Linux puro · LUKS2 + TPM2 · Btrfs + snapper · systemd-boot + UKI ·
kernel compilado para Arrow Lake (`-march=native`) · Hyprland com identidade Arch.

> O disco inteiro será apagado (Windows incluído). Faça backup antes.

---

## Fase 0 — Preparação (ainda no Windows)

1. **Backup** de tudo que importa no C:.
2. **Baixar a ISO** em <https://archlinux.org/download/> (mirror do Brasil) e o `sha256sums.txt`.
   Conferir no PowerShell:
   ```powershell
   Get-FileHash .\archlinux-*-x86_64.iso -Algorithm SHA256
   ```
   O hash precisa bater com o do `sha256sums.txt`.
3. **Pendrive com Ventoy** (<https://www.ventoy.net>): instale o Ventoy no pendrive (apaga o pendrive)
   e copie a ISO para ele. Os scripts são baixados do GitHub durante a instalação.
4. **BIOS** (ligar segurando **F2**, depois **F7** para o modo avançado):
   - `Security → Secure Boot → Secure Boot Control` = **Disabled**
   - `Advanced → VMD setup menu → Enable VMD controller` = **Disabled**
   - `Boot → Fast Boot` = **Disabled**
   - Salvar e sair (**F10**).

## Fase 1 — Instalação base (pendrive)

Ligue segurando **Esc** e escolha o pendrive → Arch Linux.

```bash
loadkeys br-abnt2

# Wi-Fi
iwctl
  device list                       # normalmente wlan0
  station wlan0 scan
  station wlan0 connect "NOME_DA_REDE"
  exit
ping -c2 archlinux.org

# Baixar os scripts
pacman -Sy --noconfirm git
git clone https://github.com/wendelmax/arch-vivobook-s14 /root/arch-linux

# Instalar (pergunta usuário, confirmação "APAGAR", senha do LUKS e senhas)
bash /root/arch-linux/scripts/install.sh
```

> Sem GitHub? Copie esta pasta para o pendrive Ventoy e use
> `mkdir -p /root/usb && mount -L Ventoy /root/usb && cp -r /root/usb/arch-linux /root/`.
> Se o mount falhar, use um segundo pendrive FAT32 (`lsblk`, depois `mount /dev/sdX1 /root/usb`).

Ao terminar:

```bash
umount -R /mnt && cryptsetup close cryptroot && reboot
```

## Fase 2 — Primeiro boot

1. Digite a **senha do LUKS** (teclado já em ABNT2).
2. Entre com seu usuário no console e conecte o Wi-Fi:
   ```bash
   nmcli device wifi connect "NOME_DA_REDE" --ask
   ```
3. Rode a pós-instalação (Hyprland, áudio, Bluetooth, energia, snapshots, bateria a 80%, visual Arch):
   ```bash
   ~/arch-linux/scripts/post-install.sh
   sudo reboot
   ```
4. No **tuigreet**, escolha a sessão **Hyprland (uwsm-managed)** (F3 alterna sessões).

Atalhos: `SUPER+Q` terminal · `SUPER+R` menu · `SUPER+E` arquivos · `SUPER+C` fecha janela ·
`SUPER+L` bloqueia · `Print` captura de área. Clique no logo do Arch na barra para abrir o menu.

## Fase 3 — Kernel otimizado

```bash
~/arch-linux/scripts/build-kernel.sh      # ~30–40 min, ~25 GB livres
sudo reboot
```

Conferir:

```bash
uname -r                                           # deve conter "cachyos"
zcat /proc/config.gz | grep -E 'X86_NATIVE_CPU|MNATIVE'   # =y → compilado para este CPU
```

O `linux-lts` continua no menu do systemd-boot como reserva (o menu aparece por 3 s no boot).

**Atualizar o kernel:** rode o mesmo script de novo (ele faz `git pull` e recompila).
Faça isso a cada poucas semanas ou quando sair correção importante.

**Build mais rápido (opcional):** instale `modprobed-db` (`paru -S modprobed-db`), use o notebook
alguns dias com tudo que costuma plugar (`modprobed-db store`), depois compile com
`LOCALMOD=y ~/arch-linux/scripts/build-kernel.sh`. Dispositivos nunca vistos podem não ter driver.

## Fase 4 — Secure Boot + desbloqueio automático pelo TPM

1. BIOS (**F2**) → `Security → Secure Boot → Key Management` → **apagar todas as chaves**
   (entra em *Setup Mode*). Salvar e iniciar o Arch.
2. ```bash
   sudo ~/arch-linux/scripts/secureboot-tpm.sh keys
   ```
3. Reinicie → BIOS → `Secure Boot Control` = **Enabled** → iniciar o Arch (ainda pede senha).
4. ```bash
   sudo ~/arch-linux/scripts/secureboot-tpm.sh tpm
   ```
   **Anote a chave de recuperação** e guarde fora do notebook.
5. Reinicie: o disco desbloqueia sozinho. A senha do LUKS continua valendo como alternativa.

---

## Checklist pós-instalação

| Item | Como testar |
|---|---|
| Wi-Fi | `nmcli device status` |
| Bluetooth | `bluetoothctl show` / ícone na barra |
| Som + microfone | `pavucontrol` → aba Entrada, fale e veja o nível |
| Aceleração de vídeo | `vainfo` (perfis H.264/HEVC/AV1) |
| GPU | `sudo intel_gpu_top` |
| Perfis de energia | `powerprofilesctl` |
| Limite de bateria | `cat /sys/class/power_supply/BAT*/charge_control_end_threshold` → 80 |
| Suspensão | `cat /sys/power/mem_sleep` → `[s2idle]`; fechar a tampa e voltar |
| Snapshots | `snapper list` (cria par pre/post a cada `pacman`) |
| zram | `swapon --show` |

## Problemas comuns

**Wi-Fi caindo ou lento** (RTL8852BE):
```bash
sudo cp ~/arch-linux/config/modprobe/rtw89.conf /etc/modprobe.d/ && sudo reboot
```

**Microfone não aparece:** confirme `sof-firmware` e `alsa-ucm-conf` instalados e veja
`journalctl -k -b | grep -i sof`.

**Kernel otimizado não inicia:** no menu do systemd-boot escolha **linux-lts**, depois rode o
`build-kernel.sh` de novo ou remova o pacote `linux-cachyos`.

**TPM parou de desbloquear** (após atualizar BIOS ou mexer no Secure Boot): digite a senha e refaça:
```bash
sudo systemd-cryptenroll /dev/disk/by-partlabel/cryptroot --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7
```

**Atualização quebrou o sistema — voltar um snapshot:**
```bash
# no pendrive live:
cryptsetup open /dev/nvme0n1p2 cryptroot
mount -o subvolid=5 /dev/mapper/cryptroot /mnt
snapper --no-dbus -r /mnt/@ list 2>/dev/null || ls /mnt/@snapshots   # escolha o número N
mv /mnt/@ /mnt/@quebrado
btrfs subvolume snapshot /mnt/@snapshots/N/snapshot /mnt/@
umount /mnt && reboot
# depois, se tudo estiver ok: sudo btrfs subvolume delete /caminho/@quebrado (montando subvolid=5)
```

**Atualizar o BIOS:** baixe o arquivo do S3407CA no site da ASUS, coloque num pendrive FAT32 e use
**EZ Flash** dentro do BIOS. Depois, o TPM provavelmente pedirá re-registro (ver acima).
