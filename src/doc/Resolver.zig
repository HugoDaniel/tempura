//! Where an anchor's bytes come from.
//!
//! An `(anchor …)` names a file; whether that file can be read at all is
//! the HOST's business, not the document's (wasm32 has no filesystem, an
//! editor may hold the bytes in memory, a test holds them in a literal).
//! So the bridge takes a `Resolver` — one function, `read(path) ?[]const
//! u8` — and every anchor rule is phrased against it:
//!
//!   * no resolver at all: nothing was asked to read anything, so a
//!     by-reference anchor is simply recorded unresolved and SILENT;
//!   * a resolver that cannot produce the bytes: `anchor_unavailable`;
//!   * bytes that do not match `:size` and `:sha256` — or an anchor that
//!     declares neither, which is the same refusal (the controller's
//!     ruling: the manifest made them optional, the host does not):
//!     `anchor_mismatch`, never a silent re-read.
//!
//! The vtable hands back a BORROWED slice: whatever owns the bytes (a
//! store's arena, the caller's literals) must outlive the read.
//!
//! This file is the INTERFACE and the in-memory store — the brief's
//! `memory(map)` — and nothing that touches a disk. The filesystem store
//! (the brief's `fs(gpa, base_dir)`) is a border's: `src/FsStore.zig`,
//! which the CLI reaches as `tempura.FsStore` and the corpus runner
//! imports, because reading a file is IO and the core reaches none
//! (plan 12, "IO at the borders"). `tempura.wasm`'s store is a `Memory`
//! holding whatever `tpr_attachAnchor` verified.

const std = @import("std");

const testing = std.testing;

/// Reading a file can fail the way any allocation fails; a file that is
/// not there is a `null` from `read`, not an error.
pub const Error = error{OutOfMemory};

/// Ceiling on one anchor's bytes, for a store that reads them (the
/// border's `src/FsStore.zig`). A `.it` with a hundred megabytes of
/// samples is not a document tempura is asked to hold; the read simply
/// answers `null` and the anchor says `anchor_unavailable`.
pub const MAX_ANCHOR_BYTES: usize = 256 * 1024 * 1024;

pub const Resolver = struct {
    ctx: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The file's bytes, or null when this host cannot produce them.
        /// The slice is BORROWED and must outlive the resolver's use.
        read: *const fn (ctx: *const anyopaque, path: []const u8) ?[]const u8,
    };

    /// Read `path`, or null.
    pub fn read(self: Resolver, path: []const u8) ?[]const u8 {
        return self.vtable.read(self.ctx, path);
    }
};

/// Do `bytes` match what an anchor declared?
///
/// Both halves, always: a length is cheap and a digest is not, so the
/// length is checked first and the hash only runs on bytes that could
/// still match. `std.crypto.hash.sha2.Sha256` is the one digest in the
/// repo.
pub fn verify(bytes: []const u8, size: u64, sha256: [32]u8) bool {
    if (bytes.len != size) return false;
    var got: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &got, .{});
    return std.crypto.timing_safe.eql([32]u8, got, sha256);
}

/// Parse a 64-hex-digit `:sha256` spelling, or null when it is not one.
/// Either case of letters is read; a document's elision (`"9f2a…"`) and
/// every other spelling answer null, and the anchor keeps its text.
pub fn parseDigest(text: []const u8) ?[32]u8 {
    if (text.len != 64) return null;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch return null;
    return out;
}

/// An in-memory table of `path → bytes`: what a test, an editor with an
/// open buffer, or a wasm host with a fetched file hands the bridge.
///
/// The caller owns both the table and every slice in it. Deterministic
/// by construction — a slice, not a hash map, so lookup order is the
/// table's order (plan 01's determinism rule).
pub const Memory = struct {
    entries: []const Entry,

    pub const Entry = struct {
        path: []const u8,
        bytes: []const u8,
    };

    /// A `Resolver` over this table. Borrows `self`.
    pub fn resolver(self: *const Memory) Resolver {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Resolver.VTable = .{ .read = readImpl };

    fn readImpl(ctx: *const anyopaque, path: []const u8) ?[]const u8 {
        const self: *const Memory = @ptrCast(@alignCast(ctx));
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.path, path)) return e.bytes;
        }
        return null;
    }
};

/// A `Resolver` over an in-memory table — the brief's `memory(map)`.
pub fn memory(map: *const Memory) Resolver {
    return map.resolver();
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "Resolver.verify: the size and the digest, both" {
    const bytes = "impulse";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    try testing.expect(verify(bytes, bytes.len, digest));
    // A size that disagrees is refused before the hash runs.
    try testing.expect(!verify(bytes, bytes.len + 1, digest));
    // A digest that disagrees in one bit is refused.
    var wrong = digest;
    wrong[31] ^= 1;
    try testing.expect(!verify(bytes, bytes.len, wrong));
}

test "Resolver.parseDigest: 64 hex digits, either case, and nothing else" {
    const hex = "9f2a00000000000000000000000000000000000000000000000000000000abcd";
    const got = parseDigest(hex).?;
    try testing.expectEqual(@as(u8, 0x9f), got[0]);
    try testing.expectEqual(@as(u8, 0x2a), got[1]);
    try testing.expectEqual(@as(u8, 0xcd), got[31]);
    try testing.expect(
        parseDigest("9F2A00000000000000000000000000000000000000000000000000000000ABCD") != null,
    );

    // The plan's own elision is not a digest, and says so rather than
    // guessing at bytes.
    try testing.expect(parseDigest("9f2a…") == null);
    try testing.expect(parseDigest("") == null);
    try testing.expect(
        parseDigest("zz2a00000000000000000000000000000000000000000000000000000000abcd") == null,
    );
}

test "Resolver.memory: a table answers what it holds and null for the rest" {
    const table: Memory = .{ .entries = &.{
        .{ .path = "impulse-04.it", .bytes = "IMPM" },
    } };
    const r = memory(&table);

    try testing.expectEqualStrings("IMPM", r.read("impulse-04.it").?);
    try testing.expect(r.read("nothing.it") == null);
}
