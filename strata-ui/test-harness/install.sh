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

# Run ONE Strata extension at a time. The original strata@edu4rdshl.dev and this
# strata-ui@elijahlynn.net both supervise the daemon, bind Ctrl+Alt+C, and capture
# the clipboard — enabling both makes them fight. Warn if the old one is on.
if gnome-extensions list --enabled 2>/dev/null | grep --quiet '^strata@edu4rdshl.dev$'; then
  cat <<'EOF'

WARNING: strata@edu4rdshl.dev is currently ENABLED. Running both Strata
extensions conflicts (daemon supervision, the Ctrl+Alt+C binding, clipboard
capture). Disable it before enabling Strata UI — see the steps below.
EOF
fi

cat <<'EOF'

Installed. Enable exactly ONE Strata extension, in this order:

  1. On Wayland, log out and back in first. A brand-new extension cannot be
     enabled until the shell re-reads the extensions directory.
  2. Disable the old extension:  gnome-extensions disable strata@edu4rdshl.dev
  3. Enable Strata UI:           gnome-extensions enable strata-ui@elijahlynn.net
       (or toggle both in the Extensions app)
  4. Press Ctrl+Alt+C to toggle the visor.

  Headless smoke test instead:  bash test-harness/launch-nested.sh --smoke
  Logs:  journalctl --user --follow --output cat | grep 'Strata UI'
EOF
