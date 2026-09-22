// The score of a FILE, in both hosts:
//
//     tpr_loadFile → tpr_exportScore   ≡   tempura export-score FILE
//
// A file's score has one input a document's does not: the EASING HINTS a
// stale curve lane kept (plan 04, rule 2) — the easing a `.mid` cannot
// carry, which the lane record remembers and the file's own steps confirm.
// They are a verdict of the dump, not a fact of the document text, so a
// host that dumps and then keeps only the text loses them. That is what
// `tpr_loadFile` did until 2026-09-22: the CLI printed a stale curve's
// hinted segment as its easing and the wasm as a hold stair, and the
// corpus parity walk skipped every `(score …)` so nothing said so. Both
// hosts now take the hints through `Dumped.easeHints`.
//
// The one byte the two scores are allowed to differ in is the header's
// source name: the CLI prints the path's basename, and the wasm has no
// name to print (`(unnamed)`, the exporter's own spelling for none).
// Everything after it — every key, every easing — is compared.
//
// The native leg is skipped, with a printed reason, when
// `zig-out/bin/tempura` has not been built; `tools/zt verify` builds it
// before this suite runs.

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { Tempura } from '../src/index.js';

const fromRepo = (rel) => fileURLToPath(new URL(`../../../${rel}`, import.meta.url));
const wasmModule = new WebAssembly.Module(readFileSync(fromRepo('npm/tempura/tempura.wasm')));
const cliPath = fromRepo('zig-out/bin/tempura');

/**
 * `tempura export-score FILE [args…]`'s stdout, or null when the CLI has
 * not been built. The warnings go to stderr, and the exit code is the
 * document's verdict: a stale lane is a warning, so it is 0.
 *
 * @param {string} file
 * @param {string[]} args
 * @returns {string | null}
 */
function nativeScore(file, args) {
  if (!existsSync(cliPath)) return null;
  return execFileSync(cliPath, ['export-score', file, ...args], {
    stdio: ['ignore', 'pipe', 'pipe'],
  }).toString('utf8');
}

/**
 * The CLI's score with its source name spelled the way the wasm spells
 * none — the header's one legitimate difference, replaced exactly once.
 *
 * @param {string} score
 * @param {string} name
 */
function unnamed(score, name) {
  const cli = `; exported from ${name} (`;
  assert.ok(score.startsWith(cli), `the CLI's header names ${name}`);
  return `; exported from (unnamed) (${score.slice(cli.length)}`;
}

/**
 * @param {string} fixture the corpus path of the file
 * @param {{ noHints?: boolean }} opts
 * @param {string[]} args the same switches, as the CLI spells them
 */
function sameScore(fixture, opts, args) {
  const label = args.length ? ` ${args.join(' ')}` : '';
  test(`file score: ${fixture}${label} — the wasm's is the CLI's`, async () => {
    const bytes = new Uint8Array(readFileSync(fromRepo(fixture)));
    const t = await Tempura.instantiate(wasmModule);
    const loaded = t.loadFile(bytes, 'mid');
    assert.equal(loaded.ok, true, JSON.stringify(loaded.diagnostics));
    const wasm = t.exportScore(opts);
    assert.ok(wasm !== null, `a score came back: ${JSON.stringify(t.diagnostics)}`);

    const native = nativeScore(fromRepo(fixture), args);
    if (native === null) {
      console.log(
        'score: zig-out/bin/tempura is missing — skipping the native leg (run `tools/zt cli`)',
      );
      return;
    }
    assert.equal(wasm, unnamed(native, 'song.mid'), 'wasm32 and native printed one score');
  });
}

// The case the hints exist for: one kept, and spent on the third segment.
sameScore('corpus/residue-stale-curve/song.mid', {}, []);
// …the switch that ignores them, in both hosts' spellings.
sameScore('corpus/residue-stale-curve/song.mid', { noHints: true }, ['--no-hints']);
// A stale NOTES lane: the same path, no hint to spend.
sameScore('corpus/residue-stale-lane/song.mid', {}, []);

test('file score: the kept hint is what shapes the stale curve, in the wasm too', async () => {
  // Leg 0, and it needs no CLI: the hint reaches the wasm's exporter.
  // Without it the hinted segment is the file's own five steps as a hold
  // stair; with it they collapse to one key carrying the easing.
  const bytes = new Uint8Array(readFileSync(fromRepo('corpus/residue-stale-curve/song.mid')));
  const t = await Tempura.instantiate(wasmModule);
  t.loadFile(bytes, 'mid');
  const hinted = t.exportScore();
  const bare = t.exportScore({ noHints: true });
  assert.ok(hinted !== null && bare !== null);
  assert.match(hinted, /\(key :at 3b :value 1 :ease in-cubic\)/);
  assert.doesNotMatch(bare, /in-cubic/);

  // …and the hints are the DUMP's, not the text's: the same document
  // loaded back from its text carries no verdicts, exactly as `tempura
  // export-score d.sjon` over the dumped text passes none.
  const text = t.text;
  assert.ok(text);
  const again = await Tempura.instantiate(wasmModule);
  again.reload(text);
  again.attachAnchor(bytes);
  assert.equal(again.exportScore(), bare, 'a document from text scores as --no-hints');
});
