//! `tempura.wasm` entry — the `tpr_*` export surface.
//!
//! The artifact is a pure function of its linear memory: no clock, no
//! loop, no filesystem. A host writes a document's text or a file's bytes
//! into a static zone, calls a `tpr_*` verb, and reads a packed blob back
//! (pacer's `drv_*` shape; the table is plan 10, "Wasm exports").
//!
//! The export set is append-only from E3, together with the diagnostic
//! code enum: never remove or re-type an export — bump `tpr_abiVersion`
//! if the contract itself must change.
//!
//! Only the handshake ships so far. The memory zones, the load lifecycle
//! and the blob writers land with P108.

/// The ABI generation this module implements. A host reads it first and
/// refuses a module it does not know.
export fn tpr_abiVersion() u32 {
    return 1;
}
