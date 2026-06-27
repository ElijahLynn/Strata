#!/usr/bin/env bash
# launch-nested.sh — reusable headless nested GNOME Shell for autonomous verification.
#
# Brings up a throwaway, headless gnome-shell (its own temp XDG profile + private
# session bus), with the unsafe-mode harness helper enabled so the loop can
# Screenshot and Eval/drive it. The Strata daemon, when the extension under test
# spawns it, writes to the temp profile — never your real clipboard.
#
# Source it for the functions, or run `launch-nested.sh --smoke [WxH]` to self-test.
#
# Reliability notes (learned the hard way):
#   - The inner session writes its private bus address to a file; we never guess it
#     with pgrep (which matched stale shells AND the pre-exec wrapper bash).
#   - The session runs under setsid, so teardown kills the exact process group —
#     no broad `pkill -f` (which self-matched our own command line) and no orphans.
#   - Every gdbus call has --timeout 6 so nothing can stall on D-Bus's 25s default.
#   - Do NOT call org.gnome.Shell.Extensions.EnableExtension on a headless shell:
#     that service isn't running, so the call blocks the full 25s activation timeout.
#     The helper auto-enables via enabled-extensions instead (unsafe mode on in ~1.7s).
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_SRC="$HARNESS_DIR/test-ext/strata-harness@local"
HELPER_UUID="strata-harness@local"

NESTED_TMP=""; NESTED_KEEPER=""; NESTED_BUS=""

_ncall() { DBUS_SESSION_BUS_ADDRESS="$NESTED_BUS" gdbus call --session --timeout 6 "$@"; }

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
  # Pass values via env so the inner session expands them (no nested-quote juggling).
  export NESTED_ENABLED="[$list]" NESTED_RES="$res"
  export NESTED_BUSFILE="$NESTED_TMP/bus"
  # Trim the nested session (small win; the big cost was the EnableExtension stall).
  export NO_AT_BRIDGE=1 GTK_A11Y=none GVFS_DISABLE_FUSE=1
  : > "$NESTED_BUSFILE"

  # Inner session as a script file — dodges all the nested-quoting traps.
  cat > "$NESTED_TMP/session.sh" <<'EOS'
#!/usr/bin/env bash
gsettings set org.gnome.shell disable-user-extensions false
gsettings set org.gnome.shell enabled-extensions "$NESTED_ENABLED"
printf %s "$DBUS_SESSION_BUS_ADDRESS" > "$NESTED_BUSFILE"
exec gnome-shell --headless --virtual-monitor "$NESTED_RES" --wayland
EOS

  # setsid → its own process group, so nested_down can kill the whole tree exactly.
  setsid bash -c 'dbus-run-session -- bash "$1"' _ "$NESTED_TMP/session.sh" \
    >"$NESTED_TMP/shell.log" 2>&1 &
  NESTED_KEEPER=$!

  # Reliable bus: read what the inner session wrote.
  local i
  for i in $(seq 1 100); do
    [ -s "$NESTED_BUSFILE" ] && { NESTED_BUS="$(cat "$NESTED_BUSFILE")"; break; }
    kill -0 "$NESTED_KEEPER" 2>/dev/null || { echo "launch-nested: session died; see $NESTED_TMP/shell.log" >&2; return 1; }
    sleep 0.2
  done
  [ -n "$NESTED_BUS" ] || { echo "launch-nested: no nested bus" >&2; return 1; }

  # Wait until unsafe mode is on (helper auto-enables; Eval is gated by it, so an
  # Eval that returns true is the signal the shell is up AND the helper ran).
  local unsafe=0
  for i in $(seq 1 80); do
    nested_eval "global.context.unsafe_mode" 2>/dev/null | grep -q "true" && { unsafe=1; break; }
    sleep 0.2
  done
  [ "$unsafe" = 1 ] || { echo "launch-nested: WARNING unsafe_mode not confirmed; aborting" >&2; return 1; }
  echo "launch-nested: up ($res)" >&2
}

nested_eval() { _ncall --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval "$1"; }

nested_screenshot() { _ncall --dest org.gnome.Shell.Screenshot --object-path /org/gnome/Shell/Screenshot \
  --method org.gnome.Shell.Screenshot.Screenshot true false "$1" >/dev/null; }

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

# nested_click_xy <x> <y>
# Synthesize a REAL primary mouse click at absolute stage coords (x,y) with a
# Clutter virtual POINTER device (mirrors nested_key's virtual KEYBOARD). The three
# notifies — motion, button-PRESSED, button-RELEASED — are issued as SEPARATE Eval
# calls with a settle between them: Clutter dispatches input on the main loop, so a
# press+release fired back-to-back in one synchronous call (same timestamp, no loop
# turn) gets coalesced and an St.Button inside a ScrollView never sees the release →
# no 'clicked'. Separate calls let each event run a main-loop turn, the way a real
# click does. Drives the actual button-press/-release chain through the visor's
# handlers (NOT a direct activate()/handler call), so a coordinate bug in a
# button-press handler is genuinely exercised.
nested_click_xy() {
  local x="$1" y="$2"
  # Land the virtual pointer on (x,y), then PRESS + RELEASE.
  #
  # Two non-obvious quirks of the headless virtual pointer, both learned by reading
  # back global.get_pointer():
  #  1) A single notify_absolute_motion to a fresh target only applies the X delta —
  #     the first event after a position change drops the Y axis (pointer lands at
  #     [x, oldY]). A SECOND motion to the same (x,y) settles Y. So we send the
  #     target motion twice.
  #  2) Mutter only re-picks the actor under the pointer when the position actually
  #     CHANGES, so we hop via (0,0) first to guarantee the target motion is a real
  #     move (a click at wherever the pointer already sat would land on a stale
  #     actor and the target St.Button — especially one inside a ScrollView — would
  #     never see the press).
  # Each notify is its own Eval with a settle: Clutter dispatches input on the main
  # loop, so a press+release fired back-to-back in one synchronous call (no loop
  # turn) gets coalesced and the release is lost. Drives the real button-press/
  # -release chain THROUGH the visor's handler — not a direct activate()/handler
  # call — so a coordinate bug in that handler is genuinely exercised.
  nested_eval "(function(){
    const C = imports.gi.Clutter;
    if (!global._hp) global._hp = C.get_default_backend().get_default_seat()
        .create_virtual_device(C.InputDeviceType.POINTER_DEVICE);
    global._hp.notify_absolute_motion(global.get_current_time(), 0, 0);
    return 1;
  })()" >/dev/null
  sleep 0.1
  nested_eval "global._hp.notify_absolute_motion(global.get_current_time(), $x, $y)" >/dev/null
  sleep 0.1
  nested_eval "global._hp.notify_absolute_motion(global.get_current_time(), $x, $y)" >/dev/null
  sleep 0.1
  nested_eval "global._hp.notify_button(global.get_current_time(), imports.gi.Clutter.BUTTON_PRIMARY, imports.gi.Clutter.ButtonState.PRESSED)" >/dev/null
  sleep 0.1
  nested_eval "global._hp.notify_button(global.get_current_time(), imports.gi.Clutter.BUTTON_PRIMARY, imports.gi.Clutter.ButtonState.RELEASED)" >/dev/null
  sleep 0.1
}

# nested_click <js-expr-returning-an-actor>
# Click the on-screen centre of the actor that <js-expr> evaluates to. Resolves the
# actor's absolute stage rectangle via get_transformed_position()+_size(), then
# delegates to nested_click_xy.
nested_click() {
  local cxy
  cxy="$(nested_eval "(function(){
    const a = ($1);
    if (!a) return 'no-actor';
    const [ax, ay] = a.get_transformed_position();
    const [aw, ah] = a.get_transformed_size();
    return Math.round(ax + aw / 2) + ' ' + Math.round(ay + ah / 2);
  })()" 2>/dev/null | grep -oE '[0-9]+ [0-9]+' | head -1)"
  [ -n "$cxy" ] || { echo "nested_click: could not resolve actor center" >&2; return 1; }
  nested_click_xy $cxy
}

nested_down() {
  if [ -n "$NESTED_KEEPER" ]; then
    kill -- "-$NESTED_KEEPER" 2>/dev/null   # whole process group (setsid leader)
    kill "$NESTED_KEEPER" 2>/dev/null
  fi
  [ -n "$NESTED_TMP" ] && rm -rf "$NESTED_TMP"
  NESTED_KEEPER=""; NESTED_BUS=""; NESTED_TMP=""
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--smoke" ]; then
  trap nested_down EXIT
  nested_up "${2:-1280x720}" || exit 1
  out="${SMOKE_OUT:-/tmp/strata-nested-smoke.png}"
  nested_screenshot "$out"
  if [ -s "$out" ]; then
    echo "smoke: OK — $(file -b "$out")"
  else
    echo "smoke: FAILED — no screenshot" >&2; exit 1
  fi
fi
