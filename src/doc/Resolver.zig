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
//! The vtable hands back a BORROWED slice: whatever owns the bytes
//! (`Fs`'s arena, the caller's literals) must outlive the read. That is
//! why `fs` is a two-step — a store with a `deinit`, and a `Resolver`
//! taken from it — rather than a bare constructor with nothing to free
//! it (the brief's `fs(gpa, base_dir)` / `memory(map)` pair, with the
//! ownership made explicit).

const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;

/// Reading a file can fail the way any allocation fails; a file that is
/// not there is a `null` from `read`, not an error.
pub const Error = error{OutOfMemory};

/// Ceiling on one anchor's bytes. A `.it` with a hundred megabytes of
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

/// Whether this target has a filesystem at all. `std.Io.Dir` has no
/// implementation on freestanding, which is exactly the target the
/// preloaded schema exists to serve, so `Fs` is a compile-time absence
/// there rather than a runtime failure.
pub const has_filesystem = builtin.os.tag != .freestanding;

/// A filesystem-backed store: reads `base_dir / path` on first ask and
/// keeps the bytes in its own arena, so the borrowed slices a `Resolver`
/// hands out live until `deinit`.
///
/// An anchor's `:file` is "resolved relative to the document" (plan 02),
/// which the host spells by pointing `base_dir` at the document's own
/// directory.
pub const Fs = if (!has_filesystem) struct {} else struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    base_dir: []const u8,
    /// What has been read so far: `path → bytes`, both arena-owned. A
    /// second ask for one path returns the first answer, so a document
    /// with two anchors on one file reads it once.
    cache: std.ArrayList(Memory.Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, base_dir: []const u8) Fs {
        return .{ .arena = .init(gpa), .io = io, .base_dir = base_dir };
    }

    pub fn deinit(self: *Fs) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// A `Resolver` over this store. Borrows `self`.
    pub fn resolver(self: *const Fs) Resolver {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Resolver.VTable = .{ .read = readImpl };

    fn readImpl(ctx: *const anyopaque, path: []const u8) ?[]const u8 {
        // The store mutates (it caches), and the vtable is const — the
        // cast back is sound because every `Fs` a `Resolver` points at is
        // the caller's own mutable value.
        const self: *Fs = @ptrCast(@alignCast(@constCast(ctx)));
        for (self.cache.items) |e| {
            if (std.mem.eql(u8, e.path, path)) return e.bytes;
        }
        const a = self.arena.allocator();
        const full = std.fs.path.join(a, &.{ self.base_dir, path }) catch return null;
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            full,
            a,
            .limited(MAX_ANCHOR_BYTES),
        ) catch return null;
        const key = a.dupe(u8, path) catch return null;
        self.cache.append(a, .{ .path = key, .bytes = bytes }) catch return null;
        return bytes;
    }
};

/// A filesystem-backed store — the brief's `fs(gpa, base_dir)`, with the
/// `io` handle Zig 0.16 needs to touch a disk and the `deinit` that owns
/// the bytes it hands out. Take the `Resolver` from it with `.resolver()`.
pub fn fs(gpa: std.mem.Allocator, io: std.Io, base_dir: []const u8) Fs {
    return .init(gpa, io, base_dir);
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
    try testing.expect(parseDigest("9F2A00000000000000000000000000000000000000000000000000000000ABCD") != null);

    // The plan's own elision is not a digest, and says so rather than
    // guessing at bytes.
    try testing.expect(parseDigest("9f2a…") == null);
    try testing.expect(parseDigest("") == null);
    try testing.expect(parseDigest("zz2a00000000000000000000000000000000000000000000000000000000abcd") == null);
}

test "Resolver.memory: a table answers what it holds and null for the rest" {
    const table: Memory = .{ .entries = &.{
        .{ .path = "impulse-04.it", .bytes = "IMPM" },
    } };
    const r = memory(&table);

    try testing.expectEqualStrings("IMPM", r.read("impulse-04.it").?);
    try testing.expect(r.read("nothing.it") == null);
}

test "Resolver.fs: reads relative to the base directory, once" {
    if (!has_filesystem) return error.SkipZigTest;
    const gpa = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "impulse-04.it", .data = "IMPMbytes" });

    // `tmpDir` lives at `.zig-cache/tmp/<sub_path>` under the working
    // directory the test runs in, which is the base the store joins onto.
    const base = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base);

    var store = fs(gpa, testing.io, base);
    defer store.deinit();
    const r = store.resolver();

    const first = r.read("impulse-04.it").?;
    try testing.expectEqualStrings("IMPMbytes", first);
    // Cached: the same slice comes back, not a second read.
    try testing.expectEqual(first.ptr, r.read("impulse-04.it").?.ptr);
    try testing.expect(r.read("absent.it") == null);
}
