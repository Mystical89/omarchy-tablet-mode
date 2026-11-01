#!/usr/bin/env bash
# Fit the focused floating window above the docked on-screen keyboard.
#
# Hyprland 0.56 resizes tiled windows and maximized floating windows itself when
# the dock's exclusive zone appears, but it never touches a plain floating window,
# so the keyboard covers it. This listens on socket2 and moves/resizes the focused
# floating window into the usable area while the dock is up, restoring its exact
# geometry when the dock goes away.
#
# Standing user preferences (2026-10-25):
#   - never switch a window's mode (no maximize, no tiling) — when a window
#     cannot fit (client min-size), it is only shifted into view;
#   - a floating window must never stick out of the screen on any edge —
#     top, bottom, left or right.
#
#   osk-window-fit --listen     follow socket2 (systemd service mode)
#   osk-window-fit --fit        refit once, right now (debug)
#   osk-window-fit --restore    restore once, right now (debug)
#   osk-window-fit --clamp      pull floating windows back into the screen
#   osk-window-fit --status     print the saved geometry, if any
set -uo pipefail

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
STATE="$CACHE/osk-window-fit.state"
LOG="$CACHE/osk-window-fit.log"
SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:-}/.socket2.sock"
GAP=0 # extra px between the window's bottom edge and the keyboard

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

# reserved is [left, top, right, bottom] in logical px, same as window at/size.
monitor_json() { hyprctl -j monitors | jq -c '.[] | select(.focused == true)'; }

# 0 when the keyboard is a floating panel (no exclusive zone) or hidden.
dock_bottom() { monitor_json | jq -r '.reserved[3] // 0'; }

active_window() { hyprctl -j activewindow | jq -c 'select(.address != null)'; }

# resize keeps the window's centre, so it must run before move everywhere.
apply_geom() { # addr x y w h
  hyprctl dispatch "hl.dsp.window.resize({ x = $4, y = $5, window = \"address:$1\" })" >/dev/null
  hyprctl dispatch "hl.dsp.window.move({ x = $2, y = $3, window = \"address:$1\" })" >/dev/null
}

move_to() { # addr x y
  local out rc
  out=$(hyprctl dispatch "hl.dsp.window.move({ x = $2, y = $3, window = \"address:$1\" })" 2>&1)
  rc=$?
  [[ $rc -ne 0 || $out != ok ]] && log "move_to: rc=$rc out=[$out] cmd=[x=$2 y=$3 addr=$1 sig=$HYPRLAND_INSTANCE_SIGNATURE]"
}

# monitors.width/height stay UNROTATED in Hyprland 0.56 when a transform is set
# (verified: transform=1 screenshot is 1280x1920 while monitors still says
# 1920x1280). Odd transforms (90/270) swap the axes, so divide the swapped pair.
monitor_logical_size() { # mon_json -> "w h" (rotated, logical)
  jq -r '(.scale // 1) as $s
         | (if ((.transform // 0) % 2 == 1) then [.height, .width] else [.width, .height] end)
         | map(. / $s | floor) | @tsv' <<<"$1"
}

# Native titlebars (Omarchy 4.5 hyprbars) draw ABOVE the window surface, so a
# window clamped to the bar still hides its title behind it. Stand back by the
# plugin's live bar_height (fallback 30) on every top edge.
title_pad() {
  local h
  h=$(hyprctl getoption plugin:hyprbars:bar_height 2>/dev/null | awk '/^int:/{print $2}')
  printf '%s\n' "${h:-30}"
}

fit_once() {
  local bottom mon w h avail_top avail_bottom avail_left avail_right addr aw ah ax ay
  bottom=$(dock_bottom)
  [[ $bottom -gt 0 ]] || { log 'fit: no dock reserve, nothing to do'; return 0; }

  mon=$(monitor_json) || return 1
  # Physical px rotated to what the user actually sees, then to logical px.
  read -r w h < <(monitor_logical_size "$mon")
  avail_top=$(( $(jq -r '.reserved[1] // 0' <<<"$mon") + $(title_pad) ))
  avail_left=$(jq -r '.reserved[0] // 0' <<<"$mon")
  avail_right=$((w - $(jq -r '.reserved[2] // 0' <<<"$mon")))
  avail_bottom=$((h - bottom - GAP))

  local win
  win=$(active_window)
  [[ -n $win ]] || { log 'fit: no active window'; return 0; }
  addr=$(jq -r '.address' <<<"$win")
  jq -e '.floating == true' <<<"$win" >/dev/null || { log "fit: $addr is not floating, compositor handles it"; return 0; }
  # Maximized floating windows are already refit by Hyprland itself.
  jq -e '.fullscreen == 0' <<<"$win" >/dev/null || { log "fit: $addr is maximized/fullscreen, compositor handles it"; return 0; }

  read -r ax ay aw ah < <(jq -r '[.at[0], .at[1], .size[0], .size[1]] | @tsv' <<<"$win")

  # Horizontal clamp first: never stick out of the left or right edge.
  local new_x=$ax
  (( new_x < avail_left )) && new_x=$avail_left
  (( new_x + aw > avail_right )) && new_x=$((avail_right - aw))
  (( new_x < avail_left )) && new_x=$avail_left

  # Already clear of the keyboard?  Only the horizontal clamp applies.
  if (( ay + ah <= avail_bottom )); then
    if (( new_x != ax )); then
      log "fit: $addr clear of the dock, clamping x only ($ax -> $new_x)"
      move_to "$addr" "$new_x" "$ay"
    else
      log "fit: $addr already clear (bottom $((ay + ah)) <= $avail_bottom)"
    fi
    return 0
  fi

  # Remember the geometry only once: a rotation or a re-show must not overwrite it.
  [[ -s $STATE ]] || printf 'address=%s at=%s,%s size=%sx%s\n' "$addr" "$ax" "$ay" "$aw" "$ah" >"$STATE"

  local free_h=$((avail_bottom - avail_top))
  local new_y
  if (( ah > free_h )); then
    # Taller than the free area (client min-size, e.g. Electron): shift only —
    # keep the size and the mode, show the top of the window above the keyboard.
    new_y=$((avail_bottom - ah))
    (( new_y < avail_top )) && new_y=$avail_top
    log "fit: $addr is taller than the free area ($ah > $free_h), shifting only: $ax,$ay -> $new_x,$new_y"
    move_to "$addr" "$new_x" "$new_y"
    return 0
  fi

  # Fits: shrink only as much as needed, anchor the bottom edge to the keyboard.
  local new_h=$ah
  (( new_h > free_h )) && new_h=$free_h
  new_y=$((avail_bottom - new_h))
  (( new_y < avail_top )) && new_y=$avail_top

  log "fit: $addr $ax,$ay ${aw}x${ah} -> $new_x,$new_y ${aw}x${new_h}"
  apply_geom "$addr" "$new_x" "$new_y" "$aw" "$new_h"
  sleep 0.25

  # A client-side minimum size may refuse the resize. Never switch modes —
  # fall back to shifting the window as it is.
  local cur now_y now_h now_w
  cur=$(hyprctl -j clients | jq -c --arg a "$addr" '.[] | select(.address == $a)')
  now_y=$(jq -r '.at[1]' <<<"$cur"); now_h=$(jq -r '.size[1]' <<<"$cur"); now_w=$(jq -r '.size[0]' <<<"$cur")
  if (( now_y + now_h > avail_bottom )); then
    new_y=$((avail_bottom - ah))
    (( new_y < avail_top )) && new_y=$avail_top
    log "fit: $addr refused the resize (still ${now_w}x${now_h}), shifting only -> $new_x,$new_y"
    move_to "$addr" "$new_x" "$new_y"
  fi
}

# Clamp x,y of one window against its own monitor's free area. Prints nothing;
# moves the window only when it actually sticks out.
clamp_window() { # win_json mons_json
  local win=$1 mons=$2 mid mon w h top left right ax ay aw ah nx ny
  # clients.monitor is the monitor id, monitors.name is the string — match by id.
  mid=$(jq -r '.monitor' <<<"$win")
  mon=$(jq -c --argjson id "$mid" '.[] | select(.id == $id)' <<<"$mons")
  [[ -n $mon ]] || return 0
  read -r w h < <(monitor_logical_size "$mon")
  # Screen bounds only: the top bar counts as an edge, the docked keyboard does
  # NOT — a window under the keyboard is fit's business (active window only),
  # and counting the reserve here races fit_once for the saved geometry.
  top=$(( $(jq -r '.reserved[1] // 0' <<<"$mon") + $(title_pad) ))
  left=$(jq -r '.reserved[0] // 0' <<<"$mon")
  right=$((w - $(jq -r '.reserved[2] // 0' <<<"$mon")))
  bottom_edge=$h

  ax=$(jq -r '.at[0]' <<<"$win"); ay=$(jq -r '.at[1]' <<<"$win")
  aw=$(jq -r '.size[0]' <<<"$win"); ah=$(jq -r '.size[1]' <<<"$win")
  nx=$ax; ny=$ay
  (( nx < left )) && nx=$left
  (( nx + aw > right )) && nx=$((right - aw))
  (( nx < left )) && nx=$left
  (( ny < top )) && ny=$top
  (( ny + ah > bottom_edge )) && ny=$((bottom_edge - ah))
  (( ny < top )) && ny=$top
  if (( nx != ax || ny != ay )); then
    local addr
    addr=$(jq -r '.address' <<<"$win")
    log "clamp: $(jq -r '.class' <<<"$win") $addr $ax,$ay -> $nx,$ny"
    move_to "$addr" "$nx" "$ny"
  fi
}

# Pull every visible floating window back into its monitor. This is a screen
# bounds correction, not a dock fit: no state is saved, nothing is restored.
clamp_once() {
  local mons
  mons=$(hyprctl -j monitors) || return 1
  hyprctl -j clients | jq -c '.[] | select(.floating == true and .fullscreen == 0 and .hidden == false and .mapped == true)' |
    while IFS= read -r win; do clamp_window "$win" "$mons"; done
  [[ ${1:-} == --quiet ]] || log 'clamp: done'
}

# A floating window can end up off-screen without any dock event: a rotation
# parks it, a restore races a resize, an app remembers a bad position. Sweep
# the bounds on a timer so the window comes back on its own.
bounds_loop() {
  while :; do
    sleep 5
    clamp_once --quiet
  done
}

restore_once() {
  local mon at size ax ay aw ah cur
  [[ -s $STATE ]] || { log 'restore: no saved geometry'; return 0; }
  # shellcheck disable=SC1090
  . "$STATE"
  cur=$(hyprctl -j clients | jq -c --arg a "$address" '.[] | select(.address == $a)')
  if [[ -z $cur ]]; then log "restore: $address is gone, dropping state"; rm -f "$STATE"; return 0; fi
  jq -e '.floating == true' <<<"$cur" >/dev/null || { log "restore: $address no longer floating, dropping state"; rm -f "$STATE"; return 0; }
  # The user may have maximized it while the dock was up — that mode is theirs,
  # not ours to undo.
  jq -e '.fullscreen == 0' <<<"$cur" >/dev/null || { log "restore: $address is maximized/fullscreen (user-set), leaving it"; rm -f "$STATE"; return 0; }

  ax=${at%,*}; ay=${at#*,}
  aw=${size%x*}; ah=${size#*x}
  # A window saved off-screen (dragged out, parked by a rotation) must come
  # back into view: clamp against the monitor without the dock reserve.
  mon=$(monitor_json)
  if [[ -n $mon ]]; then
    local w h top left right
    read -r w h < <(monitor_logical_size "$mon")
    top=$(( $(jq -r '.reserved[1] // 0' <<<"$mon") + $(title_pad) ))
    left=$(jq -r '.reserved[0] // 0' <<<"$mon")
    right=$((w - $(jq -r '.reserved[2] // 0' <<<"$mon")))
    (( ay < top )) && ay=$top
    (( ay + ah > h )) && ay=$((h - ah))
    (( ay < top )) && ay=$top
    (( ax < left )) && ax=$left
    (( ax + aw > right )) && ax=$((right - aw))
    (( ax < left )) && ax=$left
  fi
  log "restore: $address -> $ax,$ay ${aw}x${ah}"
  apply_geom "$address" "$ax" "$ay" "$aw" "$ah"
  rm -f "$STATE"
}

# The socket directory carries the compositor's pid and start time, so it changes
# on every Hyprland restart — and a user service keeps the signature it was
# started with, which then points at a dead socket. Ask hyprctl for the live
# instance instead of trusting the environment.
live_socket() {
  local runtime sig
  runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  sig=$(hyprctl instances -j 2>/dev/null | jq -r '.[0].instance // empty')
  if [[ -n $sig && -S $runtime/hypr/$sig/.socket2.sock ]]; then
    printf '%s\n' "$runtime/hypr/$sig/.socket2.sock"
    return 0
  fi
  # Fallback: the newest socket on disk.
  ls -t "$runtime"/hypr/*/.socket2.sock 2>/dev/null | head -1
}

listen() {
  bounds_loop &
  # Reconnect rather than dying when the compositor restarts.
  while :; do
    SOCK=$(live_socket)
    if [[ -z $SOCK || ! -S $SOCK ]]; then
      log 'listen: no socket2 yet, retrying'
      sleep 2
      continue
    fi
    log "listen: following $SOCK"
    socat -u "UNIX-CONNECT:$SOCK" - | while IFS= read -r ev; do
      case $ev in
        openlayer\>\>wvkbd*)
          # Let the compositor apply the new exclusive zone first.
          sleep 0.35
          fit_once
          ;;
        closelayer\>\>wvkbd*)
          sleep 0.2
          restore_once
          ;;
      esac
    done
    log 'listen: socket closed, reconnecting'
    sleep 1
  done
}

case ${1:-} in
  --listen) listen ;;
  --fit) fit_once ;;
  --restore) restore_once ;;
  --clamp) clamp_once ;;
  --status) [[ -s $STATE ]] && cat "$STATE" || echo 'no saved geometry' ;;
  *) echo "Usage: $(basename "$0") --listen|--fit|--restore|--clamp|--status" >&2; exit 2 ;;
esac
