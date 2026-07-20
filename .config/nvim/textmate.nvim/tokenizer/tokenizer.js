#!/usr/bin/env node
// Long-lived tokenizer process driven by Neovim over stdin/stdout.
//
// A VSCode color theme is loaded into the registry so token colors are resolved
// exactly as VSCode resolves them (scope-selector matching, specificity, parent
// scopes). tokenizeLine2 yields binary metadata encoding a color-map index and
// a font style; both are forwarded to Neovim, which builds highlight groups
// from the color map.
//
// Tokenization is incremental: per-buffer rule-stack state is cached so an edit
// only re-tokenizes from the first changed line until the grammar state
// re-converges with the previous pass. The response therefore reports a single
// contiguous changed line range rather than the whole buffer.
//
// Protocol: newline-delimited JSON, one message per line.
//   Request:  { "id": <n>, "type": "tokenize", "bufId": <n>, "scopeName": "source.ts", "lines": ["..."] }
//   Response: { "id": <n>, "type": "ok", "start": <n>, "stop": <n>, "lineCount": <n>,
//               "tokens": [ [ {"s":0,"e":3,"c":10,"y":1} ], ... ] }
//             tokens cover the changed line range [start, stop); lines outside it
//             are unchanged and reuse the client's existing highlights.
//             s/e = byte offsets, c = color-map index, y = font-style bits
//             (1=italic, 2=bold, 4=underline, 8=strikethrough)
//   Drop:     { "type": "drop", "bufId": <n> }  (frees cached buffer state; no reply)
//   Ready:    { "type": "ready", "colorMap": ["#......", ...] }
//
// argv[2] must be a path to a VSCode theme JSON file (with a `tokenColors` array).

const fs = require("fs");
const path = require("path");
const vsctm = require("vscode-textmate");
const oniguruma = require("vscode-oniguruma");

const ROOT = __dirname;
const GRAMMAR_DIR = path.join(ROOT, "grammars");
const manifest = JSON.parse(
  fs.readFileSync(path.join(ROOT, "grammars.json"), "utf8"),
);

// vscode-textmate token metadata bit layout (stable in v9):
//   font style occupies bits 11-14, foreground index bits 15-23.
const FOREGROUND_MASK = 0x00ff8000;
const FOREGROUND_OFFSET = 15;
const FONT_STYLE_OFFSET = 11;
const FONT_STYLE_MASK = 0xf; // italic|bold|underline|strikethrough after shift

const INITIAL = vsctm.INITIAL;

// Grammar state (ruleStack) in effect *before* line `idx`, given an array of the
// end states produced *after* each line. Line 0 always begins from INITIAL.
function beginStateAt(endStates, idx) {
  return idx <= 0 ? INITIAL : endStates[idx - 1] || INITIAL;
}

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function loadRawGrammar(scopeName) {
  const entry = manifest[scopeName];
  if (!entry) {
    return null;
  }
  const filePath = path.join(GRAMMAR_DIR, entry.file);
  if (!fs.existsSync(filePath)) {
    return null;
  }
  const content = fs.readFileSync(filePath, "utf8");
  // parseRawGrammar uses the extension to pick the plist vs JSON parser.
  return vsctm.parseRawGrammar(content, filePath);
}

function loadTheme(themePath) {
  if (!themePath || !fs.existsSync(themePath)) {
    throw new Error(`theme file not found: ${themePath}`);
  }
  const raw = JSON.parse(fs.readFileSync(themePath, "utf8"));
  // VSCode themes name the rule array `tokenColors`; vscode-textmate wants `settings`.
  return { name: raw.name, settings: raw.tokenColors || raw.settings || [] };
}

async function createRegistry(theme) {
  const wasmPath = require.resolve("vscode-oniguruma/release/onig.wasm");
  const wasmBin = fs.readFileSync(wasmPath).buffer;
  await oniguruma.loadWASM(wasmBin);

  const onigLib = Promise.resolve({
    createOnigScanner: (patterns) => new oniguruma.OnigScanner(patterns),
    createOnigString: (s) => new oniguruma.OnigString(s),
  });

  return new vsctm.Registry({
    onigLib,
    theme,
    loadGrammar: async (scopeName) => loadRawGrammar(scopeName),
  });
}

// Converts vscode-textmate UTF-16 token offsets to byte offsets for one line.
// tokenizeLine2 returns a flat Uint32Array: [startIndex, metadata, ...].
function toByteTokens(line, binTokens) {
  const count = binTokens.length / 2;
  const out = [];
  let lastUtf16 = 0;
  let lastByte = 0;
  for (let i = 0; i < count; i++) {
    const startIndex = binTokens[2 * i];
    const metadata = binTokens[2 * i + 1];
    const endIndex = i + 1 < count ? binTokens[2 * (i + 1)] : line.length;

    lastByte += Buffer.byteLength(line.slice(lastUtf16, startIndex), "utf8");
    const s = lastByte;
    lastByte += Buffer.byteLength(line.slice(startIndex, endIndex), "utf8");
    const e = lastByte;
    lastUtf16 = endIndex;

    const color = (metadata & FOREGROUND_MASK) >>> FOREGROUND_OFFSET;
    const style = (metadata >>> FONT_STYLE_OFFSET) & FONT_STYLE_MASK;
    if (e > s && (color !== 0 || style !== 0)) {
      out.push({ s, e, c: color, y: style });
    }
  }
  return out;
}

async function main() {
  const theme = loadTheme(process.argv[2]);
  const registry = await createRegistry(theme);
  const colorMap = registry.getColorMap();
  const grammarCache = new Map();
  // bufId -> { scopeName, lines: string[], endState: StateStack[] }
  // endState[i] is the grammar rule stack after tokenizing line i.
  const bufferState = new Map();

  async function getGrammar(scopeName) {
    if (grammarCache.has(scopeName)) {
      return grammarCache.get(scopeName);
    }
    const grammar = await registry.loadGrammar(scopeName);
    grammarCache.set(scopeName, grammar);
    return grammar;
  }

  // Re-tokenize only what an edit could have changed. Lines shared as a textual
  // prefix keep their cached tokens; from the first differing line we tokenize
  // forward, stopping as soon as we re-enter the unchanged textual suffix with a
  // rule stack matching the previous pass (state convergence). The returned
  // range [start, stop) is the only region whose tokens may have changed.
  function tokenizeIncremental(grammar, bufId, scopeName, newLines) {
    let prev = bufferState.get(bufId);
    if (!prev || prev.scopeName !== scopeName) {
      prev = { scopeName, lines: [], endState: [] };
    }
    const oldLines = prev.lines;
    const oldEnd = prev.endState;
    const oldLen = oldLines.length;
    const newLen = newLines.length;

    let prefix = 0;
    while (
      prefix < oldLen &&
      prefix < newLen &&
      oldLines[prefix] === newLines[prefix]
    ) {
      prefix++;
    }

    let suffix = 0;
    while (
      suffix < oldLen - prefix &&
      suffix < newLen - prefix &&
      oldLines[oldLen - 1 - suffix] === newLines[newLen - 1 - suffix]
    ) {
      suffix++;
    }

    const delta = newLen - oldLen;
    const suffixStart = newLen - suffix;
    const newEnd = oldEnd.slice(0, prefix);
    const changed = [];
    let stack = beginStateAt(oldEnd, prefix);
    let i = prefix;
    while (i < newLen) {
      // Inside the unchanged textual suffix, identical begin state guarantees
      // identical tokens for this and every following line, so stop early.
      if (i >= suffixStart && stack.equals(beginStateAt(oldEnd, i - delta))) {
        break;
      }
      const result = grammar.tokenizeLine2(newLines[i], stack);
      changed.push(toByteTokens(newLines[i], result.tokens));
      newEnd[i] = result.ruleStack;
      stack = result.ruleStack;
      i++;
    }
    for (let j = i; j < newLen; j++) {
      newEnd[j] = oldEnd[j - delta];
    }

    bufferState.set(bufId, { scopeName, lines: newLines, endState: newEnd });

    // Repaint one line of left context. An extmark ending at the last column of
    // the line above the changed range bleeds onto the changed range when a
    // newline is inserted at that column (the client paints with end-right
    // gravity so typed characters extend a token). The client clears the changed
    // range before repainting, which drops the bled mark, so re-emit that line's
    // tokens to restore it. Its begin state is unchanged, so this only adds a
    // single line of work.
    if (prefix > 0) {
      const ctxLine = newLines[prefix - 1];
      const ctx = grammar.tokenizeLine2(
        ctxLine,
        beginStateAt(newEnd, prefix - 1),
      );
      changed.unshift(toByteTokens(ctxLine, ctx.tokens));
      return { start: prefix - 1, stop: i, tokens: changed, lineCount: newLen };
    }
    return { start: prefix, stop: i, tokens: changed, lineCount: newLen };
  }

  async function handle(msg) {
    if (msg.type === "ping") {
      send({ id: msg.id, type: "ok", pong: true });
      return;
    }
    if (msg.type === "drop") {
      bufferState.delete(msg.bufId);
      return;
    }
    if (msg.type !== "tokenize") {
      send({ id: msg.id, type: "error", message: `unknown type: ${msg.type}` });
      return;
    }
    const grammar = await getGrammar(msg.scopeName);
    if (!grammar) {
      send({
        id: msg.id,
        type: "error",
        message: `no grammar for scope ${msg.scopeName}`,
      });
      return;
    }
    const result = tokenizeIncremental(
      grammar,
      msg.bufId,
      msg.scopeName,
      msg.lines || [],
    );
    send({ id: msg.id, type: "ok", ...result });
  }

  let buffer = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    buffer += chunk;
    let nl;
    while ((nl = buffer.indexOf("\n")) !== -1) {
      const raw = buffer.slice(0, nl);
      buffer = buffer.slice(nl + 1);
      if (!raw.trim()) {
        continue;
      }
      let msg;
      try {
        msg = JSON.parse(raw);
      } catch (err) {
        send({ type: "error", message: `bad json: ${err.message}` });
        continue;
      }
      // Errors inside a single request must not kill the process.
      handle(msg).catch((err) => {
        send({ id: msg && msg.id, type: "error", message: String(err && err.message) });
      });
    }
  });
  process.stdin.on("end", () => process.exit(0));

  send({ type: "ready", colorMap });
}

main().catch((err) => {
  send({ type: "fatal", message: String(err && err.stack) });
  process.exit(1);
});
