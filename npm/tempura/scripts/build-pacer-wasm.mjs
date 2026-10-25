#!/usr/bin/env node
// Build the landing proof's pacer.wasm from the RECORDED pacer source.
//
// The landing test reads positions back through the real pacer driver
// (`node_modules/pacer/pacer.wasm`). That artifact is a development
// prerequisite, not a runtime dependency of tempura, and a sibling
// checkout can move or hold a stale build. This script pins the source
// commit, package version and wasm SHA-256 in `pacer-pin.json`, rebuilds
// the artifact with pacer's own npm scripts, and refuses to hand a
// different wasm to the test.
//
//   PACER_SRC=/path/to/pacer npm run build:pacer-wasm
//
// `PACER_SRC` defaults to `../../../pacer` (the workspace arrangement).
// To accept a deliberate pacer change, rebuild, review the diff, then
// update `pacer-pin.json`'s `commit`, `version` and `wasmSha256` in the
// same commit.

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const pkgRoot = resolve(here, '..');
const pin = JSON.parse(readFileSync(join(pkgRoot, 'pacer-pin.json'), 'utf8'));
const pacerSrc = resolve(process.env.PACER_SRC ?? join(pkgRoot, '..', '..', '..', 'pacer'));
const pacerPkg = join(pacerSrc, 'npm', 'pacer');

/** Run a command in `cwd`, inheriting stdio so pacer's own build speaks. */
function run(cmd, args, cwd) {
  execFileSync(cmd, args, { cwd, stdio: 'inherit' });
}

/** The source tree's commit, or null when this is not a git checkout. */
function sourceCommit() {
  try {
    return execFileSync('git', ['rev-parse', 'HEAD'], {
      cwd: pacerSrc,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    return null;
  }
}

function sha256(file) {
  return createHash('sha256').update(readFileSync(file)).digest('hex');
}

if (!existsSync(join(pacerPkg, 'package.json'))) {
  throw new Error(
    `pacer source not found at ${pacerSrc} — set PACER_SRC to a pacer checkout ` +
      '(the landing proof is a development check; tempura itself does not need pacer)',
  );
}
const manifest = JSON.parse(readFileSync(join(pacerPkg, 'package.json'), 'utf8'));
// The pin records the HEAD manifest version and, when the recorded tree was
// mid-release, the version it carried. Either is acceptable; the wasm hash
// below is what actually identifies the built driver.
const pinnedVersions = new Set([pin.version, pin.builtVersion].filter(Boolean));
if (manifest.name !== pin.name || !pinnedVersions.has(manifest.version)) {
  throw new Error(
    `pacer package is ${manifest.name}@${manifest.version}, pin is ${pin.name}@` +
      `${[...pinnedVersions].join('/')}; update pacer-pin.json deliberately after reviewing the change`,
  );
}
const commit = sourceCommit();
if (commit !== null && commit !== pin.commit) {
  throw new Error(
    `pacer source is ${commit}, pin is ${pin.commit}; check out the pinned commit or update ` +
      'pacer-pin.json deliberately after reviewing the change',
  );
}

run('npm', ['run', 'build:wasm'], pacerPkg);
run('npm', ['run', 'build:wasm-copy'], pacerPkg);

const built = join(pacerPkg, 'pacer.wasm');
const got = sha256(built);
if (got !== pin.wasmSha256) {
  throw new Error(
    `pacer.wasm is ${got}, pin is ${pin.wasmSha256}; the source changed or the build is not ` +
      'reproducible — review it, then update pacer-pin.json deliberately',
  );
}

// Install the freshly built artifact where `pacer/pacer.wasm` resolves.
// A `file:` dependency is a symlink in this workspace, so this may write
// the same path the build already produced; the copy is still the step
// that makes the test's resolution explicit.
const require = createRequire(join(pkgRoot, 'package.json'));
const installed = require.resolve('pacer/pacer.wasm');
writeFileSync(installed, readFileSync(built));

const installedHash = sha256(installed);
if (installedHash !== got) throw new Error(`copy to ${installed} did not round-trip`);
console.log(
  `pacer.wasm: ${pin.name}@${manifest.version} ${commit ?? '(no git)'} — sha256 ${installedHash}`,
);
