#!/usr/bin/env bash
# install.sh — install Strata UI into YOUR GNOME session to try it by hand.
# Symlinks extension/ for live reload, compiles schemas, checks the daemon.
#
# The autonomous loop does NOT use this — it verifies in a throwaway nested shell
# (test-harness/launch-nested.sh, verify.sh). This is just for human dev.
set -o errexit -o nounset -o pipefail
shopt -s nullglob

REPO="$(cd "$(dirname "$0")/.." && pwd)"          # .../strata-ui
EXT_SRC="$REPO/extension"
UUID="strata-ui@elijahlynn.net"
EXT_DST="$HOME/.local/share/gnome-shell/extensions/$UUID"

[ -d "$EXT_SRC" ] || { echo "no $EXT_SRC yet — build the extension first"; exit 1; }
mkdir --parents "$(dirname "$EXT_DST")"

if [ ! -e "$EXT_DST" ]; then
  ln --symbolic "$EXT_SRC" "$EXT_DST"; echo "linked $EXT_DST -> $EXT_SRC"
else
  echo "already linked at $EXT_DST"
fi

schemas=("$EXT_SRC"/schemas/*.gschema.xml)
(( ${#schemas[@]} )) && { glib-compile-schemas "$EXT_SRC/schemas" && echo "compiled schemas"; }

command -v strata-daemon >/dev/null \
  && echo "strata-daemon: $(command -v strata-daemon)" \
  || echo "WARNING: strata-daemon not on PATH (build it in the Strata repo)."

cat <<EOF

Installed. Try it:
  Wayland: log out/in, then  gnome-extensions enable $UUID   (Ctrl+Alt+C to toggle)
  Headless instead:          bash test-harness/launch-nested.sh --smoke
  Logs:                      journalctl --user --follow --output cat | grep 'Strata UI'
EOF
