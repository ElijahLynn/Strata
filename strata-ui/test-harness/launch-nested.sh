#!/usr/bin/env bash
# launch-nested.sh — reusable headless nested GNOME Shell for autonomous verification.
#
# Brings up a throwaway, headless gnome-shell (its own temp XDG profile + private
# session bus), with the unsafe-mode harness helper enabled so the loop can
# Screenshot and Eval/drive it. The Strata daemon, when the extension under test
# spawns it, writes to the temp profile — never your real clipboard.
#
# Source it for the functions, or run `launch-nested.sh --smoke [WxH]` to self-test
# (bring up, screenshot, tear down).
#
# Functions (after `nested_up`):
#   nested_up [WxH] [EXTRA_EXT_DIR]   launch; exports NESTED_BUS, NESTED_TMP
#   nested_eval "<js>"                run JS in the shell (returns gdbus output)
#   nested_key  <Clutter.KEY_x>       press+release a key via a virtual device
#   nested_type "<text>"              type a string (ascii)
#   nested_screenshot <path.png>      capture the stage to a PNG
#   nested_enable_ext <uuid>          enable an already-installed extension
#   nested_down                       kill the shell and remove the temp profile
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_SRC="$HARNESS_DIR/test-ext/strata-harness@local"
HELPER_UUID="strata-harness@local"

NESTED_TMP=""; NESTED_PID=""; NESTED_KEEPER=""; NESTED_BUS=""

_ncall() { DBUS_SESSION_BUS_ADDRESS="$NESTED_BUS" gdbus call --session "$@"; }

nested_up() {
  local res="${1:-1280x720}" extra_ext="${2:-}"
  NESTED_TMP="$(mktemp -d -t strata-nested-XXXXXX)"
  export XDG_DATA_HOME="$NESTED_TMP/data" XDG_CACHE_HOME="$NESTED_TMP/cache"
  export XDG_CONFIG_HOME="$NESTED_TMP/config" XDG_STATE_HOME="$NESTED_TMP/state"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local extdir="$XDG_DATA_HOME/gnome-shell/extensions"
  mkdir -p "$extdir" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"

  cp -r "$HELPER_SRC" "$extdir/"
  local list="'$HELPER_UUID'"
  if [ -n "$extra_ext" ]; then
    cp -r "$extra_ext" "$extdir/"
    list="$list, '$(basename "$extra_ext")'"
  fi
  # Pass the GVariant array + resolution as env vars so the inner shell expands
  # them cleanly (no nested-quote juggling — that was the bug).
  export NESTED_ENABLED="[$list]" NESTED_RES="$res"

  # Background the private session running the headless shell.
  ( dbus-run-session -- bash -c '
      gsettings set org.gnome.shell disable-user-extensions false
      gsettings set org.gnome.shell enabled-extensions "$NESTED_ENABLED"
      exec gnome-shell --headless --virtual-monitor "$NESTED_RES" --wayland
    ' >"$NESTED_TMP/shell.log" 2>&1 ) &
  NESTED_KEEPER=$!

  # Find the nested shell PID, then read its private bus address from /proc.
  local i
  for i in $(seq 1 120); do
    NESTED_PID="$(pgrep -n -f 'gnome-shell.*--headless' || true)"
    [ -n "$NESTED_PID" ] && break
    kill -0 "$NESTED_KEEPER" 2>/dev/null || { echo "launch-nested: session died; see $NESTED_TMP/shell.log" >&2; return 1; }
    sleep 0.3
  done
  [ -n "$NESTED_PID" ] || { echo "launch-nested: no nested shell" >&2; return 1; }
  NESTED_BUS="$(tr '\0' '\n' < "/proc/$NESTED_PID/environ" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')"
  [ -n "$NESTED_BUS" ] || { echo "launch-nested: no nested bus" >&2; return 1; }

  # Wait until the shell + screenshot service are up, then until unsafe mode is on.
  for i in $(seq 1 120); do
    _ncall --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.NameHasOwner org.gnome.Shell.Screenshot 2>/dev/null | grep -q true && break
    sleep 0.3
  done
  for i in $(seq 1 40); do
    nested_eval "global.context.unsafe_mode" 2>/dev/null | grep -q "true" && break
    sleep 0.3
  done
  echo "launch-nested: up (pid=$NESTED_PID, $res)" >&2
}

nested_eval() { _ncall --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval "$1"; }

nested_screenshot() { _ncall --dest org.gnome.Shell.Screenshot --object-path /org/gnome/Shell/Screenshot \
  --method org.gnome.Shell.Screenshot.Screenshot true false "$1" >/dev/null; }

nested_enable_ext() { _ncall --dest org.gnome.Shell.Extensions --object-path /org/gnome/Shell/Extensions \
  --method org.gnome.Shell.Extensions.EnableExtension "$1" >/dev/null 2>&1 || true; }

nested_key() {
  nested_eval "
    const C = imports.gi.Clutter;
    if (!global._hk) global._hk = C.get_default_backend().get_default_seat()
        .create_virtual_device(C.InputDeviceType.KEYBOARD_DEVICE);
    const t = global.get_current_time();
    global._hk.notify_keyval(t, C.KEY_$1, C.KeyState.PRESSED);
    global._hk.notify_keyval(t, C.KEY_$1, C.KeyState.RELEASED);
  " >/dev/null
}

nested_type() {
  local s="$1" i ch
  for (( i=0; i<${#s}; i++ )); do
    ch="${s:$i:1}"; [ "$ch" = " " ] && ch="space"
    nested_key "$ch"
  done
}

nested_down() {
  [ -n "$NESTED_PID" ] && kill "$NESTED_PID" 2>/dev/null
  [ -n "$NESTED_KEEPER" ] && kill "$NESTED_KEEPER" 2>/dev/null
  pkill -f 'gnome-shell.*--headless' 2>/dev/null
  [ -n "$NESTED_TMP" ] && rm -rf "$NESTED_TMP"
  NESTED_PID=""; NESTED_KEEPER=""; NESTED_BUS=""; NESTED_TMP=""
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--smoke" ]; then
  trap nested_down EXIT
  nested_up "${2:-1280x720}" || exit 1
  out="${SMOKE_OUT:-/tmp/strata-nested-smoke.png}"
  nested_screenshot "$out"
  if [ -s "$out" ]; then
    echo "smoke: OK — $(file -b "$out")"
    echo "SMOKE_SHOT=$out"
  else
    echo "smoke: FAILED — no screenshot" >&2; exit 1
  fi
fi
