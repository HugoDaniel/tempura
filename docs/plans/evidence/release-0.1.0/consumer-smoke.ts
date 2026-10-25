// TypeScript consumer: the package resolves, the public class type-checks,
// and the position-map declaration is reachable from the blobs subpath.
import type { PositionMap } from 'tempura/blobs';
import { Tempura } from 'tempura';
import type { Diagnostic, Kind, Timeline } from 'tempura';
import * as ops from 'tempura/ops';

export async function check(wasm: WebAssembly.Module, doc: string): Promise<void> {
  const t: Tempura = await Tempura.load(wasm, doc);
  const diags: readonly Diagnostic[] = t.diagnostics;
  const timeline: Timeline | null = t.timeline();
  const map: PositionMap | null = t.exportScoreMap();
  const kind: Kind = 'mid';
  const bytes: Uint8Array | null = t.build(kind);
  const planned = t.plan(ops.retime({ sel: ops.sel({ kinds: ['note'] }), delta: 1 }));
  if (diags.length > 0 || timeline === null || map === null || bytes === null) {
    throw new Error(`unexpected: ${planned.actions}`);
  }
}
