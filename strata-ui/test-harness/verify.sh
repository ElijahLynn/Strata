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
      // Record that the search box receives focus on open (headless stage focus
      // decays over time, so we latch the key-focus-in rather than poll it late).
      globalThis._foc=0;
      e._searchEntry.get_clutter_text().connect('key-focus-in', function(){ globalThis._foc++; });
      e._showVisor(); return 1;
    })()" >/dev/null 2>&1
    sleep 0.6
    chk "$(evnum "(function(){return (globalThis._foc>=1)?1:0;})()")" "1" "search box is focused on open (search-first)"
    chk "$(evnum "$LU._shelf._cardBox.get_n_children()")" "10" "opens in browse view (recent history)"

    # type 'foo' -> debounced SearchHistory('foo', max-history) -> 45 results via idle_add batches
    nested_eval "(function(){ $LU._shelf.renderStats.batches=0; $LU._searchEntry.set_text('foo'); return 1; })()" >/dev/null 2>&1
    sleep 0.5
    chk "$(evnum "globalThis._sq.length")" "1" "typing issues one SearchHistory query (debounced)"
    chk "$(evnum "(function(){return (globalThis._sq[0][0]==='foo')?1:0;})()")" "1" "query string is passed to SearchHistory"
    chk "$(evnum "globalThis._sq[0][1]")" "200" "SearchHistory limit is max-history (200)"
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
        if (id==='img')  return Promise.resolve(['image/png', new Uint8Array([137,80,78,71,13,10,26,10,0,0,0,13])]);
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
    chk "$(evnum "(function(){return ((($LU._shelf._peek._imageView.style)||'').indexOf('background-image')>=0)?1:0;})()")" "1" "the decoded image blob is applied to the Peek image view"
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

    # Left walks back: park focus on the first card, then a REAL Left keystroke steps
    # off the front and the capture handler (moveFocus(-1)===false) hands focus back to
    # the search box. Drives the real capture path with a real key, not an internal call.
    nested_eval "(function(){global.stage.set_key_focus($LU._shelf._cardBox.get_first_child()); return 1;})()" >/dev/null 2>&1
    sleep 0.2
    nested_key Left; sleep 0.3
    chk "$(focuseq "$LU._searchEntry.get_clutter_text()")" "1" "Left off the first card returns focus to search"
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

  *) echo "  note: no feature-specific checks for $ID (generic only)";;
esac

nested_screenshot "$SHOT" && echo "  shot: $SHOT"
if [ "$fail" = 0 ]; then echo "verify $ID: PASS"; exit 0; else echo "verify $ID: FAIL"; exit 1; fi
