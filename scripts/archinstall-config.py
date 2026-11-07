#!/usr/bin/env python3
"""Gera a configuração do archinstall (formato 4.x) com as escolhas do projeto.

O layout é calculado para o disco real: ESP de 1 GiB em /efi + o resto em
LUKS2 com Btrfs (@, @home, @snapshots, @var_log, @var_cache, @var_tmp),
systemd-boot com UKI, linux-lts, pt_BR/ABNT2, NetworkManager, PipeWire,
Bluetooth, power-profiles-daemon e zram.

Senhas informadas vão para user_credentials.json; o que faltar o archinstall
pede no menu. Com --user/--password/--luks-password dá para rodar --silent.

Uso:
  archinstall-config.py --disk /dev/nvme0n1 --out /root/archinstall
  archinstall --config /root/archinstall/user_configuration.json
"""
import argparse
import json
import os
import subprocess
import uuid

MIB = 1024 ** 2

PACKAGES = [
    "base-devel",
    "sof-firmware", "alsa-ucm-conf", "linux-firmware",
    "cryptsetup", "tpm2-tss", "sbctl", "plymouth",
    "reflector", "git", "neovim", "nano", "man-db", "man-pages",
    "bash-completion", "terminus-font",
]

SUBVOLUMES = [
    ("@", "/"),
    ("@home", "/home"),
    ("@snapshots", "/.snapshots"),
    ("@var_log", "/var/log"),
    ("@var_cache", "/var/cache"),
    ("@var_tmp", "/var/tmp"),
]


def disk_geometry(disk: str) -> tuple[int, int]:
    out = subprocess.run(
        ["lsblk", "-bdno", "SIZE,LOG-SEC", disk],
        check=True, capture_output=True, text=True,
    ).stdout.split()
    return int(out[0]), int(out[1])


def build(args: argparse.Namespace) -> tuple[dict, dict | None]:
    size_bytes, sector = disk_geometry(args.disk)
    sector_size = {"value": sector, "unit": "B"}

    def size(mib: int) -> dict:
        return {"value": mib, "unit": "MiB", "sector_size": sector_size}

    esp_start, esp_len = 1, 1024
    root_start = esp_start + esp_len
    # 1 MiB livre no fim para o GPT de backup
    root_len = size_bytes // MIB - root_start - 1
    if root_len < 20 * 1024:
        raise SystemExit(f"disco {args.disk} pequeno demais ({size_bytes // MIB} MiB)")

    esp_id, root_id = str(uuid.uuid4()), str(uuid.uuid4())
    esp = {
        "obj_id": esp_id, "status": "create", "type": "primary",
        "start": size(esp_start), "size": size(esp_len),
        "fs_type": "fat32", "mountpoint": "/efi", "mount_options": [],
        "flags": ["boot", "esp"], "dev_path": None, "btrfs": [],
    }
    root = {
        "obj_id": root_id, "status": "create", "type": "primary",
        "start": size(root_start), "size": size(root_len),
        "fs_type": "btrfs", "mountpoint": None,
        "mount_options": ["noatime", "compress=zstd:1"],
        "flags": [], "dev_path": None,
        "btrfs": [{"name": n, "mountpoint": m} for n, m in SUBVOLUMES],
    }

    config = {
        "archinstall-language": "Brazilian Portuguese",
        "bootloader_config": {"bootloader": "Systemd-boot", "uki": True, "removable": False},
        "disk_config": {
            "config_type": "manual_partitioning",
            "device_modifications": [{"device": args.disk, "wipe": True, "partitions": [esp, root]}],
            "disk_encryption": {"encryption_type": "luks", "partitions": [root_id], "lvm_volumes": []},
            "btrfs_options": {"snapshot_config": None},
        },
        "hostname": args.hostname,
        "kernels": ["linux-lts"],
        "locale_config": {"kb_layout": "br-abnt2", "sys_lang": "pt_BR.UTF-8", "sys_enc": "UTF-8"},
        "network_config": {"type": "nm"},
        "app_config": {
            "audio_config": {"audio": "pipewire"},
            "bluetooth_config": {"enabled": True},
            "power_management_config": {"power_management": "power-profiles-daemon"},
        },
        "ntp": True,
        "packages": PACKAGES,
        "swap": {"enabled": True, "algorithm": "zstd"},
        "timezone": args.timezone,
    }

    # Credenciais: só o que foi informado (o resto o archinstall pede no menu)
    creds: dict = {}
    if args.luks_password:
        creds["encryption_password"] = args.luks_password
    if args.user and args.password:
        creds["users"] = [{"username": args.user, "!password": args.password, "sudo": True, "groups": []}]
        creds["!root-password"] = args.root_password or args.password
    return config, (creds or None)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--disk", default=os.environ.get("DISK", "/dev/nvme0n1"))
    p.add_argument("--out", default="/root/archinstall")
    p.add_argument("--hostname", default="vivobook")
    p.add_argument("--timezone", default="America/Sao_Paulo")
    p.add_argument("--user")
    p.add_argument("--password")
    p.add_argument("--root-password")
    p.add_argument("--luks-password")
    args = p.parse_args()

    config, creds = build(args)
    os.makedirs(args.out, exist_ok=True)
    cfg_path = os.path.join(args.out, "user_configuration.json")
    with open(cfg_path, "w") as f:
        json.dump(config, f, indent=4)
    print(cfg_path)
    if creds:
        creds_path = os.path.join(args.out, "user_credentials.json")
        with open(os.open(creds_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
            json.dump(creds, f, indent=4)
        print(creds_path)


if __name__ == "__main__":
    main()
