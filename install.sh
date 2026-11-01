#!/usr/bin/env bash
#
# Install everything this fork needs on top of the plugin itself:
#   1. build and install the wvkbd-deskus keyboard (osk/build.sh)
#   2. install the osk-window-fit user service (floating windows above the dock)
#   3. point ~/.config/omarchy/tablet-mode.conf at that keyboard and the floating panel
#   4. restart the tablet-mode service and run its doctor
#
#   ./install.sh              do all of it
#   ./install.sh --dry-run    print the plan, change nothing
#   ./install.sh --no-build   skip the keyboard build (binary already installed)
#
# Uninstall: ./uninstall.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/tablet-mode.conf"
EXAMPLE="$HERE/tablet-mode.conf.example"
LIB="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-tablet-mode"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/osk-window-fit.service"

dry=0
build=1
for a in "$@"; do
  case $a in
    --dry-run) dry=1 ;;
    --no-build) build=0 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "неизвестный аргумент: $a" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
run() { if ((dry)); then echo "   [dry] $*"; else "$@"; fi; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

# --- 1. dependencies ---------------------------------------------------------
say "1/4 Зависимости"
missing=()
for c in jq socat hyprctl make cc patch tar; do
  command -v "$c" >/dev/null || missing+=("$c")
done
if ((${#missing[@]})); then
  die "не хватает: ${missing[*]} (socat и jq — для osk-window-fit, make/cc/patch — для сборки)"
fi
echo "   ✓ jq, socat, hyprctl, make, cc, patch, tar"

# --- 2. keyboard -------------------------------------------------------------
say "2/4 Клавиатура wvkbd-deskus"
if ((build)); then
  if ((dry)); then
    echo "   [dry] osk/build.sh  → ~/.local/bin/wvkbd-deskus"
  else
    "$HERE/osk/build.sh"
  fi
else
  echo "   пропущено (--no-build)"
fi

# --- 3. window-fit service ---------------------------------------------------
say "3/4 Сервис osk-window-fit (окна над доком)"
run mkdir -p "$LIB/tools" "$UNIT_DIR"
run install -m755 "$HERE/tools/osk-window-fit.sh" "$LIB/tools/osk-window-fit.sh"
if ((dry)); then
  echo "   [dry] $UNIT"
else
  cat >"$UNIT" <<EOF
[Unit]
Description=Fit the focused floating window above the docked on-screen keyboard
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$LIB/tools/osk-window-fit.sh --listen
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now osk-window-fit.service
  sleep 1
  systemctl --user is-active --quiet osk-window-fit.service \
    && echo "   ✓ сервис активен" || die "сервис не поднялся: journalctl --user -u osk-window-fit"
fi

# --- 4. config ---------------------------------------------------------------
say "4/4 Конфиг плагина"
if ((dry)); then
  echo "   [dry] $CONF: osk=wvkbd-deskus, osk_float=true, высоты 350, ручка 28"
else
  if [[ ! -f $CONF ]]; then
    [[ -f $EXAMPLE ]] || die "нет $EXAMPLE"
    mkdir -p "$(dirname "$CONF")"
    cp "$EXAMPLE" "$CONF"
    echo "   создан из примера: $CONF"
  fi

  set_key() { # <key> <value>
    local key=$1 val=$2
    if grep -qE "^[[:space:]]*$key=" "$CONF"; then
      sed -i -E "s|^[[:space:]]*$key=.*|$key=$val|" "$CONF"
    else
      printf '%s=%s\n' "$key" "$val" >>"$CONF"
    fi
    echo "   $key=$val"
  }
  set_key osk wvkbd-deskus
  set_key osk_float true
  set_key osk_float_width 80
  set_key osk_handle_height 28
  set_key osk_height_landscape 350
  set_key osk_height_portrait 350

  if systemctl --user is-active --quiet omarchy-tablet-mode.service; then
    systemctl --user restart omarchy-tablet-mode.service
    echo "   ✓ плагин перезапущен"
  else
    echo "   плагин не запущен — запустится при следующем входе/отсоединении клавиатуры"
  fi
fi

say "Готово"
if ((dry)); then
  echo "Пробный прогон: ничего не изменено. Запусти без --dry-run."
else
  echo "Проверка: $HERE/bin/tablet-mode doctor"
  echo "Окна:    ~/.cache/osk-window-fit.log, systemctl --user status osk-window-fit"
  echo "Откат:   ./uninstall.sh"
fi
