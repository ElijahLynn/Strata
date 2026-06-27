#!/usr/bin/env bash
# Initializer for the Strata UI long-running-agent harness.
# Runs once. Sets up a live-reloading install of the extension and checks prereqs.
# https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
set -euo pipefail
shopt -s nullglob

REPO="$(cd "$(dirname "$0")/.." && pwd)"          # .../strata-ui
EXT_SRC="$REPO/extension"
UUID="strata-ui@elijahlynn.net"
EXT_DST="$HOME/.local/share/gnome-shell/extensions/$UUID"

mkdir -p "$EXT_SRC" "$(dirname "$EXT_DST")"

# Live-reload symlink: in-repo edits reflect after a Shell reload, no reinstall.
if [ ! -e "$EXT_DST" ]; then
  ln -s "$EXT_SRC" "$EXT_DST"
  echo "linked $EXT_DST -> $EXT_SRC"
else
  echo "extension already linked at $EXT_DST"
fi

# Compile gschemas if any exist yet.
schemas=("$EXT_SRC"/schemas/*.gschema.xml)
if (( ${#schemas[@]} )); then
  glib-compile-schemas "$EXT_SRC/schemas" && echo "compiled schemas"
fi

# Daemon presence (we depend on it but never modify it — ADR-0003).
if command -v strata-daemon >/dev/null; then
  echo "strata-daemon: $(command -v strata-daemon)"
else
  echo "WARNING: strata-daemon not on PATH. Build it from the Strata repo (make / cargo build -p strata-daemon) and put it on PATH."
fi

cat <<EOF

Setup done. To test the extension in a live GNOME session:
  Wayland:  log out and back in, then:  gnome-extensions enable $UUID
  Nested:   dbus-run-session -- gnome-shell --nested --wayland   (then enable)
  Logs:     journalctl -f -o cat /usr/bin/gnome-shell   (or: journalctl --user -f)
EOF
