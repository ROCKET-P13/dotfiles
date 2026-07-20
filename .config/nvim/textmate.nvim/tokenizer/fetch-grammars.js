#!/usr/bin/env node
// Downloads the TextMate grammar files declared in grammars.json into ./grammars.
// Runs during the lazy.nvim `build` step. Tolerates individual failures so a
// single unreachable grammar does not break the whole install.

const fs = require("fs");
const path = require("path");

const ROOT = __dirname;
const OUT_DIR = path.join(ROOT, "grammars");
const manifest = JSON.parse(
  fs.readFileSync(path.join(ROOT, "grammars.json"), "utf8"),
);

async function download(scopeName, entry) {
  const dest = path.join(OUT_DIR, entry.file);
  const res = await fetch(entry.url);
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} for ${entry.url}`);
  }
  const body = Buffer.from(await res.arrayBuffer());
  fs.writeFileSync(dest, body);
  return { scopeName, file: entry.file, bytes: body.length };
}

(async () => {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const entries = Object.entries(manifest);
  let ok = 0;
  let failed = 0;
  for (const [scopeName, entry] of entries) {
    try {
      const r = await download(scopeName, entry);
      ok += 1;
      console.log(`[ok]   ${r.scopeName} -> ${r.file} (${r.bytes} bytes)`);
    } catch (err) {
      failed += 1;
      console.error(`[fail] ${scopeName}: ${err.message}`);
    }
  }
  console.log(`Fetched ${ok}/${entries.length} grammars (${failed} failed).`);
  // A total failure (e.g. no network) is worth a non-zero exit so the user notices.
  if (ok === 0) {
    process.exit(1);
  }
})();
