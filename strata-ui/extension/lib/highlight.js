/* highlight.js — a small, dependency-free syntax highlighter used ONLY by Peek.
 *
 * ADR-0007: syntax highlighting happens only on the Peek path — one entry, on
 * user action (Space) — never on the shelf, because running a highlighter for
 * every visible Card is exactly the main-loop work the architecture forbids.
 *
 * highlight.js (the npm lib) is the canonical reference, but it ships as a
 * DOM/UMD bundle that emits an HTML string. In GJS we render with St.Label only
 * and must NEVER parse clipboard content as Pango markup
 * (reference/architecture-constraints.md). So instead of HTML we emit *typed
 * tokens that tile the source exactly*; Peek maps token types to colours and
 * applies them as Pango foreground attributes over byte ranges — the content is
 * set as plain text and coloured out-of-band, never markup-parsed. Swapping in
 * real highlight.js later means only re-implementing highlight() to translate
 * hljs's output into this same {text,type} run list.
 */

// A broad union of keywords across the languages Strata users tend to copy
// (C-likes, JS/TS, Python, Rust, Go, shell, …). Auto-detect is one entry, so a
// generous superset is fine — a stray keyword in prose can't pass the isCode gate.
const KEYWORDS = new Set([
    'if', 'else', 'elif', 'for', 'while', 'do', 'switch', 'case', 'default',
    'break', 'continue', 'return', 'goto', 'try', 'catch', 'finally', 'throw',
    'throws', 'yield', 'await', 'async', 'function', 'func', 'fn', 'def', 'lambda',
    'class', 'struct', 'enum', 'interface', 'trait', 'impl', 'extends', 'implements',
    'new', 'delete', 'this', 'self', 'super', 'import', 'export', 'from', 'as',
    'package', 'module', 'namespace', 'using', 'include', 'require', 'const', 'let',
    'var', 'val', 'static', 'final', 'public', 'private', 'protected', 'abstract',
    'virtual', 'override', 'void', 'int', 'long', 'short', 'char', 'float', 'double',
    'bool', 'boolean', 'byte', 'unsigned', 'signed', 'typedef', 'union', 'sizeof',
    'typeof', 'instanceof', 'and', 'or', 'not', 'in', 'is', 'of', 'match', 'where',
    'mut', 'pub', 'use', 'mod', 'defer', 'select', 'chan', 'range', 'echo', 'then',
    'fi', 'esac', 'done', 'local', 'with',
]);

// Ordered token rules; the first that matches at the cursor wins. All sticky (y)
// so each only matches starting AT the cursor; together they tile the whole input.
const RULES = [
    ['comment', /\/\*[\s\S]*?\*\/|\/\/[^\n]*|#[^\n]*|--[^\n]*/y],
    ['string', /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`/y],
    ['number', /0[xX][0-9a-fA-F]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?/y],
    ['name', /[A-Za-z_$][A-Za-z0-9_$]*/y],
    ['op', /[{}()[\].;,:?+\-*/%=<>!&|^~@]+/y],
    ['ws', /\s+/y],
];

// Strong structural signals: even with no keyword, these mean "code".
const STRUCTURAL = /[{};]|=>|::|->|#include|println!|\bdef\s+\w+\s*\(/;
// Lighter "this looks like source" signal (brackets / assignment / comparison).
const SYMBOLS = /[(){}[\]=<>]/;

/** Tokenise `code` into a run list that tiles it exactly. Returns
 *  {tokens:[{text,type}], isCode, language|null}. type ∈
 *  comment|string|number|keyword|name|op|ws|other. */
export function highlight(code) {
    const tokens = [];
    let pos = 0;
    let kw = 0;
    const N = code.length;
    while (pos < N) {
        let text = null;
        let type = 'other';
        for (const [t, re] of RULES) {
            re.lastIndex = pos;
            const m = re.exec(code);
            if (m && m.index === pos && m[0].length > 0) {
                text = m[0];
                type = t;
                break;
            }
        }
        if (text === null) { text = code[pos]; type = 'other'; } // any stray char
        if (type === 'name' && KEYWORDS.has(text)) { type = 'keyword'; kw++; }
        tokens.push({ text, type });
        pos += text.length;
    }
    // Structural punctuation is the reliable code signal; keywords alone misfire
    // on prose (English is full of "if", "in", "for", "with"…), so they only
    // count as a tie-breaker alongside source-like symbols.
    const isCode = STRUCTURAL.test(code) || (kw >= 2 && SYMBOLS.test(code));
    return { tokens, isCode, language: isCode ? detectLanguage(code) : null };
}

/** Coarse language guess — enough for a Peek subtitle; not load-bearing. */
function detectLanguage(code) {
    if (/\bfunction\b|=>|console\.|\bconst\b|\blet\b/.test(code)) return 'javascript';
    if (/\bdef\b|\bimport\b|\bprint\(|\belif\b/.test(code)) return 'python';
    if (/#include|\bprintf\b|\bint\s+main\b/.test(code)) return 'c';
    if (/\bfn\b|println!|\blet\s+mut\b/.test(code)) return 'rust';
    if (/\bfunc\b|\bpackage\b|:=/.test(code)) return 'go';
    if (/\becho\b|\bfi\b|\bdone\b|^#!.*sh/m.test(code)) return 'shell';
    return 'code';
}
