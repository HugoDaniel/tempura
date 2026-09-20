//! `src/residue/` — the residue (P104, plan 04): a timeline inside a
//! `.mid` or a `.it`.
//!
//! The part aggregator (plan 01, "one aggregator per part"): it
//! re-exports the part's files and forces their inline tests, so
//! `zig build test -Dtest-root=residue/residue.zig` runs this subtree
//! alone with exactly the imports the root hands every part.
//!
//! Three things ride in a carrying file, and this part packs, frames and
//! places them:
//!
//!   1. the **essence** (`essence.zig`) — the document's timeline tier as
//!      SJON Binary IR, comments and all;
//!   2. the **lane records** and the **conductor record** (`records.zig`)
//!      — a content hash per rendered native lane and one over the file's
//!      whole timing context, both over EVENTS in tempura ticks;
//!   3. the **carriers** — `smf.zig` seats them as `FF 7F` events in a
//!      `Sequence`, `it.zig` as a trailing `TMPU` chunk and a message
//!      tail.
//!
//! Reconciliation — what a `dump` does with what it finds — is plan 04's
//! fifth phase, `reconcile.zig`: the five rules over a file and its
//! carrier, producing the timeline tier text a dump prepends to the
//! file's own. The assembly and the re-load are `doc/pipeline.zig`'s.

const std = @import("std");

/// The timeline tier as Binary IR: `pack` and `unpack`.
pub const essence = @import("essence.zig");

/// The envelope, the record bodies and the four hashes.
pub const records = @import("records.zig");

/// The SMF carrier: `attach` and `detach`.
pub const smf = @import("smf.zig");

/// The IT carriers: the `TMPU` chunk and the message tail.
pub const it = @import("it.zig");

/// Plan 04's five reconciliation rules, over a file and what its carrier
/// held.
pub const reconcile = @import("reconcile.zig");

/// This part's error set: only resource exhaustion. Every defect of a
/// payload is a diagnostic or a returned variant, never a Zig error.
pub const Error = error{OutOfMemory};

test {
    _ = essence;
    _ = records;
    _ = smf;
    _ = it;
    _ = reconcile;
}
