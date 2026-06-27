#!/usr/bin/env bash
# verify.sh <feature-id> — install the built extension in a throwaway headless shell,
# assert it enables cleanly + run the feature's checks, screenshot. Exit 0 = PASS.
# The agent (or the loop) calls this and only flips passes:true when it returns 0.
set -uo pipefail

ID="${1:?usage: verify.sh <feature-id>}"
HARNESS="$(cd "$(dirname "$0")" && pwd)"
UI="$(dirname "$HARNESS")"
EXT="$UI/extension"
UUID="strata-ui@elijahlynn.net"
SHOT="${SHOT:-$HARNESS/screenshots/$ID.png}"
mkdir --parents "$(dirname "$SHOT")"

[ -f "$EXT/metadata.json" ] || { echo "verify $ID: no extension/ built yet"; exit 1; }
glib-compile-schemas "$EXT/schemas" 2>/dev/null || true

source "$HARNESS/launch-nested.sh"
trap nested_down EXIT
STAGE="$(mktemp -d)"; cp -r "$EXT" "$STAGE/$UUID"
nested_up 1280x720 "$STAGE/$UUID" || { echo "verify $ID: nested_up failed"; exit 1; }
sleep 0.5

fail=0
chk(){ if [ "$1" = "$2" ]; then echo "  ok  : $3"; else echo "  FAIL: $3 (got '$1', want '$2')"; fail=1; fi; }
log(){ grep -aE "$1" "$NESTED_TMP/shell.log" 2>/dev/null; }
# Eval a JS expression that returns a number; print just that number.
# (Eval's D-Bus reply is `(true, '<json>')`; the success flag has no digits,
#  so the first integer in the line is the returned value.)
evnum(){ nested_eval "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1; }

# --- generic asserts (every feature) ---
chk "$(log '\[Strata UI\] enabled' | head -1 | grep -c .)" "1" "extension enable() ran (logged 'enabled')"
if log 'JS ERROR.*strata-ui|@strata-ui|\[Strata UI\].*([Ee]rror|[Ee]xception)' >/dev/null; then
  echo "  FAIL: JS errors mentioning strata-ui:"; log 'JS ERROR|@strata-ui|\[Strata UI\]' | tail -4; fail=1
else echo "  ok  : no strata-ui JS errors in shell log"; fi

# --- per-feature asserts ---
case "$ID" in
  001)
    nested_eval "Main.extensionManager.lookup('$UUID').stateObj._toggleVisor(); 'ok'" >/dev/null 2>&1 || true
    sleep 0.4
    chk "$(log '\[Strata UI\] visor shown' | head -1 | grep -c .)" "1" "Ctrl+Alt+C path shows the visor"
    vis=$(nested_eval "String((Main.extensionManager.lookup('$UUID').stateObj||{})._visorVisible)" 2>/dev/null | grep -oE 'true|false' | head -1)
    chk "${vis:-unknown}" "true" "visor is visible after toggle"
    ;;
  002)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- static asserts: architecture-constraints (St.Label only; real GetHistory; paced render) ---
    if grep -rqs 'set_markup(' "$EXT/ui" "$EXT/extension.js"; then
      echo "  FAIL: set_markup() called (clipboard content must never be parsed as markup)"; fail=1
    else echo "  ok  : no set_markup() (St.Label only)"; fi
    chk "$(grep -rqs 'GetHistoryAsync' "$EXT/ui" && echo y || echo n)" "y" "shelf fetches via GetHistory (GetHistoryAsync)"
    chk "$(grep -rqs 'idle_add'       "$EXT/ui" && echo y || echo n)" "y" "shelf renders via idle_add batches"

    # --- runtime: stub the fetch seam with 60 canned text metas, open, then drive a near-end scroll ---
    # _fetchPage(offset,limit) is the daemon seam; recording its args proves GetHistory(0,pageSize) etc.
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._sM=[]; for (var i=0;i<60;i++) _sM.push({id:'id'+i,mime_type:'text/plain',content_text:'card text number '+i,created_at:i,has_thumbnail:false});
      globalThis._sC=[];
      sh._fetchPage=function(o,l){ _sC.push([o,l]); return Promise.resolve(_sM.slice(o,o+l)); };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.9
    chk "$(evnum "$LU._shelf._cardBox.get_n_children()")" "50" "first page renders page-size (50) cards"
    chk "$(evnum "globalThis._sC[0][0]")" "0"  "first GetHistory offset is 0"
    chk "$(evnum "globalThis._sC[0][1]")" "50" "first GetHistory limit is page-size (50)"
    chk "$(evnum "$LU._shelf.renderStats.batchSize")" "20" "cards inserted in idle_add batches of 20"
    chk "$(evnum "$LU._shelf.renderStats.batches")"   "3"  "50 items => 3 paced batches (20/20/10)"
    chk "$(evnum "(function(){var S=imports.gi.St,c=$LU._shelf._cardBox.get_first_child(); return (c._textLabel instanceof S.Label)?1:0;})()")" "1" "card text actor is an St.Label"

    nested_eval "(function(){var sh=$LU._shelf,a=sh._scroll.get_hadjustment(); a.value=a.upper; sh._maybeLoadMore(); return 1;})()" >/dev/null 2>&1
    sleep 0.7
    chk "$(evnum "globalThis._sC.length")" "2"  "scrolling within ~200px of the end fetches the next page"
    chk "$(evnum "globalThis._sC[1][0]")" "50" "second page offset is loadedOffset (50)"
    chk "$(evnum "$LU._shelf._cardBox.get_n_children()")" "60" "all 60 cards present after the second page"
    chk "$(evnum "(function(){return $LU._shelf._hasMore?1:0;})()")" "0" "short final page clears _hasMore (full table never in JS memory)"
    ;;

  003)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    THUMBS="$XDG_CACHE_HOME/strata/thumbnails"
    # --- static asserts: on-demand thumbnails fetched per visible card, cached, unlinked on delete ---
    chk "$(grep -rqs 'GetThumbnailAsync' "$EXT/ui" && echo y || echo n)" "y" "shelf fetches thumbnails via GetThumbnail"
    chk "$(grep -rqs 'strata/thumbnails' "$EXT/ui" && echo y || echo n)" "y" "thumbnails cached under ~/.cache/strata/thumbnails"
    chk "$(grep -rqs 'unlink'             "$EXT/ui" && echo y || echo n)" "y" "cached thumbnail unlinked on delete"

    # --- runtime: 60 image metas; stub fetch seams and record which thumbnail ids are requested ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._iM=[]; for (var i=0;i<60;i++) _iM.push({id:'img'+i,mime_type:'image/png',content_text:null,created_at:i,has_thumbnail:true});
      globalThis._iF=[];
      sh._fetchPage=function(o,l){ return Promise.resolve(_iM.slice(o,o+l)); };
      sh._fetchThumbnail=function(id){ _iF.push(id); return Promise.resolve(new Uint8Array([137,80,78,71,13,10,26,10,1,2,3])); };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 1.3
    chk "$(evnum "(function(){return (globalThis._iF.indexOf('img0')>=0)?1:0;})()")" "1" "visible image card fetches its thumbnail (GetThumbnail per visible row)"
    chk "$(evnum "(function(){return (globalThis._iF.indexOf('img40')>=0)?1:0;})()")" "0" "off-screen image card issues NO thumbnail D-Bus traffic"
    chk "$(evnum "(function(){return (globalThis._iF.length>=1 && globalThis._iF.length<=12)?1:0;})()")" "1" "only the handful of visible cards fetched (not the whole page)"
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('img0'); return (((c._thumbContainer.style)||'').indexOf('background-image')>=0)?1:0;})()")" "1" "visible card shows the loaded thumbnail (background-image set)"
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('img40'); return ((((c._thumbContainer.style)||'').indexOf('background-image')<0))?1:0;})()")" "1" "off-screen card still shows the placeholder (no background-image)"
    chk "$([ -f "$THUMBS/img0.png" ] && echo y || echo n)" "y" "thumbnail cached to disk (~/.cache/strata/thumbnails/img0.png)"

    # scroll img40 into view -> it (and only newly-visible cards) fetches now
    nested_eval "(function(){var sh=$LU._shelf,c=sh._cards.get('img40'),b=c.get_allocation_box(),a=sh._scroll.get_hadjustment(); a.value=Math.max(0,b.x1-100); return 1;})()" >/dev/null 2>&1
    sleep 0.8
    chk "$(evnum "(function(){return (globalThis._iF.indexOf('img40')>=0)?1:0;})()")" "1" "scrolling an off-screen card into view fetches its thumbnail"
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('img40'); return (((c._thumbContainer.style)||'').indexOf('background-image')>=0)?1:0;})()")" "1" "newly-visible card now shows its thumbnail"

    # ItemDeleted unlinks the cached file and drops the card
    nested_eval "$LU._shelf.onItemDeleted('img0')" >/dev/null 2>&1
    sleep 0.3
    chk "$([ -f "$THUMBS/img0.png" ] && echo y || echo n)" "n" "ItemDeleted unlinks the cached thumbnail file"
    chk "$(evnum "(function(){return $LU._shelf._cards.has('img0')?1:0;})()")" "0" "ItemDeleted removes the card from the shelf"
    ;;

  *) echo "  note: no feature-specific checks for $ID (generic only)";;
esac

nested_screenshot "$SHOT" && echo "  shot: $SHOT"
if [ "$fail" = 0 ]; then echo "verify $ID: PASS"; exit 0; else echo "verify $ID: FAIL"; exit 1; fi
