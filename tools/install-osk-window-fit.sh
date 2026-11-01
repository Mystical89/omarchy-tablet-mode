#!/usr/bin/env bash
# Install and enable the osk-window-fit user service (fits the focused floating
# window above the docked on-screen keyboard).
#
#   tools/install-osk-window-fit.sh          install + enable + start
#   tools/install-osk-window-fit.sh --remove uninstall
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/osk-window-fit.service"
SCRIPT="$HERE/tools/osk-window-fit.sh"

if [[ ${1:-} == --remove ]]; then
  systemctl --user disable --now osk-window-fit.service 2>/dev/null || true
  rm -f "$UNIT"
  systemctl --user daemon-reload
  echo "→ сервис osk-window-fit удалён"
  exit 0
fi

command -v socat >/dev/null || { echo "✗ нужен socat" >&2; exit 1; }
command -v jq >/dev/null || { echo "✗ нужен jq" >&2; exit 1; }
chmod +x "$SCRIPT"

mkdir -p "$UNIT_DIR"
cat >"$UNIT" <<EOF
[Unit]
Description=Fit the focused floating window above the docked on-screen keyboard
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$SCRIPT --listen
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now osk-window-fit.service
sleep 1
systemctl --user is-active osk-window-fit.service
echo "→ установлено: $UNIT"
echo "  проверка: $SCRIPT --status   (и ~/.cache/osk-window-fit.log)"
