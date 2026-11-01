#!/usr/bin/env bash
#
# Undo install.sh: stop and remove the osk-window-fit service, drop the copied
# tools, and point the plugin back at a keyboard that does not need this fork.
#
#   ./uninstall.sh                 remove the service and revert osk=
#   ./uninstall.sh --remove-binary also delete ~/.local/bin/wvkbd-deskus
#
# The plugin itself is removed with `omarchy plugin remove <id>`; this script
# only handles the pieces install.sh added.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/tablet-mode.conf"
LIB="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-tablet-mode"
UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/osk-window-fit.service"
BIN="$HOME/.local/bin/wvkbd-deskus"
remove_bin=0

[[ ${1:-} == --remove-binary ]] && remove_bin=1

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "1/3 Сервис osk-window-fit"
systemctl --user disable --now osk-window-fit.service 2>/dev/null || true
rm -f "$UNIT"
systemctl --user daemon-reload
echo "   ✓ удалён"

say "2/3 Скопированные инструменты"
rm -rf "$LIB"
echo "   ✓ $LIB"

say "3/3 Конфиг"
if [[ -f $CONF ]]; then
  if grep -qE '^[[:space:]]*osk=' "$CONF"; then
    sed -i -E 's|^[[:space:]]*osk=.*|osk=auto|' "$CONF"
  else
    printf 'osk=auto\n' >>"$CONF"
  fi
  echo "   osk=auto (плагин выберет wvkbd-mobintl, если он установлен)"
fi

if ((remove_bin)); then
  rm -f "$BIN"
  echo "   ✓ удалён $BIN"
else
  echo "   бинарь оставлен: $BIN (удалить: --remove-binary)"
fi

say "Готово"
echo "Плагин остаётся установленным; убрать его: omarchy plugin remove alanroman117.tablet-mode"
echo "Перезапустить: systemctl --user restart omarchy-tablet-mode"
