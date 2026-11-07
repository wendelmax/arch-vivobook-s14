#!/usr/bin/env bash
# Pós-instalação manual (Hyprland, visual Arch, energia, snapshots, bateria).
# Normalmente já roda durante a instalação; use este script se essa etapa
# tiver sido pulada ou falhado. Executar como usuário comum (usa sudo).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -ne 0 ]] || { echo "execute como usuário comum (o script usa sudo)" >&2; exit 1; }

sudo bash "$SCRIPT_DIR/setup-system.sh"
bash "$SCRIPT_DIR/setup-user.sh"

cat <<'EOF'

Pronto. Reinicie; no tuigreet escolha a sessão "Hyprland (uwsm-managed)" (F3 troca a sessão).
Atalhos: SUPER+Q terminal | SUPER+R menu | SUPER+E arquivos | SUPER+C fecha janela
EOF
