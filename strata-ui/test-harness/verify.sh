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

# --- regression suite (slice 015): `verify.sh all` runs every feature id that
#     has a case block below, each in its own throwaway nested shell, and exits
#     non-zero if ANY fails. Short-circuits before the single-case setup so the
#     parent never boots a shell of its own. ---
if [ "$ID" = "all" ]; then
  ids=$(grep -oE '^[[:space:]]+[0-9]{3}\)' "$0" | grep -oE '[0-9]{3}' | sort --unique)
  passed=""; failed=""; rc=0
  for id in $ids; do
    printf '\n==================== verify %s ====================\n' "$id"
    if bash "$0" "$id"; then passed="$passed $id"; else failed="$failed $id"; rc=1; fi
  done
  printf '\n==================== regression summary ====================\n'
  printf '  PASS:%s\n' "${passed:- (none)}"
  printf '  FAIL:%s\n' "${failed:- (none)}"
  [ "$rc" -eq 0 ] && echo "  ALL GREEN" || echo "  REGRESSIONS PRESENT"
  exit "$rc"
fi

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

  004)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- static asserts: FTS5 prefix search via daemon, debounced, epoch-guarded ---
    chk "$(grep -rqs 'SearchHistoryAsync' "$EXT/ui" && echo y || echo n)" "y" "search calls SearchHistory"
    chk "$(grep -rqs 'SEARCH_DEBOUNCE'    "$EXT/ui" && echo y || echo n)" "y" "search input is debounced"

    # --- runtime: stub browse + search seams; open and exercise the search box ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._bM=[]; for (var i=0;i<10;i++) _bM.push({id:'b'+i,mime_type:'text/plain',content_text:'browse '+i,created_at:i,has_thumbnail:false});
      globalThis._res={foo:[],abc:[]};
      for (var i=0;i<45;i++) _res.foo.push({id:'f'+i,mime_type:'text/plain',content_text:'foo result '+i,created_at:i,has_thumbnail:false});
      for (var i=0;i<4;i++)  _res.abc.push({id:'a'+i,mime_type:'text/plain',content_text:'abc '+i,created_at:i,has_thumbnail:false});
      globalThis._sq=[]; globalThis._bq=0;
      sh._fetchPage  =function(o,l){ _bq++; return Promise.resolve(_bM.slice(o,o+l)); };
      sh._fetchSearch=function(q,l){ _sq.push([q,l]); return Promise.resolve((_res[q]||[]).slice()); };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 1.0
    chk "$(evnum "$LU._shelf._cardBox.get_n_children()")" "10" "opens in browse view (recent history)"
    # Open-focus reality (slice 025): with cards present the visor opens focused on
    # the FIRST card (whole-card highlight), NOT the search box. (The old search-
    # first assertion became false when 025 landed; search still works below — the
    # later assertions drive the search box directly, which is what 004 protects.)
    chk "$(evnum "(function(){return global.stage.get_key_focus()===$LU._shelf._cardBox.get_first_child()?1:0;})()")" "1" "opens focused on the first card (025), not the search box"
    chk "$(evnum "(function(){return global.stage.get_key_focus()===$LU._searchEntry.get_clutter_text()?1:0;})()")" "0" "the search box is NOT focused on open (no longer search-first)"

    # type 'foo' -> debounced SearchHistory('foo', max-history) -> 45 results via idle_add batches
    nested_eval "(function(){ $LU._shelf.renderStats.batches=0; $LU._searchEntry.set_text('foo'); return 1; })()" >/dev/null 2>&1
    sleep 0.5
    chk "$(evnum "globalThis._sq.length")" "1" "typing issues one SearchHistory query (debounced)"
    chk "$(evnum "(function(){return (globalThis._sq[0][0]==='foo')?1:0;})()")" "1" "query string is passed to SearchHistory"
    chk "$(evnum "globalThis._sq[0][1]")" "2000" "SearchHistory limit is max-history (2000)"
    chk "$(evnum "$LU._shelf._cardBox.get_n_children()")" "45" "search results replace the shelf"
    chk "$(evnum "$LU._shelf.renderStats.batches")" "3" "results render through the same idle_add batches (45 => 3)"

    # three rapid keystrokes collapse to a single query (debounce)
    nested_eval "(function(){ globalThis._sq=[]; var en=$LU._searchEntry; en.set_text('a'); en.set_text('ab'); en.set_text('abc'); return 1; })()" >/dev/null 2>&1
    sleep 0.5
    chk "$(evnum "globalThis._sq.length")" "1" "3 rapid keystrokes debounce to 1 query"
    chk "$(evnum "(function(){return (globalThis._sq[globalThis._sq.length-1][0]==='abc')?1:0;})()")" "1" "only the final keystroke's query runs"
    chk "$(evnum "$LU._shelf._cardBox.get_n_children()")" "4" "shelf shows the final query's results"

    # clear the box -> browse view restored
    nested_eval "(function(){ globalThis._bq=0; $LU._searchEntry.set_text(''); return 1; })()" >/dev/null 2>&1
    sleep 0.5
    chk "$(evnum "(function(){return (globalThis._bq>=1)?1:0;})()")" "1" "empty query re-fetches recent history (GetHistory)"
    chk "$(evnum "$LU._shelf._cardBox.get_n_children()")" "10" "empty query restores the browse view"

    # epoch guard: a superseded search response must not paint over a newer one
    nested_eval "(function(){
      var sh=$LU._shelf;
      globalThis._gate={}; globalThis._er={s1:[],s2:[]};
      for (var i=0;i<3;i++) _er.s1.push({id:'x'+i,mime_type:'text/plain',content_text:'s1 '+i,created_at:i});
      for (var i=0;i<7;i++) _er.s2.push({id:'y'+i,mime_type:'text/plain',content_text:'s2 '+i,created_at:i});
      sh._fetchSearch=function(q,l){ return new Promise(function(res){ _gate[q]=function(){ res(_er[q].slice()); }; }); };
      sh._runQuery('s1'); sh._runQuery('s2'); return 1;
    })()" >/dev/null 2>&1
    sleep 0.2
    nested_eval "(function(){ globalThis._gate.s1(); return 1; })()" >/dev/null 2>&1   # stale response resolves first
    sleep 0.2
    nested_eval "(function(){ globalThis._gate.s2(); return 1; })()" >/dev/null 2>&1   # newest resolves second
    sleep 0.4
    chk "$(evnum "$LU._shelf._cardBox.get_n_children()")" "7" "newest search wins (7 results), not the stale 3"
    chk "$(evnum "(function(){return $LU._shelf._cards.has('x0')?1:0;})()")" "0" "stale search response is dropped (epoch guard)"
    ;;

  005)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- static asserts: paste-back via daemon; never synthesize a paste (ADR-0005) ---
    chk "$(grep -rqs 'GetItemContentAsync' "$EXT/ui" && echo y || echo n)" "y" "paste-back fetches GetItemContent"
    chk "$(grep -rqs 'set_text'            "$EXT/ui" && echo y || echo n)" "y" "text paste-back uses St.Clipboard.set_text"
    chk "$(grep -rqs 'SelectionSourceMemory' "$EXT/ui" && echo y || echo n)" "y" "binary paste-back uses Meta.SelectionSourceMemory"
    if grep -rqsE 'notify_keyval|VirtualInputDevice|XTEST' "$EXT"; then
      echo "  FAIL: synthetic paste machinery found (must never paste into another app)"; fail=1
    else echo "  ok  : no synthetic paste is ever sent to another app"; fi

    # --- runtime: stub browse + content seams; exercise selection/copy/dismiss ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._bM=[]; for (var i=0;i<6;i++) _bM.push({id:'b'+i,mime_type:'text/plain',content_text:'browse '+i,created_at:i,has_thumbnail:false});
      _bM.push({id:'IMG',mime_type:'image/png',content_text:null,created_at:99,has_thumbnail:true});
      globalThis._fc=[];
      sh._fetchPage=function(o,l){ return Promise.resolve(_bM.slice(o,o+l)); };
      sh._fetchThumbnail=function(id){ return Promise.resolve(new Uint8Array([137,80,78,71])); };
      sh._fetchContent=function(id){
        _fc.push(id);
        if (id==='IMG') return Promise.resolve(['image/png', new Uint8Array([137,80,78,71,1,2,3])]);
        return Promise.resolve(['text/plain', new TextEncoder().encode('CONTENT-'+id)]);
      };
      // 010: these browse cards are stubbed (not in the real daemon), so the
      // clipboard monitor would re-capture each paste-back write as a NEW item
      // and prepend a card, fighting the move-to-top assertions. Production
      // dedups instead (db.rs hash match -> is_new=false -> no ItemAdded), so
      // this only bites the stub. Disable capture to test paste-back in isolation.
      if (e._disconnectClipboardMonitor) e._disconnectClipboardMonitor();
      return 1;
    })()" >/dev/null 2>&1
    reopen(){ nested_eval "(function(){var e=$LU; e._hideVisor(); e._settings.set_boolean('move-activated-to-top', ${1:-false}); e._showVisor(); return 1;})()" >/dev/null 2>&1; sleep 0.4; }
    fclast(){ evnum "(function(){var a=globalThis._fc; return (a.length && a[a.length-1]==='$1')?1:0;})()"; }

    # Enter on a focused card copies THAT card and dismisses
    reopen
    nested_eval "(function(){var sh=$LU._shelf; sh.activatePick(sh._cards.get('b2')); return 1;})()" >/dev/null 2>&1
    sleep 0.3
    chk "$(fclast b2)" "1" "Enter copies the focused card (GetItemContent for it)"
    chk "$(evnum "(function(){return ($LU._shelf._lastWrite && $LU._shelf._lastWrite.text==='CONTENT-b2')?1:0;})()")" "1" "focused card's text is written to the clipboard"
    chk "$(evnum "(function(){return $LU._visorVisible?1:0;})()")" "0" "copying dismisses the visor"

    # Enter while focus is still in search copies the TOP result
    reopen
    nested_eval "(function(){var sh=$LU._shelf; sh.activatePick(null); return 1;})()" >/dev/null 2>&1
    sleep 0.3
    chk "$(fclast b0)" "1" "Enter with focus in search copies the top result"

    # Alt+3 copies the 3rd visible card
    reopen
    nested_eval "(function(){$LU._shelf.activateVisibleIndex(3); return 1;})()" >/dev/null 2>&1
    sleep 0.3
    chk "$(fclast b2)" "1" "Alt+N copies the Nth visible card (3rd => b2)"

    # binary paste-back goes through Meta.SelectionSourceMemory, not set_text
    reopen
    nested_eval "(function(){var sh=$LU._shelf; sh.activate(sh._cards.get('IMG')); return 1;})()" >/dev/null 2>&1
    sleep 0.3
    chk "$(evnum "(function(){return ($LU._shelf._lastWrite && $LU._shelf._lastWrite.binary===true)?1:0;})()")" "1" "binary content uses the selection-owner path (no set_text)"

    # move-activated-to-top honored only when the setting is on
    reopen true
    nested_eval "(function(){var sh=$LU._shelf; sh.activatePick(sh._cards.get('b3')); return 1;})()" >/dev/null 2>&1
    sleep 0.3
    chk "$(evnum "(function(){return ($LU._shelf._cardBox.get_first_child().strataId==='b3')?1:0;})()")" "1" "move-activated-to-top ON: picked card jumps to the front"
    reopen false
    nested_eval "(function(){var sh=$LU._shelf; sh.activatePick(sh._cards.get('b3')); return 1;})()" >/dev/null 2>&1
    sleep 0.3
    chk "$(evnum "(function(){return ($LU._shelf._cardBox.get_first_child().strataId==='b0')?1:0;})()")" "1" "move-activated-to-top OFF: order is unchanged"

    # real keystroke: Return with the search box focused copies the top result + dismisses
    reopen
    nested_eval "(function(){ globalThis._fc=[]; return 1; })()" >/dev/null 2>&1
    nested_key Return
    sleep 0.3
    chk "$(fclast b0)" "1" "a real Return keystroke (focus in search) copies the top result"
    chk "$(evnum "(function(){return $LU._visorVisible?1:0;})()")" "0" "the real Return keystroke also dismisses"
    ;;

  006)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- static asserts: highlighting only on the Peek path; St.Label only (no markup) ---
    chk "$(grep -rqs 'lib/highlight'  "$EXT/ui/peek.js" && echo y || echo n)" "y" "Peek imports the syntax highlighter"
    chk "$(grep -rqs 'lib/highlight'  "$EXT/ui/card.js" && echo y || echo n)" "n" "shelf Cards never import the highlighter (highlighting only in Peek)"
    chk "$(grep -rqs 'set_attributes' "$EXT/ui/peek.js" && echo y || echo n)" "y" "Peek colorizes via Pango attributes (set_attributes), never markup"
    if grep -rqs 'set_markup(' "$EXT/ui" "$EXT/extension.js"; then
      echo "  FAIL: set_markup() found (clipboard content must never be parsed as markup)"; fail=1
    else echo "  ok  : no set_markup() anywhere (St.Label only)"; fi
    chk "$(grep -rqs 'GetItemContent' "$EXT/ui" && echo y || echo n)" "y" "Peek fetches full content via GetItemContent"

    # --- runtime: stub browse + content seams; a code entry, a prose entry, an image ---
    # The card preview is the short ~200-char text; the FULL content (with a tail
    # marker absent from the preview) comes via the GetItemContent seam — so a
    # Peek that shows the marker proves it fetched full content, not the preview.
    # NB: build multi-line code with String.fromCharCode(10) + join — a literal
    # '\n' inside a JS string does NOT survive the gdbus/Eval round-trip (it
    # collapses to a real line break and breaks the string literal).
    nested_eval "(function(){
      var e=$LU, sh=e._shelf, NL=String.fromCharCode(10);
      globalThis._CODE=['function greet(name){','  // say hello','  const msg = \"hi \" + name;','  return msg;','}','// ZZTAIL end-of-file marker'].join(NL);
      globalThis._bM=[
        {id:'code', mime_type:'text/plain', content_text:'function greet(name){ ...', created_at:5, has_thumbnail:false},
        {id:'prose',mime_type:'text/plain', content_text:'just some plain english',   created_at:4, has_thumbnail:false},
        {id:'img',  mime_type:'image/png',  content_text:null,                        created_at:3, has_thumbnail:true}
      ];
      globalThis._fc=[];
      sh._fetchPage=function(o,l){ return Promise.resolve(_bM.slice(o,o+l)); };
      sh._fetchThumbnail=function(id){ return Promise.resolve(new Uint8Array([137,80,78,71])); };
      sh._fetchContent=function(id){
        _fc.push(id);
        if (id==='img')  return Promise.resolve(['image/png', new Uint8Array([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,2,0,0,0,2,8,6,0,0,0,114,182,13,36,0,0,0,19,73,68,65,84,120,156,99,249,223,193,240,159,1,8,152,24,160,0,0,39,205,2,141,152,172,202,59,0,0,0,0,73,69,78,68,174,66,96,130])]); // a real 2x2 RGBA PNG (033: in-process decode)
        if (id==='code') return Promise.resolve(['text/plain', new TextEncoder().encode(globalThis._CODE)]);
        if (id==='prose')return Promise.resolve(['text/plain', new TextEncoder().encode('just some plain english words here with nothing special at all')]);
        return Promise.resolve(['text/plain', new TextEncoder().encode('X')]);
      };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.7

    # Peek a CODE entry: full content (GetItemContent), enlarged, syntax-highlighted
    nested_eval "(function(){ globalThis._fc=[]; $LU._shelf.peek($LU._shelf._cards.get('code')); return 1; })()" >/dev/null 2>&1
    sleep 0.4
    chk "$(evnum "(function(){return $LU._shelf.isPeeking()?1:0;})()")" "1" "Space opens the Peek overlay"
    chk "$(evnum "(function(){var a=globalThis._fc; return (a.length===1 && a[0]==='code')?1:0;})()")" "1" "Peek decodes ONLY the peeked entry (one GetItemContent)"
    chk "$(evnum "(function(){return ($LU._shelf._peek._textLabel.get_text().indexOf('ZZTAIL')>=0)?1:0;})()")" "1" "Peek shows the FULL content (beyond the shelf preview)"
    chk "$(evnum "(function(){return $LU._shelf._peek._rendered.isCode?1:0;})()")" "1" "code is detected as code"
    chk "$(evnum "(function(){return ($LU._shelf._peek._rendered.spanCount>1)?1:0;})()")" "1" "code is syntax-highlighted (multiple colored spans)"
    chk "$(evnum "(function(){return ($LU._shelf._peek._rendered.language)?1:0;})()")" "1" "a language is detected for highlighting"
    # The shelf Card shows only the cheap truncated preview — never the full
    # content the Peek fetched+highlighted (proves the highlight path is Peek-only;
    # the static check above proves card.js never even imports the highlighter).
    chk "$(evnum "(function(){var t=$LU._shelf._cards.get('code')._textLabel.get_text(); return (t.indexOf('ZZTAIL')<0 && t.indexOf('return msg')<0)?1:0;})()")" "1" "the shelf Card shows the plain preview, never the highlighted full content"

    # Space again (or Escape) dismisses back to the shelf
    nested_eval "(function(){ $LU._shelf.closePeek(); return 1; })()" >/dev/null 2>&1
    sleep 0.2
    chk "$(evnum "(function(){return $LU._shelf.isPeeking()?1:0;})()")" "0" "Space-again / Escape dismisses the Peek"

    # Peek an IMAGE entry: full-res image via GetItemContent, decoded on demand (one image)
    nested_eval "(function(){ globalThis._fc=[]; $LU._shelf.peek($LU._shelf._cards.get('img')); return 1; })()" >/dev/null 2>&1
    sleep 0.4
    chk "$(evnum "(function(){return $LU._shelf.isPeeking()?1:0;})()")" "1" "Space opens the Peek for an image"
    chk "$(evnum "(function(){var a=globalThis._fc; return (a.length===1 && a[0]==='img')?1:0;})()")" "1" "the image is decoded on demand (one GetItemContent on keypress)"
    chk "$(evnum "(function(){return ($LU._shelf._peek._rendered.kind==='image')?1:0;})()")" "1" "image Peek shows the full-resolution image"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._imageView&&(p._imageView.get_content() instanceof imports.gi.Clutter.Content))?1:0;})()")" "1" "the decoded image blob is applied to the Peek image view as an in-process content (033)"
    nested_eval "(function(){ $LU._shelf.closePeek(); return 1; })()" >/dev/null 2>&1
    sleep 0.2

    # plain prose peeks as plain text — no highlighting (highlighting is code-only)
    nested_eval "(function(){ $LU._shelf.peek($LU._shelf._cards.get('prose')); return 1; })()" >/dev/null 2>&1
    sleep 0.4
    chk "$(evnum "(function(){return $LU._shelf._peek._rendered.isCode?1:0;})()")" "0" "plain prose is not syntax-highlighted"
    chk "$(evnum "$LU._shelf._peek._rendered.spanCount")" "0" "plain prose Peek applies no color spans"
    nested_eval "(function(){ $LU._shelf.closePeek(); return 1; })()" >/dev/null 2>&1
    sleep 0.2

    # peekFocused() respects keyboard focus: search box -> no Peek; a focused card -> Peek
    nested_eval "(function(){ var e=$LU; global.stage.set_key_focus(e._searchEntry.get_clutter_text()); e._shelf.peekFocused(); return 1; })()" >/dev/null 2>&1
    sleep 0.3
    chk "$(evnum "(function(){return $LU._shelf.isPeeking()?1:0;})()")" "0" "Space in the search box types a space (no Peek when no card is focused)"
    nested_eval "(function(){ var sh=$LU._shelf, c=sh._cards.get('code'); global.stage.set_key_focus(c); sh.peekFocused(); return 1; })()" >/dev/null 2>&1
    sleep 0.4
    chk "$(evnum "(function(){return $LU._shelf.isPeeking()?1:0;})()")" "1" "Space on a focused card opens its Peek"

    # a REAL Escape keystroke closes the Peek, NOT the whole visor (capture-phase wiring)
    nested_key Escape
    sleep 0.3
    chk "$(evnum "(function(){return $LU._shelf.isPeeking()?1:0;})()")" "0" "a real Escape dismisses the Peek"
    chk "$(evnum "(function(){return $LU._visorVisible?1:0;})()")" "1" "Escape closes only the Peek; the visor stays open"

    # leave a highlighted code Peek up for the screenshot
    nested_eval "(function(){ $LU._shelf.peek($LU._shelf._cards.get('code')); return 1; })()" >/dev/null 2>&1
    sleep 0.3
    ;;

  007)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- static asserts: cheap client-side regex classification; St.Label only ---
    chk "$(grep -rqs 'cardType' "$EXT/ui/card.js" && echo y || echo n)" "y" "cards are classified by type (cardType)"
    if grep -rqs 'set_markup(' "$EXT/ui" "$EXT/extension.js"; then
      echo "  FAIL: set_markup() found (clipboard content must never be parsed as markup)"; fail=1
    else echo "  ok  : no set_markup() anywhere (St.Label only)"; fi
    # classification must stay on the client (regex) — no daemon round-trip for type
    chk "$(grep -rqs 'test(' "$EXT/ui/card.js" && echo y || echo n)" "y" "classification is cheap client-side regex"

    # --- runtime: feed one meta per type; assert each renders its type-specific body ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf, NL=String.fromCharCode(10);
      globalThis._URIS=['file:///home/user/photo.png','file:///home/user/notes.txt'].join(NL);
      globalThis._bM=[
        {id:'url',   mime_type:'text/plain',   content_text:'https://example.com/path?q=1', created_at:9, has_thumbnail:false},
        {id:'col3',  mime_type:'text/plain',   content_text:'#3af',                          created_at:8, has_thumbnail:false},
        {id:'col6',  mime_type:'text/plain',   content_text:'#1188ff',                       created_at:7, has_thumbnail:false},
        {id:'file',  mime_type:'text/uri-list',content_text:globalThis._URIS,                created_at:6, has_thumbnail:false},
        {id:'plain', mime_type:'text/plain',   content_text:'just some regular note text',   created_at:5, has_thumbnail:false},
        {id:'img',   mime_type:'image/png',    content_text:null,                            created_at:4, has_thumbnail:true},
        {id:'noturl',mime_type:'text/plain',   content_text:'visit https://x.io for info',   created_at:3, has_thumbnail:false}
      ];
      sh._fetchPage=function(o,l){ return Promise.resolve(_bM.slice(o,o+l)); };
      sh._fetchThumbnail=function(id){ return Promise.resolve(new Uint8Array([137,80,78,71])); };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.8
    ctype(){ nested_eval "(function(){var c=$LU._shelf._cards.get('$1'); return c?c.cardType:'none';})()" 2>/dev/null | grep -oE "(link|color|file|text|image|none)" | head -1; }

    # URL → link card with the hostname as a subtitle
    chk "$(ctype url)" "link" "a URL entry renders as a Link card"
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('url'); return (c._subtitle && c._subtitle.get_text()==='example.com')?1:0;})()")" "1" "Link card shows the hostname as a subtitle"

    # #rgb / #rrggbb → color swatch carrying the hex
    chk "$(ctype col3)" "color" "a #rgb entry renders as a Color card"
    chk "$(ctype col6)" "color" "a #rrggbb entry renders as a Color card"
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('col3'); return ((c._swatch.style||'').toLowerCase().indexOf('#3af')>=0)?1:0;})()")" "1" "Color card swatch uses the hex as its background-color"

    # uri-list → file card with filename(s) + icon
    chk "$(ctype file)" "file" "a uri-list entry renders as a File card"
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('file'); return ((c._fileText.get_text()||'').indexOf('photo.png')>=0)?1:0;})()")" "1" "File card shows the filename(s)"
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('file'); var S=imports.gi.St; return (c._fileIcon instanceof S.Icon)?1:0;})()")" "1" "File card shows an icon"

    # everything else stays a Text card (incl. a string that merely CONTAINS a URL)
    chk "$(ctype plain)" "text" "a plain string stays a Text card"
    chk "$(ctype noturl)" "text" "a string that only contains a URL stays a Text card (whole-content match)"
    chk "$(ctype img)" "image" "an image entry still renders as an Image card"
    # Text card still uses an St.Label (no markup)
    chk "$(evnum "(function(){var S=imports.gi.St,c=$LU._shelf._cards.get('plain'); return (c._textLabel instanceof S.Label)?1:0;})()")" "1" "Text card body is an St.Label"
    ;;

  008)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    GS="$EXT/schemas/org.gnome.shell.extensions.strata-ui.gschema.xml"
    # --- static asserts: in-UI prefs (openPreferences, no Extensions-app detour) ---
    chk "$([ -f "$EXT/prefs.js" ] && echo y || echo n)" "y" "prefs.js exists (in-UI preferences window)"
    chk "$(grep -qs 'openPreferences' "$EXT/extension.js" && echo y || echo n)" "y" "gear opens prefs via openPreferences()"
    # gschema carries the new layout keys + the reused Strata keys (req #2)
    for k in visor-edge visor-height card-width theme max-history max-text-mb max-image-mb keyboard-shortcut excluded-apps move-activated-to-top; do
      chk "$(grep -qs "name=\"$k\"" "$GS" && echo y || echo n)" "y" "gschema has key: $k"
    done
    # prefs.js wires a row for each layout key + the key reused-from-Strata bundle
    for k in visor-edge visor-height card-width theme max-history excluded-apps keyboard-shortcut; do
      chk "$(grep -qs "'$k'" "$EXT/prefs.js" && echo y || echo n)" "y" "prefs.js wires key: $k"
    done
    # theme is applied by toggling a CSS class (class-toggle), never set_markup / stylesheet swap
    if grep -rqs 'set_markup(' "$EXT/extension.js" "$EXT/ui"; then
      echo "  FAIL: set_markup() found (clipboard/theme must never be markup-parsed)"; fail=1
    else echo "  ok  : no set_markup() (class-toggle theming)"; fi
    chk "$(grep -qs 'strata-theme-' "$EXT/extension.js" && echo y || echo n)" "y" "theme applied via class-toggle (strata-theme-*)"
    chk "$(grep -qs 'strata-theme-' "$EXT/stylesheet.css" && echo y || echo n)" "y" "stylesheet defines theme classes"

    # --- runtime: a gear St.Button in the header that triggers openPreferences (spied) ---
    nested_eval "(function(){ var e=$LU; globalThis._prefsOpened=0; e.openPreferences=function(){ globalThis._prefsOpened++; }; return 1; })()" >/dev/null 2>&1
    chk "$(evnum "(function(){return ($LU._gearButton instanceof imports.gi.St.Button)?1:0;})()")" "1" "header has a gear St.Button"
    # Drive the gear's actual handler (the arrow it's connected to) — deterministic,
    # without depending on St.Button 'clicked' signal arity in the nested shell.
    nested_eval "(function(){ $LU._onGearClicked(); return 1; })()" >/dev/null 2>&1
    sleep 0.3
    chk "$(evnum "globalThis._prefsOpened")" "1" "the gear handler calls openPreferences()"

    # --- runtime: reused keys readable with sane defaults ---
    chk "$(nested_eval "$LU._settings.get_string('theme')" 2>/dev/null | grep -oE 'auto|light|dark' | head -1)" "auto" "theme defaults to auto"
    chk "$(evnum "(function(){return $LU._settings.get_strv('excluded-apps').length>0?1:0;})()")" "1" "excluded-apps ships a populated default"

    # --- runtime: theme class-toggle on the visor ---
    setTheme(){ nested_eval "(function(){$LU._settings.set_string('theme','$1'); return 1;})()" >/dev/null 2>&1; sleep 0.3; }
    hasCls(){ evnum "(function(){return $LU._visor.has_style_class_name('$1')?1:0;})()"; }
    setTheme dark
    chk "$(hasCls strata-theme-dark)" "1" "theme=dark adds the dark class to the visor"
    setTheme light
    chk "$(hasCls strata-theme-light)" "1" "theme=light adds the light class"
    chk "$(hasCls strata-theme-dark)" "0" "theme=light removes the dark class (toggle, not stack)"
    setTheme auto
    chk "$(evnum "(function(){var v=$LU._visor; return (v.has_style_class_name('strata-theme-light')||v.has_style_class_name('strata-theme-dark'))?1:0;})()")" "1" "theme=auto resolves to a concrete light/dark class"

    # --- runtime: live layout updates (open with cards, change keys, observe) ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._lM=[]; for(var i=0;i<8;i++) _lM.push({id:'L'+i,mime_type:'text/plain',content_text:'live card '+i,created_at:i,has_thumbnail:false});
      sh._fetchPage=function(o,l){ return Promise.resolve(_lM.slice(o,o+l)); };
      e._settings.set_string('visor-edge','bottom');
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.8
    nested_eval "(function(){ $LU._settings.set_string('visor-edge','top'); return 1; })()" >/dev/null 2>&1
    sleep 0.3
    chk "$(evnum "(function(){return Math.round($LU._band.get_y());})()")" "0" "visor-edge=top moves the band to the top edge live"
    nested_eval "(function(){ $LU._settings.set_int('visor-height', 420); return 1; })()" >/dev/null 2>&1
    sleep 0.3
    chk "$(evnum "(function(){return Math.round($LU._band.get_height());})()")" "420" "visor-height updates the band height live"
    nested_eval "(function(){ $LU._settings.set_int('card-width', 250); return 1; })()" >/dev/null 2>&1
    sleep 0.3
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('L0'); return c?Math.round(c.get_width()):-1;})()")" "250" "card-width updates existing cards live"
    ;;

  009)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    THUMBS="$XDG_CACHE_HOME/strata/thumbnails"
    # --- static asserts: subscribe to the 3 daemon signals; excluded-apps + focus tracking ---
    chk "$(grep -qs 'signal_subscribe' "$EXT/extension.js" && echo y || echo n)" "y" "subscribes to daemon D-Bus signals (signal_subscribe)"
    for s in ItemAdded ItemDeleted HistoryCleared; do
      chk "$(grep -qs "'$s'" "$EXT/extension.js" && echo y || echo n)" "y" "wires the $s signal"
    done
    chk "$(grep -qs 'onItemAdded' "$EXT/ui/shelf.js" && echo y || echo n)" "y" "shelf prepends on add (onItemAdded)"
    chk "$(grep -qs 'onHistoryCleared' "$EXT/ui/shelf.js" && echo y || echo n)" "y" "shelf empties on clear (onHistoryCleared)"
    chk "$(grep -qs 'excluded-apps' "$EXT/extension.js" && echo y || echo n)" "y" "ItemAdded consults excluded-apps"
    chk "$(grep -qsE 'focus.window|focus_window' "$EXT/extension.js" && echo y || echo n)" "y" "tracks the focused app (focus-window)"

    # --- runtime: open with a few browse cards; stub the daemon-delete used for excluded drops ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._dM=[]; for(var i=0;i<4;i++) _dM.push({id:'h'+i,mime_type:'text/plain',content_text:'history '+i,created_at:i,has_thumbnail:false});
      sh._fetchPage=function(o,l){ return Promise.resolve(_dM.slice(o,o+l)); };
      globalThis._deleted=[];
      e._proxy={ DeleteItemAsync:function(id){ globalThis._deleted.push(id); return Promise.resolve(); } };
      e._currentFocusedApp='firefox';
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.8

    # ItemAdded (non-excluded) prepends a card at the front (newest-first)
    nested_eval "(function(){ $LU._handleItemAdded('new1','text/plain','fresh copy'); return 1; })()" >/dev/null 2>&1
    sleep 0.4
    chk "$(evnum "(function(){return $LU._shelf._cards.has('new1')?1:0;})()")" "1" "ItemAdded prepends a new card"
    chk "$(evnum "(function(){var b=$LU._shelf._cardBox; return (b.get_children()[0]===$LU._shelf._cards.get('new1'))?1:0;})()")" "1" "the new card is at the front (newest-first)"

    # a burst of ItemAdded is coalesced into ONE render flush (debounced)
    nested_eval "(function(){ var e=$LU; e._shelf._addFlushes=0; e._handleItemAdded('b1','text/plain','burst 1'); e._handleItemAdded('b2','text/plain','burst 2'); e._handleItemAdded('b3','text/plain','burst 3'); return 1; })()" >/dev/null 2>&1
    sleep 0.4
    chk "$(evnum "(function(){var s=$LU._shelf; return (s._cards.has('b1')&&s._cards.has('b2')&&s._cards.has('b3'))?1:0;})()")" "1" "every add in a burst lands"
    chk "$(evnum "$LU._shelf._addFlushes")" "1" "the burst is coalesced into a single render flush (debounced)"
    chk "$(evnum "(function(){var b=$LU._shelf._cardBox.get_children(); return (b.indexOf($LU._shelf._cards.get('b3'))<b.indexOf($LU._shelf._cards.get('b1')))?1:0;})()")" "1" "within a burst the newest ends up in front"

    # ItemAdded from an excluded app is dropped from the shelf AND from the daemon
    nested_eval "(function(){ $LU._currentFocusedApp='1password'; $LU._handleItemAdded('secret','text/plain','my password'); return 1; })()" >/dev/null 2>&1
    sleep 0.4
    chk "$(evnum "(function(){return $LU._shelf._cards.has('secret')?1:0;})()")" "0" "ItemAdded from an excluded app never reaches the shelf"
    chk "$(evnum "(function(){return (globalThis._deleted.indexOf('secret')>=0)?1:0;})()")" "1" "the excluded item is deleted from the daemon"

    # ItemDeleted removes the card + unlinks its cached thumbnail
    mkdir -p "$THUMBS"; : > "$THUMBS/h1.png"
    chk "$([ -f "$THUMBS/h1.png" ] && echo y || echo n)" "y" "(setup) a cached thumbnail exists for h1"
    nested_eval "(function(){ $LU._handleItemDeleted('h1'); return 1; })()" >/dev/null 2>&1
    sleep 0.3
    chk "$(evnum "(function(){return $LU._shelf._cards.has('h1')?1:0;})()")" "0" "ItemDeleted removes the card"
    chk "$([ -f "$THUMBS/h1.png" ] && echo y || echo n)" "n" "ItemDeleted unlinks the cached thumbnail"

    # HistoryCleared empties the shelf AND wipes the thumbnail cache directory
    mkdir -p "$THUMBS"; : > "$THUMBS/h0.png"; : > "$THUMBS/h2.png"
    chk "$(ls "$THUMBS" 2>/dev/null | grep -c .)" "2" "(setup) two cached thumbnails exist before clear"
    nested_eval "(function(){ $LU._handleHistoryCleared(); return 1; })()" >/dev/null 2>&1
    sleep 0.3
    chk "$(evnum "(function(){return $LU._shelf._cards.size;})()")" "0" "HistoryCleared empties the shelf"
    chk "$(ls "$THUMBS" 2>/dev/null | grep -c .)" "0" "HistoryCleared wipes the thumbnail cache directory"
    ;;

  010)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- static asserts: the extension is the clipboard capture agent on GNOME ---
    chk "$(grep -qs 'owner-changed'  "$EXT/extension.js" && echo y || echo n)" "y" "watches the Meta selection (owner-changed)"
    chk "$(grep -qs 'transfer_async' "$EXT/extension.js" && echo y || echo n)" "y" "reads the clipboard off-thread (transfer_async)"
    chk "$(grep -qs 'SubmitItem'     "$EXT/extension.js" && echo y || echo n)" "y" "forwards copies to the daemon (SubmitItem)"
    chk "$(grep -qs 'SetConfig'      "$EXT/extension.js" && echo y || echo n)" "y" "pushes size caps to the daemon (SetConfig)"

    # --- runtime: stub SubmitItem, drive the nested session clipboard, assert capture ---
    nested_eval "(function(){
      var e=$LU; globalThis._sub=[];
      e._proxy=e._proxy||{};
      e._proxy.SubmitItemRemote=function(m,b,cb){ globalThis._sub.push([m,(new TextDecoder('utf-8')).decode(b)]); if(cb)cb(); };
      imports.gi.St.Clipboard.get_default().set_text(imports.gi.St.ClipboardType.CLIPBOARD,'hello strata MARK42');
      return 1;
    })()" >/dev/null 2>&1
    sleep 0.6
    chk "$(evnum "(function(){return globalThis._sub.length;})()")" "1" "copying text calls SubmitItem once"
    chk "$(evnum "(function(){return (globalThis._sub[0]&&_sub[0][0].indexOf('text')===0)?1:0;})()")" "1" "submitted mime is text/*"
    chk "$(evnum "(function(){return (globalThis._sub[0]&&_sub[0][1].indexOf('MARK42')>=0)?1:0;})()")" "1" "submitted bytes are the copied text"

    # --- password-manager secrets (x-kde-passwordManagerHint) are skipped ---
    nested_eval "(function(){
      var M=imports.gi.Meta,G=imports.gi.GLib;
      var src=M.SelectionSourceMemory.new('x-kde-passwordManagerHint',G.Bytes.new([115,101,99,114,101,116]));
      global.display.get_selection().set_owner(M.SelectionType.SELECTION_CLIPBOARD,src);
      return 1;
    })()" >/dev/null 2>&1
    sleep 0.6
    chk "$(evnum "(function(){return globalThis._sub.length;})()")" "1" "password-manager secret is NOT submitted"

    # --- payloads over the size cap are dropped ---
    nested_eval "(function(){
      var e=$LU; e._maxTextBytes=4;
      imports.gi.St.Clipboard.get_default().set_text(imports.gi.St.ClipboardType.CLIPBOARD,'way too long to store');
      return 1;
    })()" >/dev/null 2>&1
    sleep 0.6
    chk "$(evnum "(function(){return globalThis._sub.length;})()")" "1" "over-cap payload is dropped (size check)"
    ;;

  011)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- the live bug: Left/Right do NOTHING the user can SEE. card.js already adds
    #     the .strata-card-focused class on key-focus-in and key focus DOES move on a
    #     real Right keystroke — but the user sees no selection, because in the default
    #     (light) theme the two-class `.strata-theme-light .strata-card` rule out-
    #     specifies the single-class `.strata-card-focused` colour, so the highlight is
    #     a silent no-op. The OLD test only checked get_key_focus() (an internal proxy)
    #     and stayed green while the user saw nothing. This case asserts what the USER
    #     SEES: the focused card's COMPUTED theme node differs visibly from an unfocused
    #     card's, the focus class is applied, and the target scrolled into view. ---

    # --- static: .strata-card-focused must be a non-empty rule carrying a VISIBLE
    #     property (outline / border / background) — not an empty/commented no-op ---
    foc="$(awk '/^\.strata-card-focused[[:space:]]*\{/{f=1} f{print} f&&/\}/{exit}' "$EXT/stylesheet.css")"
    chk "$(printf '%s' "$foc" | grep -qsE '(outline|border|background)[^;]*:' && echo y || echo n)" "y" ".strata-card-focused declares a visible property (outline/border/background)"

    # --- runtime: open with browse cards, drive REAL arrow keys through the capture
    #     phase (the search entry must NOT swallow Left/Right) ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._nM=[]; for (var i=0;i<12;i++) _nM.push({id:'n'+i,mime_type:'text/plain',content_text:'nav '+i,created_at:i,has_thumbnail:false});
      sh._fetchPage=function(o,l){ return Promise.resolve(_nM.slice(o,o+l)); };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.8
    focuseq(){ evnum "(function(){return global.stage.get_key_focus()===$1?1:0;})()"; }
    # focus the search box, then Right should ENTER the shelf at the first card
    nested_eval "(function(){global.stage.set_key_focus($LU._searchEntry.get_clutter_text()); return 1;})()" >/dev/null 2>&1
    sleep 0.2
    nested_key Right; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "Right from search focuses the first card"

    # USER-OBSERVABLE: the focused card carries the selection class AND its computed
    # theme node differs VISIBLY from an unfocused card (outline / border-width /
    # border-color / background). This is exactly what goes RED if .strata-card-focused
    # is a visual no-op (the live bug) — get_key_focus moving is NOT enough.
    chk "$(evnum "(function(){return $LU._shelf._cardBox.get_first_child().has_style_class_name('strata-card-focused')?1:0;})()")" "1" "the focused card carries .strata-card-focused"
    visdelta="(function(){var St=imports.gi.St;
      function sig(card){var t=card.get_theme_node();
        var bc=t.get_border_color(St.Side.TOP), bg=t.get_background_color(), oc=t.get_outline_color();
        return [t.get_outline_width(),oc.red,oc.green,oc.blue,oc.alpha,
                t.get_border_width(St.Side.TOP),bc.red,bc.green,bc.blue,bc.alpha,
                bg.red,bg.green,bg.blue,bg.alpha].join(',');}
      var f=$LU._shelf._cardBox.get_first_child();
      var u=$LU._shelf._cardBox.get_children()[3];   // an unfocused, off-to-the-right card
      return (sig(f)!==sig(u))?1:0;})()"
    chk "$(evnum "$visdelta")" "1" "the focused card looks VISIBLY different from an unfocused one (real CSS delta, not just key focus)"

    # WHOLE-CARD FILL (the re-opened live bug): the LIVE highlight was only on the
    # card's LEFT/RIGHT sides — the outline/border got clipped where the card sits
    # flush with the band top/bottom, so the selection never read as the whole card.
    # An outline+border-only style passes the delta above (sides-only signal) while
    # looking broken live. So assert SPECIFICALLY that the focused card's computed
    # BACKGROUND differs from an unfocused card's: a fill that cannot be clipped at the
    # band edges. Removing the background tint (leaving outline/border) must turn THIS
    # red even though the sides-only delta above would still pass. (Comparing the
    # premultiplied colour is enough — a transparent vs. tinted background differs in
    # alpha and/or channels.)
    bgdelta="(function(){
      function bg(card){var c=card.get_theme_node().get_background_color();
        return [c.red,c.green,c.blue,c.alpha].join(',');}
      var f=$LU._shelf._cardBox.get_first_child();
      var u=$LU._shelf._cardBox.get_children()[3];   // an unfocused, off-to-the-right card
      return (bg(f)!==bg(u))?1:0;})()"
    chk "$(evnum "$bgdelta")" "1" "the focused card's BACKGROUND fills the whole card (computed background differs from an unfocused card — not just the outline/border sides)"

    nested_key Right; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_children()[1]")" "1" "Right moves focus to the next card"

    # SCROLL INTO VIEW: navigate several cards to the right (past the viewport edge) and
    # assert the focused card's allocation now sits fully inside the scroll viewport.
    nested_key Right; sleep 0.15; nested_key Right; sleep 0.15; nested_key Right; sleep 0.15
    nested_key Right; sleep 0.15; nested_key Right; sleep 0.15; nested_key Right; sleep 0.3
    chk "$(evnum "(function(){
      var sh=$LU._shelf, adj=sh._scroll.get_hadjustment();
      var c=sh._cardFromActor(global.stage.get_key_focus());
      if(!c||adj.page_size<=0) return 0;
      var b=c.get_allocation_box();
      return (b.x1>=adj.value-1 && b.x2<=adj.value+adj.page_size+1)?1:0;
    })()")" "1" "the navigated-to card is scrolled into view (allocation inside the viewport)"
    chk "$(evnum "(function(){return $LU._shelf._scroll.get_hadjustment().value>0?1:0;})()")" "1" "navigating right actually scrolled the shelf (hadjustment moved off 0)"

    # Left at the LEFT BOUNDARY is a NO-OP (slice 031, supersedes the old 011 "Left off
    # the first card returns to search"): park focus on the first card, then a REAL Left
    # keystroke must KEEP focus on the first card and must NOT jump to the search box.
    # Up / typing (023) are the only routes from a card to search. Drives the real
    # capture path with a real key, not an internal call.
    nested_eval "(function(){global.stage.set_key_focus($LU._shelf._cardBox.get_first_child()); return 1;})()" >/dev/null 2>&1
    sleep 0.2
    nested_key Left; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "Left at the first card stays on the first card (031 boundary no-op)"
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "0" "Left at the first card does NOT return to the search box (031 supersedes 011)"
    ;;

  012)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- paste-back, driven by a REAL synthesized mouse CLICK on the card. ---
    # The old 012 test called sh.activate(card) directly via Eval, so it never went
    # through the visor's button-press-event handler — which is exactly where the
    # live bug lived: that handler read get_transformed_position()'s X (`[bandY]`)
    # instead of Y, so on a bottom-anchored visor a press on any card looked
    # "outside the band" → it hideVisor'd + EVENT_STOP'd, eating the click before the
    # card's `clicked` → activate → copy could run. Clicking with a real virtual
    # POINTER device (launch-nested.sh nested_click) re-creates the user gesture and
    # bites: RED on the buggy handler (nothing is copied), GREEN on the fix.
    #
    # Headless caveat (NOT the bug): under a Mutter modal grab the synthesized
    # virtual-pointer events reach only the grab actor (the visor), never its
    # children, so the card's `clicked` can't fire. We therefore drop the modal grab
    # after _showVisor — the visor stays visible and its button-press-event handler
    # stays wired, so the click still goes THROUGH the handler into the card. Real
    # hardware events under the grab DO reach the card (that is how the user clicks
    # cards); only the synthetic-input routing differs.

    # wait for the daemon proxy to come up (real GetItemContent path, not a stub)
    for i in $(seq 1 40); do
      [ "$(evnum "(function(){return ($LU._proxy&&$LU._proxy.SubmitItemRemote)?1:0;})()")" = "1" ] && break; sleep 0.1
    done
    chk "$(evnum "(function(){return ($LU._proxy&&$LU._proxy.SubmitItemRemote)?1:0;})()")" "1" "daemon D-Bus proxy is ready"

    # seed the (isolated, throwaway) daemon with 4 known text items A<B<C<D by age,
    # so newest-first history is D,C,B,A. Capture is off so paste-back is isolated.
    # Force a bottom-anchored visor: that is the default AND the orientation where
    # the `[bandY]` X-vs-Y bug fires (cards sit at large y, bandY=X≈0).
    nested_eval "(function(){
      var e=$LU, P=e._proxy, G=imports.gi.GLib;
      e._disconnectClipboardMonitor();
      e._settings.set_string('visor-edge','bottom');
      globalThis._setup=0;
      P.ClearHistoryRemote(function(){
        var Ls=['A','B','C','D'];
        (function sub(i){
          if(i>=Ls.length){ globalThis._setup=1; return; }
          var b=new TextEncoder().encode('STRATA012-'+Ls[i]);
          P.SubmitItemRemote('text/plain', b, function(){
            G.timeout_add(G.PRIORITY_DEFAULT,150,function(){ sub(i+1); return false; });
          });
        })(0);
      });
      return 1;
    })()" >/dev/null 2>&1
    for i in $(seq 1 50); do [ "$(evnum "(function(){return globalThis._setup;})()")" = "1" ] && break; sleep 0.1; done

    # poll until the daemon has committed all 4 (SubmitItem is fire-and-forget) and
    # snapshot the newest-first order into globalThis._h
    pollhist(){ for i in $(seq 1 50); do
      nested_eval "(function(){var P=$LU._proxy;globalThis._h=null;P.GetHistoryAsync(0,50).then(function(r){globalThis._h=JSON.parse(r[0]);},function(){globalThis._h=[];});return 1;})()" >/dev/null 2>&1
      sleep 0.15
      [ "$(evnum "(function(){return (globalThis._h&&_h.length>=4)?1:0;})()")" = "1" ] && return 0
    done; return 1; }
    pollhist || { echo "  FAIL: daemon never returned the 4 seeded items"; fail=1; }
    chk "$(evnum "(function(){return (globalThis._h&&_h.length>=4)?1:0;})()")" "1" "real daemon returned the 4 seeded items"
    chk "$(evnum "(function(){return (globalThis._h&&_h[0].content_text==='STRATA012-D')?1:0;})()")" "1" "history is newest-first (top = last submitted, D)"
    chk "$(evnum "(function(){return (globalThis._h&&_h[2].content_text==='STRATA012-B')?1:0;})()")" "1" "the non-top target (index 2) is the older B"

    # open browse so the real history renders into cards, then drop the modal grab
    # (headless synthetic-input routing only — see header).
    nested_eval "(function(){ var e=$LU; if(e._visorVisible)e._hideVisor(); e._showVisor(); if(e._grab){imports.ui.main.popModal(e._grab); e._grab=null;} return 1; })()" >/dev/null 2>&1
    sleep 1.2

    # drop a sentinel on the real clipboard, then synthesize a REAL primary click on
    # the NON-top card B (index 2). The click travels through the visor's
    # button-press handler exactly as a user's click does.
    nested_eval "(function(){
      var e=$LU, sh=e._shelf, St=imports.gi.St;
      globalThis._target=globalThis._h[2];          // STRATA012-B, NOT the top
      sh._lastWrite=null;
      St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD,'SENTINEL-NOPE');
      var card=sh._cards.get(globalThis._target.id);
      globalThis._hadcard=card?1:0;
      return globalThis._hadcard;
    })()" >/dev/null 2>&1
    chk "$(evnum "(function(){return globalThis._hadcard;})()")" "1" "the non-top card B is present to click"

    nested_click "$LU._shelf._cards.get(globalThis._target.id)"
    sleep 0.8

    # the click must have reached the card and copied — NOT been eaten by the visor's
    # dismiss handler. _lastWrite is the proof the activate()/paste-back path ran.
    chk "$(evnum "(function(){return ($LU._shelf._lastWrite&&$LU._shelf._lastWrite.text===globalThis._target.content_text)?1:0;})()")" "1" "a REAL click on card B ran activate→paste-back (shelf._lastWrite is B's content)"

    # end-to-end: the REAL system clipboard now holds the CHOSEN entry, not the top
    nested_eval "(function(){var St=imports.gi.St;globalThis._clip='<unread>';St.Clipboard.get_default().get_text(St.ClipboardType.CLIPBOARD,function(c,t){globalThis._clip=t;});return 1;})()" >/dev/null 2>&1
    sleep 0.4
    chk "$(evnum "(function(){return (globalThis._clip===globalThis._target.content_text)?1:0;})()")" "1" "system clipboard holds the CHOSEN card's content (end-to-end read-back of B)"
    chk "$(evnum "(function(){return (globalThis._clip==='SENTINEL-NOPE')?1:0;})()")" "0" "the click was not eaten (clipboard is no longer the pre-click sentinel)"
    chk "$(evnum "(function(){return (globalThis._clip===globalThis._h[0].content_text)?1:0;})()")" "0" "clipboard is NOT the most-recent entry (D)"
    ;;

  013)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- the live bug: clicking the gear "just closes the visor" and no prefs open.
    #     SAME root cause as 012 — the visor's button-press-event handler read
    #     get_transformed_position()'s X (`[bandY]`) instead of Y, so on a
    #     bottom-anchored visor a press on the gear (large y) looked "outside the
    #     band" → hideVisor + EVENT_STOP, eating the click before the gear's `clicked`
    #     → _onGearClicked → openPreferences could run. The old 013 test called
    #     _onGearClicked() directly, never exercising that handler, so it passed while
    #     the gear was broken. Here we synthesize a REAL click on the gear. ---

    # --- static: _onGearClicked must drop the modal first, then open prefs inside a
    #     try/catch that logs (no more silent "the gear just closed the visor") ---
    gear="$(awk '/_onGearClicked\(\) \{/{f=1} f{print} f&&/^    \}/{exit}' "$EXT/extension.js")"
    chk "$(printf '%s' "$gear" | grep -qs 'openPreferences'             && echo y || echo n)" "y" "_onGearClicked calls openPreferences()"
    chk "$(printf '%s' "$gear" | grep -qs 'try'                         && echo y || echo n)" "y" "_onGearClicked wraps openPreferences in try {"
    chk "$(printf '%s' "$gear" | grep -qs 'catch'                       && echo y || echo n)" "y" "_onGearClicked has a catch for prefs failures"
    chk "$(printf '%s' "$gear" | grep -qs '\[Strata UI\]'              && echo y || echo n)" "y" "_onGearClicked logs the failure with the [Strata UI] prefix"
    # the visor is hidden BEFORE openPreferences (opening must not depend on the grab)
    chk "$(printf '%s' "$gear" | awk '/_hideVisor/{h=NR} /openPreferences/{o=NR} END{print (h&&o&&h<o)?"y":"n"}')" "y" "_hideVisor() runs before openPreferences() (prefs do not depend on the modal)"

    # --- runtime (nested shell): a REAL click on the gear must reach _onGearClicked →
    #     openPreferences (spied), NOT be eaten by the visor's dismiss handler. ---
    # Bottom-anchored visor: the orientation where the `[bandY]` X-vs-Y bug fires.
    # Drop the modal grab after _showVisor (headless synthetic-input routing only,
    # see the 012 header) so the synthesized click reaches the gear; the click still
    # travels THROUGH the visor's button-press handler.
    chk "$(evnum "(function(){return ($LU._gearButton instanceof imports.gi.St.Button)?1:0;})()")" "1" "header has a gear St.Button"
    nested_eval "(function(){
      var e=$LU;
      globalThis._po=0; e.openPreferences=function(){ globalThis._po++; };
      e._settings.set_string('visor-edge','bottom');
      if(e._visorVisible)e._hideVisor();
      e._showVisor();
      if(e._grab){ imports.ui.main.popModal(e._grab); e._grab=null; }
      return 1;
    })()" >/dev/null 2>&1
    sleep 0.8
    nested_click "$LU._gearButton"
    sleep 0.5
    chk "$(evnum "globalThis._po")" "1" "a REAL click on the gear invokes openPreferences() (click not eaten by the dismiss handler)"

    # --- the real test: construct the WHOLE prefs UI (both pages + the shortcut
    #     dialog) against the running GNOME's libadwaita. RED if prefs.js throws under
    #     the live Adw (the feature's suspected Adw incompatibility); GREEN if it
    #     builds clean. Needs a display (the running session); skip-with-note if none. ---
    if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
      pc="$(gjs -m "$HARNESS/prefs-construct.js" "$EXT/schemas" "$EXT/prefs.js" 2>&1)"; pcrc=$?
      chk "$pcrc" "0" "prefs.js builds the full prefs UI under the running libadwaita (exit 0)"
      chk "$(printf '%s' "$pc" | grep -qs 'PREFS-CONSTRUCT-OK' && echo y || echo n)" "y" "prefs construction reports OK (General+Privacy pages + shortcut dialog)"
      [ "$pcrc" = 0 ] || { echo "  prefs-construct output:"; printf '%s\n' "$pc" | sed 's/^/    /'; }
    else
      echo "  note: no display (WAYLAND_DISPLAY/DISPLAY unset) — skipping live prefs-construct"
    fi
    ;;

  014)
    # --- static: install.sh must steer the user to run ONE Strata extension. Two
    #     enabled at once fight over daemon supervision, Ctrl+Alt+C, and capture. ---
    INS="$HARNESS/install.sh"
    chk "$([ -f "$INS" ] && echo y || echo n)" "y" "install.sh exists"
    chk "$(grep -Eqs 'gnome-extensions disable strata@edu4rdshl\.dev'   "$INS" && echo y || echo n)" "y" "install.sh tells you to DISABLE strata@edu4rdshl.dev"
    chk "$(grep -Eqs 'gnome-extensions enable strata-ui@elijahlynn\.net' "$INS" && echo y || echo n)" "y" "install.sh tells you to ENABLE strata-ui@elijahlynn.net"
    chk "$(grep -Eiqs 'log ?out|log out/in|sign out' "$INS" && echo y || echo n)" "y" "install.sh says to log out/in (Wayland) for a brand-new extension"
    chk "$(grep -qs 'Ctrl+Alt+C' "$INS" && echo y || echo n)" "y" "install.sh mentions Ctrl+Alt+C to toggle"
    # ordering: log out/in  ->  disable old  ->  enable new
    ord="$(awk '
      /[Ll]og ?out|[Ss]ign out/      && !lo {lo=NR}
      /disable strata@edu4rdshl\.dev/ && !di {di=NR}
      /enable strata-ui@elijahlynn\.net/ && !en {en=NR}
      END{ print (lo && di && en && lo<di && di<en) ? "y" : "n" }' "$INS")"
    chk "$ord" "y" "ordered: log out/in, THEN disable the old, THEN enable Strata UI"
    # conflict warning when the old extension is currently enabled
    chk "$(grep -qs 'list --enabled' "$INS" && echo y || echo n)" "y" "install.sh inspects the currently-enabled extensions"
    chk "$(grep -Eiqs 'conflict|both|fight' "$INS" && echo y || echo n)" "y" "install.sh warns about the two-extensions conflict"
    ;;

  016)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    CORPUS="$HARNESS/corpus"
    # --- Test Clipboard Corpus: one shared fixture of 3 realistic items of EACH
    #     claimed type, with REAL bytes (real PNGs included). Every other case rolls
    #     its own inline, almost-all-TEXT stub and NO case loads a REAL image — which
    #     is why the image paste-back bug shipped (the binary path was never run).
    #     This case loads the corpus, asserts each type classifies + renders, and
    #     proves real PNG bytes reach the daemon via SubmitItem. ---

    # static: the corpus + loader exist and cover every claimed cardType
    chk "$([ -f "$CORPUS/manifest.json" ] && echo y || echo n)" "y" "corpus manifest exists"
    chk "$([ -f "$CORPUS/loader.js" ] && echo y || echo n)" "y" "corpus loader exists"
    chk "$([ -f "$CORPUS/images/img-png-1.png" ] && echo y || echo n)" "y" "corpus ships REAL PNG image bytes"
    # the first 8 bytes of img-png-1.png must be the PNG magic signature (real bytes, not a stub)
    chk "$(head -c 8 "$CORPUS/images/img-png-1.png" 2>/dev/null | od -An -tu1 | tr -s ' ' | sed 's/^ //')" "137 80 78 71 13 10 26 10" "corpus PNG starts with the \\x89PNG magic signature"
    for ct in text html rtf markdown files links colors images; do
      n=$(ls "$CORPUS/$ct" 2>/dev/null | wc -l)
      chk "$([ "$n" -ge 3 ] && echo y || echo n)" "y" "corpus has >=3 $ct items (got $n)"
    done

    # load the corpus loader into the nested shell (it installs globalThis.StrataCorpus)
    LSRC="$(cat "$CORPUS/loader.js")"
    nested_eval "$LSRC" >/dev/null 2>&1
    chk "$(evnum "(function(){return (globalThis.StrataCorpus&&typeof StrataCorpus.items==='function')?1:0;})()")" "1" "corpus loader installed globalThis.StrataCorpus"
    chk "$(evnum "(function(){return globalThis.StrataCorpus.items('$CORPUS').length;})()")" "28" "loader reads all 28 corpus items off disk"

    # --- classification + rendering: stub the shelf seam with the corpus and open ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._cm = StrataCorpus.stubFetchPage(sh, '$CORPUS');
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 1.0
    ctype(){ nested_eval "(function(){var c=$LU._shelf._cards.get('$1'); return c?c.cardType:'none';})()" 2>/dev/null | grep -oE "(link|color|file|text|image|none)" | head -1; }

    # every text-family item (plain/html/rtf/markdown) classifies to a Text card with an St.Label
    for id in text-1 text-2 text-3 html-1 html-2 html-3 rtf-1 rtf-2 rtf-3 md-1 md-2 md-3; do
      chk "$(ctype $id)" "text" "$id classifies as a Text card"
    done
    chk "$(evnum "(function(){var S=imports.gi.St,c=$LU._shelf._cards.get('html-1'); return (c._textLabel instanceof S.Label)?1:0;})()")" "1" "an html item renders an St.Label (no markup)"

    # all 3 file items (uri-list + gnome-copied-files) classify as File and render a filename
    for id in file-1 file-2 file-3; do chk "$(ctype $id)" "file" "$id classifies as a File card"; done
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('file-1'); return ((c._fileText.get_text()||'').indexOf('photo.png')>=0)?1:0;})()")" "1" "File card shows the parsed filename (photo.png)"
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('file-3'); return ((c._fileText.get_text()||'').indexOf('holiday.jpg')>=0)?1:0;})()")" "1" "gnome-copied-files card skips the op line and shows holiday.jpg"

    # all 3 link items classify as Link and show the hostname subtitle
    for id in link-1 link-2 link-3; do chk "$(ctype $id)" "link" "$id classifies as a Link card"; done
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('link-1'); return (c._subtitle&&c._subtitle.get_text()==='example.com')?1:0;})()")" "1" "Link card subtitle is the hostname (example.com)"
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('link-2'); return (c._subtitle&&c._subtitle.get_text()==='rust-lang.org')?1:0;})()")" "1" "Link card strips www. (rust-lang.org)"

    # all 3 color items classify as Color and the swatch carries the hex
    for id in color-1 color-2 color-3; do chk "$(ctype $id)" "color" "$id classifies as a Color card"; done
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('color-2'); return ((c._swatch.style||'').toLowerCase().indexOf('#1188ff')>=0)?1:0;})()")" "1" "Color card swatch uses the hex as its background-color"

    # all 7 raster items classify as Image and render the thumbnail container (placeholder)
    for id in img-png-1 img-png-2 img-png-3 img-jpeg img-gif img-bmp img-webp; do
      chk "$(ctype $id)" "image" "$id classifies as an Image card"
    done
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('img-png-1'); return (c._thumbContainer&&(c._thumbContainer instanceof imports.gi.St.Widget))?1:0;})()")" "1" "Image card renders a thumbnail container"

    # --- PREFERRED path: push the REAL corpus bytes through the daemon via SubmitItem.
    #     This is the first case to send real raster image bytes down the binary `ay`
    #     path (capture + storage + thumbnailing), the gap that let the image bug ship.
    for i in $(seq 1 40); do
      [ "$(evnum "(function(){return ($LU._proxy&&$LU._proxy.SubmitItemRemote)?1:0;})()")" = "1" ] && break; sleep 0.1
    done
    chk "$(evnum "(function(){return ($LU._proxy&&$LU._proxy.SubmitItemRemote)?1:0;})()")" "1" "daemon D-Bus proxy is ready"
    nested_eval "(function(){
      var e=$LU; e._disconnectClipboardMonitor();   // isolate: no capture racing our submits
      globalThis._seeded=0;
      e._proxy.ClearHistoryRemote(function(){
        StrataCorpus.seedViaSubmit('$CORPUS', e._proxy, function(n){ globalThis._seeded=n; });
      });
      return 1;
    })()" >/dev/null 2>&1
    for i in $(seq 1 80); do [ "$(evnum "(function(){return globalThis._seeded;})()")" = "28" ] && break; sleep 0.1; done
    chk "$(evnum "(function(){return globalThis._seeded;})()")" "28" "loader seeded all 28 corpus items into the daemon via SubmitItem"

    # read history back and prove a REAL image landed (mime image/png, no content_text,
    # has_thumbnail true once the daemon decoded the real PNG) — the binary path ran.
    for i in $(seq 1 60); do
      nested_eval "(function(){var P=$LU._proxy;globalThis._H=null;P.GetHistoryAsync(0,100).then(function(r){globalThis._H=JSON.parse(r[0]);},function(){globalThis._H=[];});return 1;})()" >/dev/null 2>&1
      sleep 0.15
      [ "$(evnum "(function(){return (globalThis._H&&_H.length>=10)?1:0;})()")" = "1" ] && break
    done
    chk "$(evnum "(function(){return (globalThis._H&&_H.length>0)?1:0;})()")" "1" "daemon returned the seeded corpus history"
    chk "$(evnum "(function(){return (globalThis._H&&_H.some(function(m){return m.mime_type==='image/png';}))?1:0;})()")" "1" "a REAL image/png item is stored in the daemon (binary SubmitItem path exercised)"
    chk "$(evnum "(function(){return (globalThis._H&&_H.some(function(m){return m.mime_type==='image/png'&&m.has_thumbnail;}))?1:0;})()")" "1" "the daemon decoded the real PNG and produced a thumbnail"
    # IMAGE PASTE-BACK IS NOT ASSERTED HERE: pushing a real image through full paste-back
    # exposes the known 'No compatible transfer format found' bug — a separate slice.
    # This case asserts image RENDERING + storage only; see claude-progress.txt follow-up.
    ;;

  017)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- BUG (live): the search box placeholder ("Search clipboard…", shown while
    #     the entry is empty) rendered near-WHITE — rgba(255,255,255,0.7), the GNOME
    #     default `StEntry StLabel.hint-text` colour our skins never overrode — so it
    #     was almost invisible on the pale light band and washed-out on the dark one.
    #     Fix: per-theme hint colours in stylesheet.css, readable + good contrast on
    #     the band, distinctly dimmer than typed text. ---
    #
    # USER-OBSERVABLE assert: read the COMPUTED foreground colour of the real hint
    # label (St.Entry.get_hint_actor() → StLabel.hint-text) via its theme node, in
    # BOTH skins. It must equal the intended readable colour, must NOT be the old
    # near-white low-contrast value, and must clear a WCAG contrast bar vs the band.
    NEARWHITE_R=255; NEARWHITE_G=255; NEARWHITE_B=255   # the buggy hint colour

    # Static guard: stylesheet declares a hint-text colour for the search entry that
    # is NOT pure white (so the default near-white theme rule can't leak through).
    hintcss="$(grep -E '\.strata-search[^,{]*StLabel\.hint-text' "$EXT/stylesheet.css" | grep -c .)"
    chk "$([ "${hintcss:-0}" -ge 1 ] && echo y || echo n)" "y" "stylesheet targets .strata-search StLabel.hint-text (overrides the default near-white)"

    # Probe one theme: set it, open the visor, read the hint label's computed fg +
    # the band background, and emit 'R G B A | bR bG bB bA' for the shell to diff.
    hintsig(){   # $1 = theme (dark|light)
      nested_eval "(function(){
        var e=$LU; if(e._visorVisible) e._hideVisor();
        e._settings.set_string('theme','$1');
        e._showVisor();
        var en=e._searchEntry;
        var hint=en.get_hint_actor();
        var hc=hint.get_theme_node().get_foreground_color();
        var bn=e._band.get_theme_node().get_background_color();
        return [hc.red,hc.green,hc.blue,hc.alpha,'|',bn.red,bn.green,bn.blue].join(' ');
      })()" 2>/dev/null | grep -oE '[0-9]+ [0-9]+ [0-9]+ [0-9]+ \| [0-9]+ [0-9]+ [0-9]+'
    }
    # WCAG-ish contrast of an opaque fg over an opaque bg (sRGB relative luminance).
    contrast(){ awk -v fr="$1" -v fg="$2" -v fb="$3" -v br="$4" -v bg="$5" -v bb="$6" 'function lin(c){c/=255; return (c<=0.03928)?c/12.92:((c+0.055)/1.055)^2.4} function lum(r,g,b){return 0.2126*lin(r)+0.7152*lin(g)+0.0722*lin(b)} BEGIN{L1=lum(fr,fg,fb);L2=lum(br,bg,bb); hi=(L1>L2)?L1:L2; lo=(L1>L2)?L2:L1; printf "%.2f", (hi+0.05)/(lo+0.05)}'; }

    # --- DARK skin: hint must be the intended readable grey rgb(170,178,190), not
    #     near-white, and high-contrast on the dark band. ---
    sig="$(hintsig dark)"; sleep 0.3
    read -r hr hg hb ha _bar bbr bbg bbb <<< "$sig"
    chk "$hr $hg $hb" "170 178 190" "dark: hint label computed fg is the intended readable colour rgb(170,178,190)"
    chk "$([ "$hr" = "$NEARWHITE_R" ] && [ "$hg" = "$NEARWHITE_G" ] && [ "$hb" = "$NEARWHITE_B" ] && echo near-white || echo distinct)" "distinct" "dark: hint is NOT the old near-white rgb(255,255,255) value"
    dctr="$(contrast "$hr" "$hg" "$hb" "$bbr" "$bbg" "$bbb")"
    chk "$(awk -v c="$dctr" 'BEGIN{print (c>=4.5)?"ok":"low"}')" "ok" "dark: hint contrast vs band is adequate ($dctr:1 >= 4.5)"

    # --- LIGHT skin: hint must be rgb(90,96,110), not near-white, high-contrast on
    #     the pale band (the worst case — that is where near-white vanished). ---
    sig="$(hintsig light)"; sleep 0.3
    read -r hr hg hb ha _bar bbr bbg bbb <<< "$sig"
    chk "$hr $hg $hb" "90 96 110" "light: hint label computed fg is the intended readable colour rgb(90,96,110)"
    chk "$([ "$hr" = "$NEARWHITE_R" ] && [ "$hg" = "$NEARWHITE_G" ] && [ "$hb" = "$NEARWHITE_B" ] && echo near-white || echo distinct)" "distinct" "light: hint is NOT the old near-white rgb(255,255,255) value"
    lctr="$(contrast "$hr" "$hg" "$hb" "$bbr" "$bbg" "$bbb")"
    chk "$(awk -v c="$lctr" 'BEGIN{print (c>=4.5)?"ok":"low"}')" "ok" "light: hint contrast vs band is adequate ($lctr:1 >= 4.5)"
    ;;
  018)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- the live bug: image cards look very blurry / low-res. applyThumbnail() drops
    #     the daemon's ~200px thumbnail in as a background-image with `background-size:
    #     cover`, which UPSCALES it to fill the ~300px card (worse on a HiDPI/scaled
    #     display) AND crops it to the card's aspect. The crisp UI-only fix renders the
    #     thumbnail with `background-size: contain` (native size, aspect-preserving,
    #     letterboxed) so it is never blurry-upscaled and never cropped. ---

    # --- static: applyThumbnail must NOT use `cover` and MUST use `contain` ---
    appthumb="$(awk '/applyThumbnail\(fileUri\) \{/{f=1} f{print} f&&/^    \}/{exit}' "$EXT/ui/card.js")"
    chk "$(printf '%s' "$appthumb" | grep -qsE 'background-size:[[:space:]]*cover' && echo y || echo n)" "n" "applyThumbnail does NOT upscale with background-size: cover"
    chk "$(printf '%s' "$appthumb" | grep -qsE 'background-size:[[:space:]]*contain' && echo y || echo n)" "y" "applyThumbnail renders crisp with background-size: contain"

    # --- runtime: stub the fetch seams with image metas, open, let a VISIBLE card load
    #     its thumbnail, then read the style ACTUALLY applied to the card (003 unchanged:
    #     placeholder first, on-demand fetch for visible cards only). ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._tM=[]; for (var i=0;i<8;i++) _tM.push({id:'t'+i,mime_type:'image/png',content_text:null,created_at:i,has_thumbnail:true});
      sh._fetchPage=function(o,l){ return Promise.resolve(_tM.slice(o,o+l)); };
      sh._fetchThumbnail=function(id){ return Promise.resolve(new Uint8Array([137,80,78,71,13,10,26,10,0,0,0,13])); };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 1.2
    tstyle(){ nested_eval "(function(){var c=$LU._shelf._cards.get('t0'); return ((c&&c._thumbContainer&&c._thumbContainer.style)||'');})()" 2>/dev/null; }
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('t0'); return (((c._thumbContainer.style)||'').indexOf('background-image')>=0)?1:0;})()")" "1" "visible image card loaded a thumbnail (background-image applied)"
    chk "$(evnum "(function(){var s=(($LU._shelf._cards.get('t0')._thumbContainer.style)||'').replace(/ /g,''); return (s.indexOf('background-size:contain')>=0)?1:0;})()")" "1" "the APPLIED thumbnail style uses background-size: contain (crisp, no upscale)"
    chk "$(evnum "(function(){var s=(($LU._shelf._cards.get('t0')._thumbContainer.style)||'').replace(/ /g,''); return (s.indexOf('background-size:cover')>=0)?1:0;})()")" "0" "the APPLIED thumbnail style does NOT use background-size: cover (no blurry upscaling)"
    ;;
  020)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- the live bug: with a card highlighted (keyboard focus), pressing Delete
    #     does NOTHING — it should DELETE that clipboard item from history. The fix
    #     wires Delete / KP_Delete in the visor key handling to a shelf method that
    #     calls the daemon's DeleteItem(id) for the focused card; the daemon's
    #     ItemDeleted signal then drops the card (shelf.onItemDeleted, from 009) and
    #     unlinks its cached thumbnail. Focus moves to the next card after. Delete in
    #     the SEARCH box must NOT delete (it edits the query text there). This case
    #     drives a REAL Delete keystroke through the capture/key path, asserts the
    #     daemon DeleteItem fired for that card and the card is gone, and asserts the
    #     search-box Delete issues NO DeleteItem. ---

    # --- static: the visor key handling references Delete and a shelf delete seam ---
    chk "$(grep -qsE 'KEY_Delete|KEY_KP_Delete' "$EXT/extension.js" && echo y || echo n)" "y" "visor key handling references the Delete key"
    chk "$(grep -qs 'DeleteItemAsync' "$EXT/ui/shelf.js" && echo y || echo n)" "y" "shelf deletes the focused item via the daemon (DeleteItemAsync)"

    # --- runtime: open with browse cards; stub the proxy's DeleteItemAsync to RECORD
    #     the deleted id AND mirror the real daemon by emitting ItemDeleted (which
    #     shelf.onItemDeleted handles → drops the card). ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._dM=[]; for (var i=0;i<8;i++) _dM.push({id:'d'+i,mime_type:'text/plain',content_text:'del card '+i,created_at:i,has_thumbnail:false});
      sh._fetchPage=function(o,l){ return Promise.resolve(_dM.slice(o,o+l)); };
      globalThis._del=[];
      // Recording delete stub that mirrors the daemon: record the id, then emit the
      // ItemDeleted the real daemon would (the extension's handler drops the card).
      e._proxy={ DeleteItemAsync:function(id){ globalThis._del.push(id); e._handleItemDeleted(id); return Promise.resolve(); } };
      // give the shelf the same stubbed proxy so its DeleteItemAsync call lands here
      sh._proxy=e._proxy;
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.8
    focuseq(){ evnum "(function(){return global.stage.get_key_focus()===$1?1:0;})()"; }

    # focus the SECOND card, then a REAL Delete keystroke must delete THAT card.
    nested_eval "(function(){global.stage.set_key_focus($LU._shelf._cardBox.get_children()[1]); return 1;})()" >/dev/null 2>&1
    sleep 0.2
    chk "$(focuseq "$LU._shelf._cards.get('d1')")" "1" "(setup) the second card (d1) holds key focus"
    nested_key Delete; sleep 0.4
    chk "$(evnum "(function(){return (globalThis._del.indexOf('d1')>=0)?1:0;})()")" "1" "Delete on a focused card calls DeleteItem(id) for THAT card"
    chk "$(evnum "(function(){return globalThis._del.length;})()")" "1" "exactly one DeleteItem is issued for one Delete press"
    chk "$(evnum "(function(){return $LU._shelf._cards.has('d1')?1:0;})()")" "0" "the deleted card is removed from the shelf (ItemDeleted handled)"

    # focus moved to the NEXT card (d2) so repeated Delete walks the shelf
    chk "$(focuseq "$LU._shelf._cards.get('d2')")" "1" "after delete, focus moves to the next card (d2)"

    # a second real Delete deletes the now-focused d2 too (repeat works)
    nested_key Delete; sleep 0.4
    chk "$(evnum "(function(){return (globalThis._del.indexOf('d2')>=0)?1:0;})()")" "1" "a second Delete removes the now-focused card (d2)"
    chk "$(evnum "(function(){return globalThis._del.length;})()")" "2" "two Delete presses issue exactly two DeleteItem calls"

    # Delete with focus in the SEARCH box must NOT delete (it edits the query text)
    nested_eval "(function(){ globalThis._del=[]; global.stage.set_key_focus($LU._searchEntry.get_clutter_text()); return 1; })()" >/dev/null 2>&1
    sleep 0.2
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "1" "(setup) the search box holds key focus"
    nested_key Delete; sleep 0.4
    chk "$(evnum "(function(){return globalThis._del.length;})()")" "0" "Delete with focus in the search box issues NO DeleteItem"
    ;;
  021)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- the live bug: when the Strata UI prefs window is ALREADY open but not
    #     focused (behind another window), clicking the gear again appears to do
    #     nothing. Root cause is in GNOME Shell's OWN extensions D-Bus service
    #     (dbusServices/extensions/extensionsService.js, GNOME 50): OpenExtensionPrefs
    #     throws 'Already showing a prefs dialog' when this._prefsDialog exists, so a
    #     second openPreferences() is rejected and the existing window is never raised.
    #     The prefs window lives in a SEPARATE gjs process, so the extension cannot
    #     present() it directly -- but the Shell side CAN find that window among
    #     Mutter's windows (by the extension display name / gtk-application-id) and
    #     Main.activateWindow() it. The fix adds that raise path to _onGearClicked.
    #
    #     HEADLESS LIMIT (honest): the REAL prefs window cannot be created or observed
    #     from the throwaway nested shell -- it lives in org.gnome.Shell.Extensions, a
    #     different process (the 013 agent proved this). So this case CANNOT assert the
    #     real cross-process raise. What it legitimately CAN assert is MY logic: the
    #     branch and the activate call. It stubs the window-lookup seam to inject a
    #     FAKE existing window, spies Main.activateWindow, and proves the gear RAISES
    #     that window (and does NOT open a second dialog); and with NO existing window
    #     it proves the gear opens exactly one fresh prefs window. The end-to-end real
    #     refocus is LIVE-SMOKE-gated (see claude-progress.txt / tasks.json 021). ---

    # --- static: _onGearClicked must have a raise/present path (Main.activateWindow +
    #     a window-lookup helper matching by name/gtk-application-id), AND keep the
    #     openPreferences fallback + the '[Strata UI] gear clicked' log. ---
    gear="$(awk '/_onGearClicked\(\) \{/{f=1} f{print} f&&/^    \}/{exit}' "$EXT/extension.js")"
    chk "$(printf '%s' "$gear" | grep -qs 'gear clicked'        && echo y || echo n)" "y" "_onGearClicked keeps the '[Strata UI] gear clicked' log"
    chk "$(printf '%s' "$gear" | grep -qs 'openPreferences'     && echo y || echo n)" "y" "_onGearClicked still calls openPreferences() (fresh-open fallback)"
    chk "$(printf '%s' "$gear" | grep -qsE '_findPrefsWindow'   && echo y || echo n)" "y" "_onGearClicked looks up an existing prefs window before opening"
    chk "$(printf '%s' "$gear" | grep -qsE '_presentPrefsWindow' && echo y || echo n)" "y" "_onGearClicked raises the existing window (_presentPrefsWindow) when one is found"
    chk "$(grep -qs 'Main.activateWindow' "$EXT/extension.js" && echo y || echo n)" "y" "the raise path uses Main.activateWindow (raise+focus+workspace)"
    # a window-lookup helper exists and matches the prefs window by name / gtk-application-id
    chk "$(grep -qs '_findPrefsWindow' "$EXT/extension.js" && echo y || echo n)" "y" "a _findPrefsWindow() helper locates the open prefs window"
    chk "$(grep -qsE 'get_gtk_application_id|get_title|metadata\.name|this\.metadata' "$EXT/extension.js" && echo y || echo n)" "y" "_findPrefsWindow matches by the extension display name / gtk-application-id"

    # --- runtime: spy openPreferences + the _presentPrefsWindow raise seam, and stub
    #     the window-lookup seam so the branch is deterministic without the real
    #     cross-process window. (Main.activateWindow is a read-only ESM export and
    #     cannot be reassigned from Eval; _presentPrefsWindow is the spyable seam that
    #     wraps it -- the static check above proves it really calls Main.activateWindow.)
    nested_eval "(function(){
      var e=$LU;
      globalThis._po=0;  e.openPreferences   =function(){ globalThis._po++; };
      globalThis._act=[]; e._presentPrefsWindow=function(w){ globalThis._act.push(w); };
      globalThis._fakeWin=null;   // null => no existing window
      e._findPrefsWindow =function(){ return globalThis._fakeWin; };
      return 1;
    })()" >/dev/null 2>&1

    # CASE A: no existing window -> gear opens exactly one fresh prefs window (open path)
    nested_eval "(function(){ globalThis._po=0; globalThis._act=[]; globalThis._fakeWin=null; $LU._onGearClicked(); return 1; })()" >/dev/null 2>&1
    sleep 0.3
    chk "$(evnum "globalThis._po")"  "1" "no existing window: gear opens exactly one fresh prefs window (openPreferences once)"
    chk "$(evnum "globalThis._act.length")" "0" "no existing window: nothing is raised (no window to refocus)"

    # CASE B: an existing (unfocused) window -> gear RAISES it, does NOT open a second
    nested_eval "(function(){
      globalThis._po=0; globalThis._act=[];
      globalThis._fakeWin={ id:'PREFSWIN', get_title:function(){return 'Strata UI';} };
      $LU._onGearClicked(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.3
    chk "$(evnum "globalThis._act.length")" "1" "existing window: gear raises+refocuses exactly one window"
    chk "$(evnum "(function(){return (globalThis._act[0] && globalThis._act[0].id==='PREFSWIN')?1:0;})()")" "1" "existing window: the RAISED window is the open prefs window"
    chk "$(evnum "globalThis._po")"  "0" "existing window: NO second prefs dialog is opened (the bug: it would no-op; the fix: it raises)"
    ;;
  023)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- the live bug: with a card highlighted (keyboard focus), typing a printable
    #     character is LOST. A card is an St.Button (no text input), so the keystroke
    #     dies on it and the user can't refine the search after arrowing into the
    #     cards. The fix: when a card holds focus, a printable key must FOCUS the
    #     search box and TYPE there (route/re-inject the char so it isn't lost), and
    #     Up must move focus from a card back to the search box. Left/Right still
    #     navigate; Space (Peek) / Enter (copy) / Delete (delete) are unchanged.
    #     This case drives REAL keystrokes through the capture/key path and asserts
    #     the USER-OBSERVABLE result: after a printable key, focus is in the search
    #     box AND that exact char reached the query text (not an internal proxy);
    #     after Up, focus is in the search box; and a printable key on a card neither
    #     copies nor deletes (no card action regressed). ---

    # --- runtime: open with browse cards; stub _fetchPage (browse) and _fetchSearch
    #     (so the typed char's query resolves without a real daemon) and record any
    #     copy (paste-back) / delete so we can prove the printable key did neither. ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._tM=[]; for (var i=0;i<8;i++) _tM.push({id:'t'+i,mime_type:'text/plain',content_text:'type card '+i,created_at:i,has_thumbnail:false});
      sh._fetchPage=function(o,l){ return Promise.resolve(_tM.slice(o,o+l)); };
      sh._fetchSearch=function(q,l){ return Promise.resolve([]); };
      // Spy the copy + delete seams: a printable key on a card must trigger NEITHER.
      globalThis._copied=[]; sh._fetchContent=function(id){ globalThis._copied.push(id); return Promise.resolve(['text/plain', new Uint8Array()]); };
      globalThis._del=[]; e._proxy={ DeleteItemAsync:function(id){ globalThis._del.push(id); return Promise.resolve(); } };
      sh._proxy=e._proxy;
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.8
    focuseq(){ evnum "(function(){return global.stage.get_key_focus()===$1?1:0;})()"; }
    searchtext(){ nested_eval "(function(){return $LU._searchEntry.get_text();})()" 2>/dev/null; }

    # focus the SECOND card, then a REAL printable keystroke ('g') must route to search.
    nested_eval "(function(){global.stage.set_key_focus($LU._shelf._cardBox.get_children()[1]); return 1;})()" >/dev/null 2>&1
    sleep 0.2
    chk "$(focuseq "$LU._shelf._cardBox.get_children()[1]")" "1" "(setup) the second card holds key focus"
    nested_key g; sleep 0.4
    # USER-OBSERVABLE 1: focus is now in the SEARCH box (not the card).
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "1" "a printable key on a focused card moves focus to the search box"
    # USER-OBSERVABLE 2: the typed char actually REACHED the search entry's text.
    chk "$(searchtext | grep -qs 'g' && echo y || echo n)" "y" "the typed character ('g') reached the search box text"
    # USER-OBSERVABLE 3: the char drove the actual query (the search ran with it).
    chk "$(evnum "(function(){return ($LU._shelf._query==='g')?1:0;})()")" "1" "the typed character drove the search query (_query==='g')"
    # REGRESSION (Space/Enter/Delete unchanged): the printable key copied nothing and deleted nothing.
    chk "$(evnum "globalThis._copied.length")" "0" "a printable key on a card copies nothing (Enter/copy unchanged)"
    chk "$(evnum "globalThis._del.length")"    "0" "a printable key on a card deletes nothing (Delete unchanged)"

    # A SECOND printable key while already typing in search appends normally (the
    # route only fires from a card; once in search the entry types as usual).
    nested_key o; sleep 0.4
    chk "$(searchtext | grep -qs 'go' && echo y || echo n)" "y" "a following printable key keeps typing in the search box ('go')"

    # --- Up returns to search: re-enter the shelf, focus a card, then a REAL Up
    #     keystroke must hand focus back to the search box. ---
    nested_eval "(function(){ $LU._shelf.load(); return 1; })()" >/dev/null 2>&1
    sleep 0.6
    nested_eval "(function(){global.stage.set_key_focus($LU._shelf._cardBox.get_children()[2]); return 1;})()" >/dev/null 2>&1
    sleep 0.2
    chk "$(focuseq "$LU._shelf._cardBox.get_children()[2]")" "1" "(setup) a card holds key focus before Up"
    nested_key Up; sleep 0.3
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "1" "Up from a focused card returns focus to the search box"

    # --- REGRESSION (011): Left/Right still NAVIGATE between cards (not routed to search) ---
    nested_eval "(function(){global.stage.set_key_focus($LU._searchEntry.get_clutter_text()); return 1;})()" >/dev/null 2>&1
    sleep 0.2
    nested_key Right; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "Right from search still navigates to the first card (011 not regressed)"
    nested_key Right; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_children()[1]")" "1" "Right still moves between cards (011 not regressed)"

    # --- NEW CONTRACT (031): Left at the first card stays put (no escape to search) ---
    nested_eval "(function(){global.stage.set_key_focus($LU._shelf._cardBox.get_first_child()); return 1;})()" >/dev/null 2>&1
    sleep 0.2
    nested_key Left; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "031: Left at the first card stays on the first card (no jump to search)"
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "0" "031: Left at the first card does not focus the search box"

    # --- NEW CONTRACT (032): Up/Down toggle between the search box and the shelf ---
    nested_key Up; sleep 0.3
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "1" "032: Up from the first card returns to the search box"
    nested_key Down; sleep 0.3
    chk "$(evnum "(function(){return $LU._shelf.hasFocusedCard()?1:0;})()")" "1" "032: Down from the search box re-enters the shelf"

    # --- REGRESSION (020): Delete on a focused card still deletes THAT card ---
    nested_eval "(function(){ globalThis._del=[]; global.stage.set_key_focus($LU._shelf._cardBox.get_children()[1]); return 1; })()" >/dev/null 2>&1
    sleep 0.2
    nested_key Delete; sleep 0.4
    chk "$(evnum "globalThis._del.length")" "1" "Delete on a focused card still deletes it (020 not regressed)"
    ;;

  024)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- the live bug: a focused card shows a DUPLICATE / double line on its
    #     left/right edges. Slice 011 made the whole-card BACKGROUND fill the
    #     primary selection cue (can't be clipped at the band's top/bottom), but
    #     KEPT the earlier `outline: 3px` + thickened `border-width: 2px` on
    #     .strata-card-focused as "secondary edge emphasis". On screen that draws a
    #     SECOND line on the sides (the old sides-only highlight) ON TOP of the
    #     fill, so the card reads as double-lined. The fix drops the redundant
    #     outline + thick border so focus is just the clean whole-card fill: the
    #     focused card's computed outline-width and border-width must REVERT to an
    #     unfocused card's values (no extra edge), while the BACKGROUND fill stays.
    #
    # USER-OBSERVABLE assert: compare a FOCUSED card's computed theme node to an
    # UNFOCUSED card's. Background must still differ (the fill). outline-width and
    # border-width must MATCH the unfocused card (no added outline / no thickened
    # border => no duplicate edge). Re-adding `outline:3px` or `border-width:2px`
    # makes those widths differ from the unfocused card again => RED (the teeth).

    # --- static: .strata-card-focused must NOT declare an outline or a thickened
    #     border-width (the redundant secondary edge). It MUST still declare the
    #     background fill (the single intended highlight). ---
    focrule="$(awk '/^\.strata-card-focused[[:space:]]*\{/{f=1} f{print} f&&/\}/{exit}' "$EXT/stylesheet.css")"
    chk "$(printf '%s' "$focrule" | grep -qsE '^[[:space:]]*outline[^;]*:' && echo y || echo n)" "n" ".strata-card-focused declares NO outline (the redundant edge line is gone)"
    chk "$(printf '%s' "$focrule" | grep -qsE '^[[:space:]]*border-width[^;]*:' && echo y || echo n)" "n" ".strata-card-focused declares NO thickened border-width (no double edge)"
    chk "$(printf '%s' "$focrule" | grep -qsE '^[[:space:]]*background-color[^;]*:' && echo y || echo n)" "y" ".strata-card-focused still declares the whole-card background fill"

    # --- runtime: open with browse cards once, then per theme focus the first card
    #     and read computed theme nodes for BOTH skins (the per-theme focused rules
    #     live in the theme-scoped blocks too). The unfocused reference is an
    #     off-to-the-right card that never received focus.
    #
    # Sequencing note: _showVisor() defers a focus to the SEARCH box one idle tick,
    # which would steal focus off our card (and strip .strata-card-focused). So we
    # open ONCE in setup, switch theme LIVE via settings (008: class-toggle, no
    # reshow), and set the card focus in a SEPARATE Eval AFTER a settle, so the
    # idle search-focus has already fired and our focus sticks. ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._eM=[]; for (var i=0;i<8;i++) _eM.push({id:'e'+i,mime_type:'text/plain',content_text:'edge '+i,created_at:i,has_thumbnail:false});
      sh._fetchPage=function(o,l){ return Promise.resolve(_eM.slice(o,o+l)); };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.9

    # Emit "ow_f ow_u bw_f bw_u bgdiff foccls": outline-width / border-width (TOP)
    # for the Focused vs Unfocused card; bgdiff=1 if backgrounds differ; foccls=1 if
    # the focus class is applied. Read AFTER focus is set + settled.
    edgesig(){   # $1 = theme (dark|light)
      # switch theme live (no reshow) and settle so the idle search-focus has fired
      nested_eval "(function(){ $LU._settings.set_string('theme','$1'); return 1; })()" >/dev/null 2>&1
      sleep 0.4
      # focus the first card in its own Eval, then settle so the class applies
      nested_eval "(function(){ global.stage.set_key_focus($LU._shelf._cardBox.get_first_child()); return 1; })()" >/dev/null 2>&1
      sleep 0.4
      nested_eval "(function(){
        var St=imports.gi.St, sh=$LU._shelf;
        var f=sh._cardBox.get_first_child();
        var u=sh._cardBox.get_children()[3];
        var tf=f.get_theme_node(), tu=u.get_theme_node();
        function bg(t){var c=t.get_background_color(); return [c.red,c.green,c.blue,c.alpha].join(',');}
        var owf=Math.round(tf.get_outline_width()), owu=Math.round(tu.get_outline_width());
        var bwf=Math.round(tf.get_border_width(St.Side.TOP)), bwu=Math.round(tu.get_border_width(St.Side.TOP));
        var bgdiff=(bg(tf)!==bg(tu))?1:0;
        var foccls=f.has_style_class_name('strata-card-focused')?1:0;
        return [owf,owu,bwf,bwu,bgdiff,foccls].join(' ');
      })()" 2>/dev/null | grep -oE '[0-9]+ [0-9]+ [0-9]+ [0-9]+ [0-9]+ [0-9]+' | head -1
    }

    for theme in dark light; do
      sig="$(edgesig "$theme")"
      read -r owf owu bwf bwu bgdiff foccls <<< "$sig"
      chk "${foccls:-0}" "1" "$theme: the focused card carries .strata-card-focused"
      chk "${bgdiff:-0}" "1" "$theme: the focused card's BACKGROUND still fills (computed background differs from an unfocused card)"
      chk "${owf:-x} ${owu:-y}" "0 0" "$theme: focused card adds NO outline (outline-width matches the unfocused card => no duplicate edge line)"
      chk "${bwf:-x}" "${bwu:-y}" "$theme: focused card does NOT thicken the border (border-width matches the unfocused card => no double edge)"
    done
    ;;

  026)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- BUG (live): the hex label below the color swatch (.strata-card-color-hex)
    #     is hard-coded color: rgba(255,255,255,0.85) — near-WHITE — so in the LIGHT
    #     theme it renders as white text on the light-grey card surface and is almost
    #     invisible. The dark theme happens to look fine. Fix: per-theme CSS rules for
    #     .strata-card-color-hex, mirroring slice 017's search-placeholder contrast fix.
    #
    # USER-OBSERVABLE assert: build a color card, read the hex label's COMPUTED
    # foreground color via its theme node in BOTH skins. In the light theme the color
    # must be DARK (not near-white) and must contrast against the light card. In the
    # dark theme it must be LIGHT and contrast against the dark card.
    #
    # Threshold: 4.5:1 (WCAG AA for normal text). The card surface in light theme is
    # roughly #F4F4F6 (the light band with 4% black card overlay). White on that is
    # ~1.0:1 (invisible). A dark color like rgb(30,30,35) gives ~15:1. In the dark
    # theme the card is roughly #1E1E22; rgba(255,255,255,0.85) gives ~10:1.
    # We use band bg as the reference since the card bg may be transparent:
    # light band ~= rgb(246,246,248); dark band ~= rgb(28,28,34). ---

    # Static guard: stylesheet declares per-theme rules for .strata-card-color-hex
    # for BOTH .strata-theme-light and .strata-theme-dark (must have a rule in each).
    lighthex="$(grep -E '\.strata-theme-light[^{]*\.strata-card-color-hex|\.strata-card-color-hex[^{]*\.strata-theme-light' "$EXT/stylesheet.css" | grep -c .)"
    darkhex="$(grep -E '\.strata-theme-dark[^{]*\.strata-card-color-hex|\.strata-card-color-hex[^{]*\.strata-theme-dark' "$EXT/stylesheet.css" | grep -c .)"
    chk "$([ "${lighthex:-0}" -ge 1 ] && echo y || echo n)" "y" "stylesheet has a .strata-theme-light rule for .strata-card-color-hex"
    chk "$([ "${darkhex:-0}" -ge 1 ] && echo y || echo n)" "y" "stylesheet has a .strata-theme-dark rule for .strata-card-color-hex"

    # WCAG-ish contrast ratio (same helper as 017).
    contrast(){ awk -v fr="$1" -v fg="$2" -v fb="$3" -v br="$4" -v bg="$5" -v bb="$6" 'function lin(c){c/=255; return (c<=0.03928)?c/12.92:((c+0.055)/1.055)^2.4} function lum(r,g,b){return 0.2126*lin(r)+0.7152*lin(g)+0.0722*lin(b)} BEGIN{L1=lum(fr,fg,fb);L2=lum(br,bg,bb); hi=(L1>L2)?L1:L2; lo=(L1>L2)?L2:L1; printf "%.2f", (hi+0.05)/(lo+0.05)}'; }
    NEARWHITE_R=255; NEARWHITE_G=255; NEARWHITE_B=255

    # Open once with a color card, then switch themes live (class-toggle, no reshow).
    # This matches the 024 pattern: _showVisor once, then flip the theme setting.
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      sh._fetchPage=function(o,l){
        return Promise.resolve([{id:'hx0',mime_type:'text/plain',content_text:'#00FFCC',created_at:1,has_thumbnail:false}]);
      };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.8

    # Read hex label computed fg color for a given theme (switch live, then read).
    hexsig(){   # $1 = theme (dark|light)
      nested_eval "(function(){ $LU._settings.set_string('theme','$1'); return 1; })()" >/dev/null 2>&1
      sleep 0.4
      nested_eval "(function(){
        var sh=$LU._shelf;
        var card=sh._cards.get('hx0');
        if(!card) return '-1 -1 -1 -1';
        // card > strata-card-body (BoxLayout) > strata-card-color (BoxLayout) > [swatch, hexLabel]
        var body=card.get_child();
        var colorBox=body.get_first_child();
        var hexLabel=colorBox.get_last_child();
        var hc=hexLabel.get_theme_node().get_foreground_color();
        return [hc.red,hc.green,hc.blue,hc.alpha].join(' ');
      })()" 2>/dev/null | grep -oE '[0-9]+ [0-9]+ [0-9]+ [0-9]+' | head -1
    }

    # --- LIGHT skin: hex label must NOT be near-white (the bug) and must contrast
    #     against the light card/band surface (~rgb(246,246,248)). ---
    sig="$(hexsig light)"
    read -r hr hg hb ha <<< "$sig"
    chk "$([ "$hr" = "$NEARWHITE_R" ] && [ "$hg" = "$NEARWHITE_G" ] && [ "$hb" = "$NEARWHITE_B" ] && echo near-white || echo distinct)" "distinct" "light: hex label is NOT the old near-white rgba(255,255,255,…) on the light card"
    lctr="$(contrast "${hr:-255}" "${hg:-255}" "${hb:-255}" 246 246 248)"
    chk "$(awk -v c="${lctr:-0}" 'BEGIN{print (c>=4.5)?"ok":"low"}')" "ok" "light: hex label contrast vs light band is adequate (${lctr:-?}:1 >= 4.5; 4.5 = WCAG AA normal text)"

    # --- DARK skin: hex label must be LIGHT (near-white IS correct here) and must
    #     contrast against the dark band surface (~rgb(28,28,34)). ---
    sig="$(hexsig dark)"
    read -r hr hg hb ha <<< "$sig"
    dctr="$(contrast "${hr:-0}" "${hg:-0}" "${hb:-0}" 28 28 34)"
    chk "$(awk -v c="${dctr:-0}" 'BEGIN{print (c>=4.5)?"ok":"low"}')" "ok" "dark: hex label contrast vs dark band is adequate (${dctr:-?}:1 >= 4.5)"
    ;;

  025)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- the change: the visor used to open with key focus on the SEARCH box
    #     (slice 004 "search-first"). The user wants it to open focused on the
    #     FIRST (most-recent) card, shown with the whole-card focus highlight
    #     (.strata-card-focused), so Left/Right work immediately and typing
    #     refines the search (routed by 023). The first card renders ASYNCHRONOUSLY
    #     (idle_add batches, 002), so the focus must land AFTER the first card
    #     exists — never on the search box. With NO cards (empty history / empty
    #     search) focus falls back to the search box.
    #
    # USER-OBSERVABLE asserts (real open, no internal focus poke):
    #   * non-empty corpus → on open the first card holds key focus AND carries
    #     .strata-card-focused (NOT the search entry);
    #   * empty corpus     → on open focus is the search box;
    #   * compose with 023 → a printable key right after open reaches the search
    #     box; compose with 011 → Left/Right still navigate.

    focuseq(){ evnum "(function(){return global.stage.get_key_focus()===$1?1:0;})()"; }
    searchtext(){ nested_eval "(function(){return $LU._searchEntry.get_text();})()" 2>/dev/null; }

    # --- non-empty corpus: open and assert focus lands on the FIRST card ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._oM=[]; for (var i=0;i<8;i++) _oM.push({id:'o'+i,mime_type:'text/plain',content_text:'open '+i,created_at:i,has_thumbnail:false});
      sh._fetchPage=function(o,l){ return Promise.resolve(_oM.slice(o,o+l)); };
      sh._fetchSearch=function(q,l){ return Promise.resolve([]); };
      // Spy copy/delete: typing right after open must do NEITHER (compose with 023).
      globalThis._copied=[]; sh._fetchContent=function(id){ globalThis._copied.push(id); return Promise.resolve(['text/plain', new Uint8Array()]); };
      globalThis._del=[]; e._proxy={ DeleteItemAsync:function(id){ globalThis._del.push(id); return Promise.resolve(); } };
      sh._proxy=e._proxy;
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 1.0
    # USER-OBSERVABLE 1: the FIRST card holds key focus on open (not the search box).
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "visor opens with key focus on the FIRST card"
    # USER-OBSERVABLE 2: that card carries the whole-card focus highlight class.
    chk "$(evnum "(function(){return $LU._shelf._cardBox.get_first_child().has_style_class_name('strata-card-focused')?1:0;})()")" "1" "the first card carries .strata-card-focused on open"
    # USER-OBSERVABLE 3: the search box is NOT the focused actor.
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "0" "the search box is NOT focused on open (open is card-first, not search-first)"

    # COMPOSE WITH 023: a printable key right after open routes to the search box.
    nested_key g; sleep 0.4
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "1" "typing right after open routes focus to the search box (023 composes)"
    chk "$(searchtext | grep -qs 'g' && echo y || echo n)" "y" "the typed character ('g') reached the search box text (023 composes)"
    chk "$(evnum "globalThis._copied.length")" "0" "typing right after open copies nothing (no card action fired)"
    chk "$(evnum "globalThis._del.length")"    "0" "typing right after open deletes nothing (no card action fired)"

    # COMPOSE WITH 011: reopen (back to browse), then Left/Right still navigate cards.
    nested_eval "(function(){var e=$LU; e._hideVisor(); e._showVisor(); return 1;})()" >/dev/null 2>&1
    sleep 1.0
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "(reopen) focus is on the first card again"
    nested_key Right; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_children()[1]")" "1" "Right still navigates to the next card on open (011 not regressed)"
    nested_key Left; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "Left walks back to the first card (011 not regressed)"
    # NEW CONTRACT (031): a further Left at the first card is a no-op (stays put, never search).
    nested_key Left; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "031: Left at the first card stays put (no escape to search)"
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "0" "031: Left at the first card does not focus the search box"

    # --- empty corpus: open with NO history → focus falls back to the search box ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      e._hideVisor();
      sh._fetchPage=function(o,l){ return Promise.resolve([]); };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 1.0
    chk "$(evnum "$LU._shelf._cardBox.get_n_children()")" "0" "(empty corpus) the shelf has no cards"
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "1" "with NO cards, focus falls back to the search box"
    ;;

  028)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    GS="$EXT/schemas/org.gnome.shell.extensions.strata-ui.gschema.xml"
    # --- Slice 028: gschema default values updated for a better out-of-box experience.
    #     visor-height 360->300, card-width 300->240, max-history 200->2000,
    #     move-activated-to-top stays true (already was true; confirm no regression).
    #
    # USER-OBSERVABLE asserts:
    #   1. The COMPILED schema default for visor-height is 300 (not 360).
    #   2. The COMPILED schema default for card-width is 240 (not 300).
    #   3. The COMPILED schema default for max-history is 2000 (not 200).
    #   4. The COMPILED schema default for move-activated-to-top is true.
    #   5. On a fresh (no-override) profile, the live band height is 300.
    #   6. On a fresh (no-override) profile, a rendered card is 240px wide.
    #
    # The nested shell launches with an isolated temp XDG profile (no gsettings
    # overrides), so get_int/get_boolean read schema defaults, not user overrides.
    # Recompiling the schema before nested_up happens at the top of this script.

    # --- static: verify the XML <default> values in the gschema source ---
    chk "$(grep -A3 'name="visor-height"' "$GS" | grep -oE '<default>[0-9]+</default>' | grep -oE '[0-9]+')" "300" "gschema visor-height <default> is 300"
    chk "$(grep -A3 'name="card-width"' "$GS" | grep -oE '<default>[0-9]+</default>' | grep -oE '[0-9]+')" "240" "gschema card-width <default> is 240"
    chk "$(grep -A3 'name="max-history"' "$GS" | grep -oE '<default>[0-9]+</default>' | grep -oE '[0-9]+')" "2000" "gschema max-history <default> is 2000"
    chk "$(grep -A3 'name="move-activated-to-top"' "$GS" | grep -oE '<default>(true|false)</default>' | grep -oE 'true|false')" "true" "gschema move-activated-to-top <default> is true"

    # --- runtime: on a fresh profile (no overrides), the settings read the compiled defaults ---
    chk "$(evnum "$LU._settings.get_int('visor-height')")" "300" "fresh profile: settings visor-height default is 300"
    chk "$(evnum "$LU._settings.get_int('card-width')")" "240" "fresh profile: settings card-width default is 240"
    chk "$(evnum "$LU._settings.get_int('max-history')")" "2000" "fresh profile: settings max-history default is 2000"
    chk "$(nested_eval "$LU._settings.get_boolean('move-activated-to-top')" 2>/dev/null | grep -oE 'true|false' | head -1)" "true" "fresh profile: settings move-activated-to-top default is true"

    # --- runtime: open the visor and assert the LIVE band height is 300 and cards are 240px wide ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._dM=[]; for (var i=0;i<6;i++) _dM.push({id:'d28'+i,mime_type:'text/plain',content_text:'card '+i,created_at:i,has_thumbnail:false});
      sh._fetchPage=function(o,l){ return Promise.resolve(_dM.slice(o,o+l)); };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.9
    chk "$(evnum "Math.round($LU._band.get_height())")" "300" "live visor band height is 300px (visor-height default applied)"
    chk "$(evnum "(function(){var c=$LU._shelf._cards.get('d280'); return c?Math.round(c.get_width()):-1;})()")" "240" "live card width is 240px (card-width default applied)"
    ;;

  030)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- Slice 030: the Peek IMAGE preview was too dark + slow to show/dismiss.
    #     (a) The dark scrim was the overlay's OWN background-color (rgba 10,10,14,.94)
    #         painted with the image as a mere descendant + the image view carried its
    #         own rgba(0,0,0,.35) tint -> the full-res image rendered very dark. The fix
    #         gives the dim/scrim its OWN actor (.strata-peek-dim) that sits BELOW the
    #         image in child/z-order, so the image paints at FULL brightness on top.
    #     (b) Space showed a dark BLANK during the ~2s GetItemContent fetch. The fix
    #         shows a lightweight loading state immediately instead.
    #     (c) Escape must tear the overlay down synchronously.
    #
    #     NB: headless GL does NOT render a CSS background-image (a solid background
    #     -COLOR paints fine, a file:// background-image does not), so we cannot assert
    #     pixel brightness here. We assert the USER-OBSERVABLE STRUCTURE that makes the
    #     image bright: the dim is a separate actor BELOW the image in child order, the
    #     image actor's effective opacity is full, and neither the image actor nor the
    #     overlay carries a dark background of its own (only the dim, which is behind).

    # --- static: the dim + loading actors exist; the scrim moved off the overlay ---
    chk "$(grep -rqs 'strata-peek-dim' "$EXT/ui/peek.js" && echo y || echo n)" "y" "Peek builds a dedicated dim/scrim actor (strata-peek-dim)"
    chk "$(grep -rqs 'strata-peek-dim' "$EXT/stylesheet.css" && echo y || echo n)" "y" "the dim/scrim background lives on .strata-peek-dim (not the overlay)"
    chk "$(grep -rqs 'strata-peek-loading' "$EXT/ui/peek.js" && echo y || echo n)" "y" "Peek builds a loading-state actor (strata-peek-loading)"

    # --- runtime: stub the shelf seams; image fetch is GATED so we can see the
    #     loading state BEFORE the bytes arrive (the ~2s window) ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._bM=[ {id:'img', mime_type:'image/png', content_text:null, created_at:3, has_thumbnail:true} ];
      sh._fetchPage=function(o,l){ return Promise.resolve(_bM.slice(o,o+l)); };
      sh._fetchThumbnail=function(id){ return Promise.resolve(new Uint8Array([137,80,78,71])); };
      globalThis._gate=null;
      sh._fetchContent=function(id){ return new Promise(function(res){ globalThis._gate=function(){ res(['image/png', new Uint8Array([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,2,0,0,0,2,8,6,0,0,0,114,182,13,36,0,0,0,19,73,68,65,84,120,156,99,249,223,193,240,159,1,8,152,24,160,0,0,39,205,2,141,152,172,202,59,0,0,0,0,73,69,78,68,174,66,96,130])]); }; }); }; // a real 2x2 RGBA PNG (033)
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.7

    # Open the image Peek; the fetch is still pending (mimics the ~2s daemon transfer).
    nested_eval "(function(){ $LU._shelf.peek($LU._shelf._cards.get('img')); return 1; })()" >/dev/null 2>&1
    sleep 0.4

    # (b) PROMPT: overlay is up immediately with a LOADING state, NOT a dark blank.
    #     NB: every assert below returns 1 ONLY for the good state, 0 for missing/bad
    #     (no negative sentinel: evnum strips the sign, so -1 would misparse as 1).
    chk "$(evnum "(function(){return $LU._shelf.isPeeking()?1:0;})()")" "1" "Space opens the Peek immediately (before the image bytes arrive)"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._loading&&p._loading.visible)?1:0;})()")" "1" "a lightweight loading state shows during the fetch (not a dark blank)"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._loading&&p._imageView&&!p._imageView.visible)?1:0;})()")" "1" "the (empty) image view is hidden while the loading state shows"

    # Release the gated fetch -> the full-res image is shown.
    nested_eval "(function(){ if(globalThis._gate) globalThis._gate(); return 1; })()" >/dev/null 2>&1
    sleep 0.5
    chk "$(evnum "(function(){return ($LU._shelf._peek._rendered.kind==='image')?1:0;})()")" "1" "once bytes arrive the image Peek renders the full-resolution image"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._loading&&!p._loading.visible)?1:0;})()")" "1" "the loading state hides once the image is shown"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._imageView&&(p._imageView.get_content() instanceof imports.gi.Clutter.Content))?1:0;})()")" "1" "the decoded image blob is applied to the Peek image view as an in-process content (033)"
    chk "$(evnum "(function(){var s=($LU._shelf._peek._imageView.style)||''; return (s.indexOf('background-image')<0)?1:0;})()")" "1" "the image view carries NO CSS background-image url (033: in-process, not glycin file-load)"

    # (a) BRIGHTNESS / Z-ORDER (the primary teeth): the dim is a SEPARATE actor that
    #     sits BELOW the image in child order, the image is at full opacity, and the
    #     dark backdrop is ONLY on the dim (not on the image actor or the overlay).
    chk "$(evnum "(function(){var p=$LU._shelf._peek; if(!p||!p._dim||!p._overlay) return 0; var k=p._overlay.get_children(); return (k.indexOf(p._dim)===0)?1:0;})()")" "1" "the dim/scrim is the BOTTOM child of the Peek overlay"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; if(!p||!p._dim||!p._imageView||!p._overlay) return 0; var k=p._overlay.get_children(); return (k.indexOf(p._imageView)>k.indexOf(p._dim)&&k.indexOf(p._dim)>=0)?1:0;})()")" "1" "the image actor is ABOVE the dim/scrim in child order (image not covered by the scrim)"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._imageView&&p._imageView.get_paint_opacity()===255)?1:0;})()")" "1" "the image actor's effective (paint) opacity is full"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; if(!p||!p._dim) return 0; try{return (p._dim.get_theme_node().get_background_color().alpha>200)?1:0;}catch(e){return 0;}})()")" "1" "the dim actor carries the dark backdrop (it is the scrim, and it is behind)"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; if(!p||!p._imageView) return 0; try{return (p._imageView.get_theme_node().get_background_color().alpha<30)?1:0;}catch(e){return 0;}})()")" "1" "the image actor has NO dark background of its own (not darkened)"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; if(!p||!p._overlay) return 0; try{return (p._overlay.get_theme_node().get_background_color().alpha<30)?1:0;}catch(e){return 0;}})()")" "1" "the overlay carries NO dark background of its own (scrim moved to the dim)"

    # (c) DISMISS: a REAL Escape tears the overlay down SYNCHRONOUSLY (catches the ~1s
    #     lag). After the keystroke the Peek is gone and the overlay is not mapped.
    nested_key Escape
    sleep 0.3
    chk "$(evnum "(function(){return $LU._shelf.isPeeking()?1:0;})()")" "0" "a real Escape dismisses the Peek"
    chk "$(evnum "(function(){return $LU._shelf._peek._overlay.mapped?1:0;})()")" "0" "Escape unmaps the Peek overlay synchronously (no lingering overlay)"
    chk "$(evnum "(function(){return $LU._visorVisible?1:0;})()")" "1" "Escape closes only the Peek; the visor stays open"

    # leave an image Peek up for the screenshot
    nested_eval "(function(){ $LU._shelf.peek($LU._shelf._cards.get('img')); if(globalThis._gate) globalThis._gate(); return 1; })()" >/dev/null 2>&1
    sleep 0.4
    ;;

  029)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- slice 029 (the hard one): on open the first card must take focus AND KEEP it.
    #     Main.pushModal settles stage key-focus ASYNCHRONOUSLY a tick or more after
    #     _showVisor and can null it (or hand it to the visor / the search entry),
    #     clobbering the card focus we just set (025's live symptom: highlight on, then
    #     off). 025's bounded-ATTEMPT guard fails live because it disconnects after its
    #     FIRST recovery, so a LATER settle pass is never re-asserted. This case
    #     REPRODUCES that deferred settle: a few ticks after open it programmatically
    #     drifts stage key-focus OFF the first card (to null, then to the search entry's
    #     ClutterText, then null, then the entry again) the way the modal does live, then
    #     asserts the first card REGAINS and KEEPS focus + .strata-card-focused. These
    #     are direct set_key_focus pokes (NOT Up/typing) => INVOLUNTARY drift the guard
    #     must survive. RED against the 025 guard (stops re-asserting after the first
    #     drift), GREEN with the time-boxed guard. ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf, G=imports.gi.GLib;
      globalThis._oM=[]; for (var i=0;i<8;i++) _oM.push({id:'F'+i,mime_type:'text/plain',content_text:'focus '+i,created_at:i,has_thumbnail:false});
      sh._fetchPage=function(o,l){ return Promise.resolve(_oM.slice(o,o+l)); };
      e._showVisor();
      globalThis._drifts=0;
      var ct=e._searchEntry.get_clutter_text();
      function drift(target, delayMs){
        G.timeout_add(G.PRIORITY_DEFAULT, delayMs, function(){
          if (e._visorVisible) { global.stage.set_key_focus(target); globalThis._drifts++; }
          return false;
        });
      }
      drift(null, 100); drift(ct, 180); drift(null, 260); drift(ct, 340);
      return 1;
    })()" >/dev/null 2>&1
    sleep 1.4
    focuseq(){ evnum "(function(){return global.stage.get_key_focus()===$1?1:0;})()"; }
    chk "$(evnum "globalThis._drifts")" "4" "(setup) all four deferred focus-drifts fired after open"
    # USER-OBSERVABLE: despite the drifts, the FIRST card holds key focus now…
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "the first card REGAINS key focus after the deferred pushModal settle"
    # …it is NOT left on null/search (the live bug)…
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "0" "focus did NOT drift to the search box (no dehighlight)"
    # …and it carries the whole-card focus highlight (highlights and STAYS).
    chk "$(evnum "(function(){return $LU._shelf._cardBox.get_first_child().has_style_class_name('strata-card-focused')?1:0;})()")" "1" "the first card keeps .strata-card-focused (highlight sticks, no flicker-off)"

    # KEEPS it: the guard window has elapsed, so the steady state must persist after a
    # further settle a tick from now — nothing drifts it, so it stays on the card.
    sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "the first card STILL holds focus after the settle window closes (focus stuck, not flickering)"

    # COMPOSE (029 step 3): after open, one Left/Right navigates adjacent cards with NO
    # skip — the first card is the true cards[0], so adjacent moves are exact.
    nested_key Right; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_children()[1]")" "1" "after open, one Right moves to the 2nd card (no skip)"
    nested_key Left; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "one Left returns to the true first card (no skip)"
    ;;

  031)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- slice 031: Left navigates WITHIN the shelf only. Left while the FIRST card is
    #     focused is a NO-OP — focus stays on the first card and must NOT jump to the
    #     search box (the old 011 boundary behaviour, now superseded). Up / typing (023)
    #     are the ONLY routes from a card to the search box. Drives REAL Left keystrokes
    #     through the capture phase. ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._nM=[]; for (var i=0;i<10;i++) _nM.push({id:'L'+i,mime_type:'text/plain',content_text:'left '+i,created_at:i,has_thumbnail:false});
      sh._fetchPage=function(o,l){ return Promise.resolve(_nM.slice(o,o+l)); };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 1.0
    focuseq(){ evnum "(function(){return global.stage.get_key_focus()===$1?1:0;})()"; }

    # park focus on the SECOND card; one Left moves to the first (normal nav still works).
    nested_eval "(function(){global.stage.set_key_focus($LU._shelf._cardBox.get_children()[1]); return 1;})()" >/dev/null 2>&1
    sleep 0.2
    nested_key Left; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "Left from the second card moves to the first card (normal nav)"

    # NOW a Left FROM the first card is a no-op: focus STAYS on the first card.
    nested_key Left; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "Left at the first card stays on the first card (031 boundary no-op)"
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "0" "Left at the first card does NOT escape to the search box (031)"
    chk "$(evnum "(function(){return $LU._shelf._cardBox.get_first_child().has_style_class_name('strata-card-focused')?1:0;})()")" "1" "the first card keeps the focus highlight after a boundary Left"

    # a second Left is still a no-op (repeatable), never reaching search.
    nested_key Left; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "repeated Left at the boundary keeps the first card focused"
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "0" "repeated Left never reaches the search box"

    # Right/Left still navigate between cards (the boundary change did not break nav).
    nested_key Right; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_children()[1]")" "1" "Right still steps to the next card"
    nested_key Right; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_children()[2]")" "1" "Right still steps card to card"
    ;;

  032)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- slice 032: Down from the search box re-enters the shelf (inverse of 023's Up).
    #     Up/Down toggle between the search box and the shelf. Down re-enters at the
    #     last-focused card if one is tracked, else the first card; an EMPTY shelf makes
    #     Down a no-op. Drives REAL Up/Down keystrokes through the capture phase. ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._nM=[]; for (var i=0;i<10;i++) _nM.push({id:'D'+i,mime_type:'text/plain',content_text:'down '+i,created_at:i,has_thumbnail:false});
      sh._fetchPage=function(o,l){ return Promise.resolve(_nM.slice(o,o+l)); };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 1.0
    focuseq(){ evnum "(function(){return global.stage.get_key_focus()===$1?1:0;})()"; }

    # put focus in the search box, then a REAL Down must re-enter the shelf.
    nested_eval "(function(){global.stage.set_key_focus($LU._searchEntry.get_clutter_text()); return 1;})()" >/dev/null 2>&1
    sleep 0.2
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "1" "(setup) the search box holds key focus"
    nested_key Down; sleep 0.3
    chk "$(evnum "(function(){return $LU._shelf.hasFocusedCard()?1:0;})()")" "1" "Down from the search box moves focus into the shelf (a card is focused)"
    chk "$(evnum "(function(){var c=$LU._shelf._cardFromActor(global.stage.get_key_focus()); return (c&&c.has_style_class_name('strata-card-focused'))?1:0;})()")" "1" "the re-entered card carries .strata-card-focused"

    # Up/Down toggle: Up returns to the search box, Down comes back to the shelf.
    nested_key Up; sleep 0.3
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "1" "Up returns focus to the search box (toggle half 1)"
    nested_key Down; sleep 0.3
    chk "$(evnum "(function(){return $LU._shelf.hasFocusedCard()?1:0;})()")" "1" "Down re-enters the shelf again (toggle half 2)"

    # Down re-enters at the LAST-focused card: navigate to the 3rd card, Up to search,
    # then Down must come back to the 3rd card (not the first card).
    nested_key Right; sleep 0.2; nested_key Right; sleep 0.2   # 1st -> 2nd -> 3rd (index 2)
    chk "$(focuseq "$LU._shelf._cardBox.get_children()[2]")" "1" "(setup) navigated to the third card"
    nested_key Up; sleep 0.3
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "1" "Up from the third card returns to the search box"
    nested_key Down; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_children()[2]")" "1" "Down re-enters at the LAST-focused card (the third), not the first"

    # EMPTY shelf: Down in the search box is a no-op (focus stays in search).
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      e._hideVisor();
      sh._fetchPage=function(o,l){ return Promise.resolve([]); };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 1.0
    chk "$(evnum "$LU._shelf._cardBox.get_n_children()")" "0" "(empty corpus) the shelf has no cards"
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "1" "(empty corpus) focus falls back to the search box on open"
    nested_key Down; sleep 0.3
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "1" "Down on an empty shelf is a no-op (focus stays in the search box)"
    ;;

  027)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- slice 027: entering the shelf from the search box lands on AND highlights the
    #     TRUE first card (cards[0]) with NO skip — even when the search entry holds text
    #     with the cursor MID-STRING (the live repro: the entry's ClutterText eats a
    #     variable number of Left/Right presses for its own cursor, so card #1 looked
    #     skipped, and which card was skipped VARIED with cursor position). We intercept
    #     Left/Right in the capture phase BEFORE the entry, so the FIRST press always
    #     enters at cards[0]. Reconciled with 031: a Left FROM the first card is a no-op
    #     (stays put), never a jump back to search. Drives REAL keystrokes. ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._rM=[]; for (var i=0;i<8;i++) _rM.push({id:'r'+i,mime_type:'text/plain',content_text:'result '+i,created_at:i,has_thumbnail:false});
      sh._fetchPage=function(o,l){ return Promise.resolve(_rM.slice(o,o+l)); };
      sh._fetchSearch=function(q,l){ return Promise.resolve(_rM.slice()); };   // the 8 'result' cards
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 1.0
    focuseq(){ evnum "(function(){return global.stage.get_key_focus()===$1?1:0;})()"; }

    # Put focus in the search box, type text, park the cursor MID-STRING — the exact
    # condition under which the entry's ClutterText would eat a Right for its cursor.
    nested_eval "(function(){
      var e=$LU, ct=e._searchEntry.get_clutter_text();
      if (e._teardownFocusGuard) e._teardownFocusGuard();
      global.stage.set_key_focus(ct);
      e._searchEntry.set_text('result');
      ct.set_cursor_position(3);   // cursor in the middle of the text, not at the end
      return 1;
    })()" >/dev/null 2>&1
    sleep 0.5
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "1" "(setup) focus is in the search box with a mid-string cursor"
    chk "$(evnum "(function(){return $LU._shelf._cardBox.get_n_children();})()")" "8" "(setup) the search shows 8 result cards"

    # THE REPRO: a SINGLE Right must enter the shelf at the TRUE first card (cards[0]) —
    # not eaten by the entry's cursor, not skipped to card #2.
    nested_key Right; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "a single Right from search-with-text enters at the TRUE first card (cards[0], no eaten arrow)"
    chk "$(evnum "(function(){return $LU._shelf._cardBox.get_first_child().has_style_class_name('strata-card-focused')?1:0;})()")" "1" "the true first card carries .strata-card-focused (not skipped)"

    # arrow nav across cards never skips: Right walks 0 -> 1 -> 2 exactly.
    nested_key Right; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_children()[1]")" "1" "Right steps to the 2nd card (no skip)"
    nested_key Right; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_children()[2]")" "1" "Right steps to the 3rd card (no skip)"

    # from the 3rd card, Left walks back 2 -> 1 -> 0 exactly; a further Left at the first
    # card is the 031 no-op (stays put), never a jump back to search.
    nested_key Left; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_children()[1]")" "1" "Left steps back to the 2nd card (no skip)"
    nested_key Left; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "Left reaches the TRUE first card and highlights it (not skipped)"
    nested_key Left; sleep 0.3
    chk "$(focuseq "$LU._shelf._cardBox.get_first_child()")" "1" "Left at the first card stays put (031: no jump to search)"
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "0" "arrow nav never lands focus back in the search box via Left (031)"

    # ALSO via Down (032): from the search box, Down re-enters the shelf at a real card.
    nested_eval "(function(){global.stage.set_key_focus($LU._searchEntry.get_clutter_text()); return 1;})()" >/dev/null 2>&1
    sleep 0.2
    nested_key Down; sleep 0.3
    chk "$(evnum "(function(){return $LU._shelf.hasFocusedCard()?1:0;})()")" "1" "Down from search also re-enters the shelf at a real card (032, no skip)"
    ;;

  033)
    LU="Main.extensionManager.lookup('$UUID').stateObj"
    # --- Slice 033: the Peek IMAGE was BLACK 'Loading…' for ~2s then slow (~1s) to
    #     dismiss. Root cause: peek.js wrote the bytes to a TEMP FILE and showed them
    #     via CSS background-image: url("file://…"), which on this system goes through
    #     St.TextureCache's file-loader + glycin sandbox (cold bwrap spin-up + temp-file
    #     I/O ≈ the 2s; the same heavy GL texture is slow to tear down ≈ the 1s Escape).
    #     The fix decodes the in-memory blob IN-PROCESS (GdkPixbuf.new_from_stream over a
    #     Gio.MemoryInputStream → St.ImageContent set on the image actor) — NO temp file,
    #     NO file:// CSS, NO St.TextureCache; CACHES the decoded content per id and can
    #     PRE-FETCH the focused card in the background; dismiss just drops the content
    #     reference (cheap, no glycin/St.TextureCache teardown).
    #
    #     NB (headless): we assert the USER-OBSERVABLE STRUCTURE — the image actor is
    #     backed by an in-process Clutter.Content (St.ImageContent), NOT a CSS
    #     background-image url; the path writes no temp file / no file://; a gated fetch
    #     yields a present content; the cache + prefetch skip re-fetching; Escape unmaps
    #     synchronously AND releases the displayed content. The wall-clock instant-ness is
    #     only live-verifiable (see claude-progress.txt timing numbers).

    # --- static: in-process decode path, no temp-file / file:// / CSS background-image ---
    if grep -qs 'background-image' "$EXT/ui/peek.js"; then
      echo "  FAIL: peek.js still uses a CSS background-image (glycin/St.TextureCache path)"; fail=1
    else echo "  ok  : peek.js uses NO CSS background-image (no St.TextureCache image path)"; fi
    if grep -qs 'file_set_contents' "$EXT/ui/peek.js"; then
      echo "  FAIL: peek.js still writes a temp file for the image"; fail=1
    else echo "  ok  : peek.js writes NO temp file for the image"; fi
    if grep -qs 'file://' "$EXT/ui/peek.js"; then
      echo "  FAIL: peek.js still references a file:// url"; fail=1
    else echo "  ok  : peek.js references NO file:// url"; fi
    chk "$(grep -qs 'ImageContent'   "$EXT/ui/peek.js" && echo y || echo n)" "y" "Peek decodes to an in-process St.ImageContent"
    chk "$(grep -qs 'new_from_stream' "$EXT/ui/peek.js" && echo y || echo n)" "y" "Peek decodes the in-memory blob via GdkPixbuf.new_from_stream"
    chk "$(grep -qs 'GdkPixbuf'      "$EXT/ui/peek.js" && echo y || echo n)" "y" "Peek imports GdkPixbuf (in-process decode, not glycin file-load)"
    chk "$(grep -qs 'prefetch'       "$EXT/ui/peek.js" && echo y || echo n)" "y" "Peek can pre-fetch+decode a card's image in the background"

    # --- runtime: stub the seams; img1's content fetch is GATED so we can observe the
    #     loading window BEFORE the bytes arrive; the bytes are a REAL (decodable) PNG so
    #     the in-process decode genuinely produces a content. _fcN counts fetches per id
    #     (proves the cache/prefetch skip re-fetching). ---
    nested_eval "(function(){
      var e=$LU, sh=e._shelf;
      globalThis._bM=[
        {id:'img1', mime_type:'image/png', content_text:null, created_at:3, has_thumbnail:true},
        {id:'img2', mime_type:'image/png', content_text:null, created_at:2, has_thumbnail:true}
      ];
      sh._fetchPage=function(o,l){ return Promise.resolve(_bM.slice(o,o+l)); };
      sh._fetchThumbnail=function(id){ return Promise.resolve(new Uint8Array([137,80,78,71])); };
      // a real 2x2 RGBA PNG (valid bytes → in-process GdkPixbuf decode succeeds)
      globalThis._PNG=new Uint8Array([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,2,0,0,0,2,8,6,0,0,0,114,182,13,36,0,0,0,19,73,68,65,84,120,156,99,249,223,193,240,159,1,8,152,24,160,0,0,39,205,2,141,152,172,202,59,0,0,0,0,73,69,78,68,174,66,96,130]);
      globalThis._fcN={}; globalThis._gate=null;
      sh._fetchContent=function(id){
        _fcN[id]=(_fcN[id]||0)+1;
        if (id==='img1') return new Promise(function(res){ globalThis._gate=function(){ res(['image/png', globalThis._PNG]); }; });
        return Promise.resolve(['image/png', globalThis._PNG]);
      };
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.7

    # Open img1; its fetch is still pending (mimics the cold decode/transfer window).
    nested_eval "(function(){ $LU._shelf.peek($LU._shelf._cards.get('img1')); return 1; })()" >/dev/null 2>&1
    sleep 0.4
    chk "$(evnum "(function(){return $LU._shelf.isPeeking()?1:0;})()")" "1" "Space opens the Peek immediately (before the image bytes arrive)"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._loading&&p._loading.visible)?1:0;})()")" "1" "a lightweight loading state shows during the fetch (not a black blank)"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._imageView&&!p._imageView.visible)?1:0;})()")" "1" "the image view is hidden while the loading state shows"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._imageView&&p._imageView.get_content()===null)?1:0;})()")" "1" "no image content is set yet (the gated fetch is still pending)"

    # Release the gated fetch -> the bytes are decoded IN-PROCESS and a content appears.
    nested_eval "(function(){ if(globalThis._gate) globalThis._gate(); return 1; })()" >/dev/null 2>&1
    sleep 0.5
    chk "$(evnum "(function(){return ($LU._shelf._peek._rendered.kind==='image')?1:0;})()")" "1" "once bytes arrive the image Peek renders the full-resolution image"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._loading&&!p._loading.visible)?1:0;})()")" "1" "the loading state hides once the image is shown"
    # THE PRIMARY 033 TEETH: the image actor is backed by an in-process Clutter.Content
    # (St.ImageContent), NOT a CSS background-image url.
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._imageView&&(p._imageView.get_content() instanceof imports.gi.Clutter.Content))?1:0;})()")" "1" "the image actor is backed by an in-process Clutter.Content (St.ImageContent), not a CSS url"
    chk "$(evnum "(function(){var s=($LU._shelf._peek._imageView.style)||''; return (s.indexOf('background-image')<0)?1:0;})()")" "1" "the live image actor's style carries NO background-image url"
    chk "$(evnum "(function(){var s=($LU._shelf._peek._imageView.style)||''; return (s.indexOf('file://')<0)?1:0;})()")" "1" "the live image actor's style carries NO file:// url"

    # 030 invariants stay GREEN: dim is the bottom child, the image is ABOVE it, full opacity.
    chk "$(evnum "(function(){var p=$LU._shelf._peek; if(!p||!p._dim||!p._overlay) return 0; var k=p._overlay.get_children(); return (k.indexOf(p._dim)===0)?1:0;})()")" "1" "the dim/scrim is the BOTTOM child of the Peek overlay (030)"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; if(!p||!p._dim||!p._imageView||!p._overlay) return 0; var k=p._overlay.get_children(); return (k.indexOf(p._imageView)>k.indexOf(p._dim)&&k.indexOf(p._dim)>=0)?1:0;})()")" "1" "the image actor is ABOVE the dim/scrim in child order (030)"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._imageView&&p._imageView.get_paint_opacity()===255)?1:0;})()")" "1" "the image actor's effective (paint) opacity is full (030: bright, not dimmed)"

    # CACHE: a decoded content is cached per id; re-peeking img1 is a cache HIT — NO new
    # fetch (proves the cache makes a re-peek instant, not another 2s decode).
    chk "$(evnum "(function(){return (globalThis._fcN['img1']===1)?1:0;})()")" "1" "(setup) img1 fetched exactly once for the first peek"
    nested_eval "(function(){ $LU._shelf.closePeek(); return 1; })()" >/dev/null 2>&1
    sleep 0.2
    nested_eval "(function(){ $LU._shelf.peek($LU._shelf._cards.get('img1')); return 1; })()" >/dev/null 2>&1
    sleep 0.3
    chk "$(evnum "(function(){return (globalThis._fcN['img1']===1)?1:0;})()")" "1" "re-peeking img1 is a cache HIT — no second GetItemContent (instant re-peek)"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._imageView&&(p._imageView.get_content() instanceof imports.gi.Clutter.Content))?1:0;})()")" "1" "the cached content is shown on re-peek (no re-decode)"
    nested_eval "(function(){ $LU._shelf.closePeek(); return 1; })()" >/dev/null 2>&1
    sleep 0.2

    # PRE-FETCH: warm img2 in the background (decode without showing); a later peek of
    # img2 is then a cache hit — the focused-card image is ready BEFORE Space.
    nested_eval "(function(){ $LU._shelf._peek.prefetch($LU._shelf._cards.get('img2')); return 1; })()" >/dev/null 2>&1
    sleep 0.4
    chk "$(evnum "(function(){return (globalThis._fcN['img2']===1)?1:0;})()")" "1" "prefetch fetches+decodes img2 in the background (cache warmed)"
    chk "$(evnum "(function(){return $LU._shelf.isPeeking()?1:0;})()")" "0" "prefetch does NOT open the Peek (background warm only)"
    nested_eval "(function(){ $LU._shelf.peek($LU._shelf._cards.get('img2')); return 1; })()" >/dev/null 2>&1
    sleep 0.3
    chk "$(evnum "(function(){return (globalThis._fcN['img2']===1)?1:0;})()")" "1" "peeking img2 after prefetch is a cache HIT (no extra fetch — instant)"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._imageView&&(p._imageView.get_content() instanceof imports.gi.Clutter.Content))?1:0;})()")" "1" "the prefetched content is shown instantly on peek"

    # DISMISS: a REAL Escape tears the overlay down SYNCHRONOUSLY and releases the
    # displayed content cheaply (no glycin/St.TextureCache teardown == no ~1s lag).
    nested_key Escape
    sleep 0.3
    chk "$(evnum "(function(){return $LU._shelf.isPeeking()?1:0;})()")" "0" "a real Escape dismisses the Peek"
    chk "$(evnum "(function(){return $LU._shelf._peek._overlay.mapped?1:0;})()")" "0" "Escape unmaps the Peek overlay synchronously (no lingering overlay)"
    chk "$(evnum "(function(){var p=$LU._shelf._peek; return (p&&p._imageView&&p._imageView.get_content()===null)?1:0;})()")" "1" "Escape releases the displayed image content (cheap teardown, no glycin)"
    chk "$(evnum "(function(){return $LU._visorVisible?1:0;})()")" "1" "Escape closes only the Peek; the visor stays open"

    # leave an image Peek up for the screenshot (cache hit → instant)
    nested_eval "(function(){ $LU._shelf.peek($LU._shelf._cards.get('img1')); return 1; })()" >/dev/null 2>&1
    sleep 0.3
    ;;

  *) echo "  note: no feature-specific checks for $ID (generic only)";;
esac

nested_screenshot "$SHOT" && echo "  shot: $SHOT"
if [ "$fail" = 0 ]; then echo "verify $ID: PASS"; exit 0; else echo "verify $ID: FAIL"; exit 1; fi
