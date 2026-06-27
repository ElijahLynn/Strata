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

  *) echo "  note: no feature-specific checks for $ID (generic only)";;
esac

nested_screenshot "$SHOT" && echo "  shot: $SHOT"
if [ "$fail" = 0 ]; then echo "verify $ID: PASS"; exit 0; else echo "verify $ID: FAIL"; exit 1; fi
