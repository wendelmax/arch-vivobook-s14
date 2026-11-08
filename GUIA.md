# Guia de instalação — Arch Linux no ASUS Vivobook S14 (S3407CA)

Arch Linux puro · LUKS2 + TPM2 · Btrfs + snapper · systemd-boot + UKI ·
kernel compilado para Arrow Lake (`-march=native`) · Hyprland com identidade Arch.

> O disco inteiro será apagado (Windows incluído). Faça backup antes.

---

## 0. Preparação (ainda no Windows)

1. **Backup** de tudo que importa no C:.
2. **Baixar a ISO pronta** em [Releases](https://github.com/wendelmax/arch-vivobook-s14/releases)
   (confira o SHA-256 publicado junto) **ou gerar a ISO personalizada** pelo Arch x86_64
   (ex.: WSL Arch, como root):
   ```bash
   cd /mnt/c/Users/<você>/Projects/arch-linux
   bash iso/build.sh                                               # Wi-Fi perguntado no boot
   # ou: WIFI_SSID="MinhaRede" WIFI_PASS="senha" bash iso/build.sh  # Wi-Fi embutido
   ```
   O build compila o Calamares do AUR na primeira vez (~15 min). Para reutilizar um
   pacote já compilado: `CALAMARES_PKG=/caminho/calamares-*.pkg.tar.zst bash iso/build.sh`.
   Resultado: `iso/out/archlinux-custom-*.iso`.
   > A ISO com Wi-Fi embutido guarda a senha da rede em texto puro — não compartilhe.
3. **Pendrive com Ventoy** (<https://www.ventoy.net>): instale o Ventoy (apaga o pendrive) e copie a ISO.
   Vale copiar também a ISO oficial do Arch como reserva.
4. **BIOS** (ligar segurando **F2**, depois **F7** para o modo avançado):
   - `Advanced → VMD setup menu → Enable VMD controller` = **Disabled**
   - `Boot → Fast Boot` = **Disabled**
   - `Security → Secure Boot → Key Management` → **apagar todas as chaves** (*Setup Mode*).
     Isso desliga o Secure Boot e deixa o instalador registrar as chaves próprias.
     Se preferir não mexer agora, apenas deixe `Secure Boot Control` = **Disabled**.
   - Salvar e sair (**F10**).

## 1. Instalação (tudo numa etapa)

Ligue segurando **Esc** e escolha o pendrive → *archlinux-custom*. O assistente abre sozinho:

1. Teclado ABNT2 e **Wi-Fi** (escolha a rede e digite a senha, ou conecta sozinho se embutido).
2. Baixa a versão mais nova dos scripts do GitHub (ou usa a cópia embutida).
3. **Escolha o instalador:**
   - **1) Automática** (recomendada) — segue abaixo.
   - **2) Gráfica (Calamares)** — interface com disco/criptografia, usuário/senhas, hostname,
     idioma, fuso e teclado. O layout é o mesmo: ESP de 1 GiB em `/efi`, LUKS2, Btrfs com os
     subvolumes do projeto, systemd-boot + UKI e `linux-lts`. **Ao terminar, feche a janela
     (não reinicie)**: as etapas extras (Wi-Fi, Plymouth, Hyprland, kernel, Secure Boot/TPM)
     continuam no terminal, com as mesmas perguntas abaixo.
   - **3) archinstall** — o instalador oficial abre com tudo pré-carregado (ESP em `/efi`, LUKS2,
     Btrfs com os mesmos subvolumes, systemd-boot + UKI, `linux-lts`, pt_BR/ABNT2, NetworkManager,
     PipeWire, Bluetooth, zram). Você revisa/ajusta, define usuário e senhas e instala.
     **Ao final escolha "Sair" (não reiniciar)**: as etapas extras rodam em seguida.
   - **4) Sair para o shell.**
4. **Perguntas (modo automático) — todas no início:**
   - usuário, nome do computador, senha do usuário, senha do root, senha do disco (LUKS);
   - instalar Hyprland + visual Arch? · compilar o kernel otimizado? · configurar Secure Boot + TPM?
   - resumo e confirmação digitando `APAGAR`.
5. **Daí em diante segue sozinho** (~45–60 min com o kernel; mantenha na tomada):
   base criptografada → Wi-Fi salvo no sistema → Hyprland/visual Arch → kernel `-march=native` →
   chaves do Secure Boot e assinaturas.
6. No fim aparece a **chave de recuperação do disco** — **fotografe/anote e guarde fora do notebook**.
   Remova o pendrive e pressione Enter para reiniciar.

> Sem a ISO personalizada (ISO oficial): `loadkeys br-abnt2`, conecte com `iwctl`, depois
> `pacman -Sy --noconfirm git && git clone https://github.com/wendelmax/arch-vivobook-s14 /root/arch-linux && bash /root/arch-linux/scripts/install.sh`.

### Testar antes no computador (VM)

Em outro Arch x86_64 com KVM (ou numa VM), sem tocar no disco real:

```bash
sudo test/vm.sh install    # instalação automática (test/answers.env) e desliga
sudo test/vm.sh gui        # instalação gráfica: Calamares via VNC em 127.0.0.1:5901
sudo test/vm.sh boot       # inicia o disco instalado; type/key/shot/stop controlam a VM
```

O `gui` usa UEFI + Secure Boot em Setup Mode + TPM2 emulado + disco NVMe, como no notebook.
Conecte no VNC (`vncviewer 127.0.0.1:5901`) e conclua o Calamares; o terminal com as etapas
extras e o pedido da senha do LUKS aparece na mesma tela. O log fica em
`/var/tmp/arch-vm/serial-gui.log`. No UTM, use uma VM x86_64 com UEFI e o ISO como CD-ROM
(o Calamares também pode ser testado por lá).

**No Mac (Apple Silicon):** gere a ISO num container Arch x86_64 (Docker Desktop) e rode a VM
com emulação TCG — funciona, mas é bem mais lento que KVM:

```bash
docker run --rm --privileged --platform linux/amd64 -v "$PWD":/repo -e OUT_DIR=/repo/iso/out \
  archlinux:latest bash -c 'sed -i "/^\[options\]/a DisableSandbox" /etc/pacman.conf;
    pacman -Sy --noconfirm git; git config --global --add safe.directory "*"; bash /repo/iso/build.sh'
brew install qemu swtpm xorriso
test/vm.sh gui             # sem sudo; disco/log em ~/.cache/arch-vm
```

## 2. Primeiros boots (Secure Boot + TPM)

O serviço `arch-secureboot` conclui sozinho; os avisos aparecem como notificação no Hyprland.

| Situação no fim da instalação | O que fazer |
|---|---|
| Chaves já registradas (BIOS estava em Setup Mode) | 1º reboot: BIOS (F2) → `Secure Boot Control` = **Enabled**. Digite a senha do disco uma última vez; o TPM é registrado. Do boot seguinte em diante, desbloqueio automático. |
| BIOS não estava em Setup Mode | BIOS → Key Management → apagar chaves → boot (o sistema registra as chaves) → reboot → BIOS → **Enabled** → boot (TPM registrado). |

A senha do disco e a chave de recuperação continuam valendo se o TPM recusar (ex.: após atualizar o BIOS).

No **tuigreet**, escolha a sessão **Hyprland (uwsm-managed)** (F3 alterna sessões).
Atalhos: `SUPER+Q` terminal · `SUPER+R` menu · `SUPER+E` arquivos · `SUPER+C` fecha janela ·
`SUPER+L` bloqueia · `Print` captura de área. Clique no logo do Arch na barra para abrir o menu.

## 3. Manutenção e etapas manuais

Se alguma etapa foi pulada ou falhou (o resumo final e `/var/log/arch-install.log` mostram), rode depois:

| Etapa | Comando |
|---|---|
| Hyprland + visual Arch + apps | `~/arch-linux/scripts/post-install.sh` |
| Tela de boot Plymouth (Arch) | `sudo ~/arch-linux/scripts/plymouth-theme.sh` |
| Kernel otimizado | `~/arch-linux/scripts/build-kernel.sh` (~30–40 min, ~25 GB livres) |
| Secure Boot (Setup Mode) | `sudo ~/arch-linux/scripts/secureboot-tpm.sh keys` |
| TPM (com Secure Boot ativo) | `sudo ~/arch-linux/scripts/secureboot-tpm.sh tpm` |

**Conferir o kernel:**
```bash
uname -r                                                  # deve conter "cachyos"
zcat /proc/config.gz | grep -E 'X86_NATIVE_CPU|MNATIVE'   # =y → compilado para este CPU
```
O `linux-lts` continua no menu do systemd-boot como reserva (o menu aparece por 3 s no boot).

**Atualizar o kernel:** rode `build-kernel.sh` de novo (faz `git pull` e recompila) a cada poucas semanas.

**Build mais rápido (opcional):** `paru -S modprobed-db`, use o notebook alguns dias com tudo que costuma
plugar (`modprobed-db store`) e compile com `LOCALMOD=y ~/arch-linux/scripts/build-kernel.sh`.
Dispositivos nunca vistos podem ficar sem driver.

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
