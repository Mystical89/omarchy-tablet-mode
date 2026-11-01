#!/usr/bin/env bash
#
# Build the wvkbd-deskus keyboard this fork expects, from the vendored wvkbd
# 0.20 tarball plus the patch chain in osk/patches/.
#
#   osk/build.sh                 build and install to ~/.local/bin/wvkbd-deskus
#   osk/build.sh --no-install    build only, leave the binary in the build dir
#   PREFIX=/usr/local osk/build.sh
#   BUILD_DIR=/tmp/b osk/build.sh
#
# The result is a keyboard that supports --float, --float-width, --handle-height
# (floating panel with a drag handle), keeps a Cyrillic page in both layer
# cycles, and re-creates its virtual-keyboard object so layout switching works
# under Hyprland.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-tablet-mode/build}"
PREFIX="${PREFIX:-$HOME/.local}"
TARBALL="$HERE/wvkbd-0.20.tar.gz"
SRC="$BUILD_DIR/wvkbd-v0.20"
JOBS="$(nproc 2>/dev/null || echo 2)"
install=1

[[ ${1:-} == --no-install ]] && install=0

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

for c in tar make cc patch; do
  command -v "$c" >/dev/null || die "нужен $c"
done
[[ -f $TARBALL ]] || die "нет исходников: $TARBALL"

# The plugin recipe's order matters: the plugin's own three patches first, then
# the Russian deskus layout, then the behaviour patches.
PATCHES=(
  deskus-layout.patch
  hold-until-release.patch
  stay-on-output.patch
  ru-alt-deskus.patch
  10-vkbd-recreate-on-keymap.patch
  20-float-drag-handle.patch
  40-handle-full-height.patch
)

say "1/4 Чистое дерево wvkbd 0.20"
rm -rf "$SRC"
mkdir -p "$BUILD_DIR"
tar -xzf "$TARBALL" -C "$BUILD_DIR"
cd "$SRC"

say "2/4 deskus = deskintl + патчи плагина"
cp layout.deskintl.h layout.deskus.h
cp keymap.deskintl.h keymap.deskus.h
cp config.deskintl.h config.deskus.h

for p in "${PATCHES[@]}"; do
  f="$HERE/patches/$p"
  [[ -f $f ]] || die "нет патча: $p"
  # deskus-layout.patch touches layout.deskus.h only; the rest are -p1.
  if [[ $p == deskus-layout.patch ]]; then
    patch --quiet layout.deskus.h <"$f" || die "патч не применился: $p"
  else
    patch -p1 --quiet <"$f" || die "патч не применился: $p"
  fi
  echo "   ✓ $p"
done

say "3/4 Сборка"
rm -f build-deskus/config.h   # Makefile rule has no deps: config.h is copied once
make LAYOUT=deskus wvkbd-deskus -j"$JOBS"

say "4/4 Проверка и установка"
for flag in --float-width --handle-height --output; do
  grep -q -- "$flag" <(./wvkbd-deskus --help 2>&1) || die "бинарь не знает $flag"
done
echo "   ✓ --float-width, --handle-height, --output на месте"

if ((install)); then
  install -Dm755 wvkbd-deskus "$PREFIX/bin/wvkbd-deskus"
  echo "   ✓ установлен: $PREFIX/bin/wvkbd-deskus"
  echo
  echo "Дальше: перезапустить плагин —"
  echo "  systemctl --user restart omarchy-tablet-mode"
else
  echo "   бинарь: $SRC/wvkbd-deskus (--no-install)"
fi
