//! A filesystem-backed anchor store — the border's half of
//! `doc/Resolver.zig`.
//!
//! The core states WHERE an anchor's bytes come from as an interface —
//! `Resolver`, one function, `read(path) ?[]const u8` — and holds the
//! in-memory table beside it. Reading a disk is IO, and IO lives at the
//! borders (plan 12, `CLAUDE.md`'s "IO at the borders"), so the store
//! that reads one lives here, one level above the core: the CLI reaches
//! it as `tempura.FsStore`, the corpus runner imports this file, and
//! `tempura.wasm` never references it at all — a freestanding target has
//! no `std.Io.Dir`, and a browser's store is `Resolver.Memory` holding
//! whatever `tpr_attachAnchor` verified.
//!
//! It reads `base_dir / path` on the first ask and keeps the bytes in its
//! own arena, so the BORROWED slice a `Resolver` hands out lives until
//! `deinit`. That is why it is a two-step — a store with a `deinit`, and
//! a `Resolver` taken from it — rather than a bare constructor with
//! nothing to free what it read (the brief's `fs(gpa, base_dir)`, with
//! the ownership made explicit).
//!
//! An anchor's `:file` is "resolved relative to the document" (plan 02),
//! which a host spells by pointing `base_dir` at the document's own
//! directory.
//!
//! ```zig
//! var store: tempura.FsStore = .init(gpa, io, doc_dir);
//! defer store.deinit();
//! var loaded = try tempura.doc.fromSource(gpa, &schema, source, store.resolver());
//! defer loaded.deinit();
//! ```

const std = @import("std");
const builtin = @import("builtin");

const resolver_file = @import("doc/Resolver.zig");
const Resolver = resolver_file.Resolver;
const Memory = resolver_file.Memory;

const FsStore = @This();

comptime {
    // The one target with no filesystem is the one the preloaded schema
    // exists to serve. A wasm that reached this file would be a wasm with
    // a store that cannot read, so it fails the build rather than a host.
    if (builtin.os.tag == .freestanding)
        @compileError("FsStore is a native border; a freestanding host's store is Memory");
}

/// Owns every path and every byte this store has read, freed at once by
/// `deinit`.
arena: std.heap.ArenaAllocator,
/// The handle Zig 0.16 needs to touch a disk. Borrowed from the caller.
io: std.Io,
/// The directory an anchor's `:file` is joined onto. Borrowed: it must
/// outlive the store.
base_dir: []const u8,
/// What has been read so far: `path → bytes`, both arena-owned. A second
/// ask for one path returns the first answer, so a document with two
/// anchors on one file reads it once — and a verb that needs an anchor's
/// bytes after the load (`build`, `inline`) gets them without a second
/// trip to the disk.
cache: std.ArrayList(Memory.Entry) = .empty,

/// A store over `base_dir`. Nothing is read until a `Resolver` taken
/// from it is asked. `gpa` backs the arena, which is the only allocation
/// the store makes and `deinit` frees; `io` and `base_dir` are borrowed.
pub fn init(gpa: std.mem.Allocator, io: std.Io, base_dir: []const u8) FsStore {
    return .{ .arena = .init(gpa), .io = io, .base_dir = base_dir };
}

/// Free every path and byte the store read. Every slice a `Resolver`
/// taken from it handed out dies here.
pub fn deinit(self: *FsStore) void {
    self.arena.deinit();
    self.* = undefined;
}

/// A `Resolver` over this store. Borrows `self`, which must not move
/// while the resolver is in use.
pub fn resolver(self: *const FsStore) Resolver {
    return .{ .ctx = self, .vtable = &vtable };
}

const vtable: Resolver.VTable = .{ .read = readImpl };

/// Read `base_dir / path`, or answer the cached read. Null for a file
/// that is not there, cannot be read, is past `MAX_ANCHOR_BYTES`, or
/// could not be held — the anchor then says `anchor_unavailable`, which
/// is the resolver's whole vocabulary for "not here".
fn readImpl(ctx: *const anyopaque, path: []const u8) ?[]const u8 {
    // The store mutates (it caches), and the vtable is const — the cast
    // back is sound because every `FsStore` a `Resolver` points at is
    // the caller's own mutable value.
    const self: *FsStore = @ptrCast(@alignCast(@constCast(ctx)));
    for (self.cache.items) |e| {
        if (std.mem.eql(u8, e.path, path)) return e.bytes;
    }
    const arena = self.arena.allocator();
    const full = std.fs.path.join(arena, &.{ self.base_dir, path }) catch return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        self.io,
        full,
        arena,
        .limited(resolver_file.MAX_ANCHOR_BYTES),
    ) catch return null;
    const key = arena.dupe(u8, path) catch return null;
    self.cache.append(arena, .{ .path = key, .bytes = bytes }) catch return null;
    return bytes;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "FsStore: reads relative to the base directory, once" {
    const gpa = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "impulse-04.it", .data = "IMPMbytes" });

    // `tmpDir` lives at `.zig-cache/tmp/<sub_path>` under the working
    // directory the test runs in, which is the base the store joins onto.
    const base = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base);

    var store: FsStore = .init(gpa, testing.io, base);
    defer store.deinit();
    const r = store.resolver();

    const first = r.read("impulse-04.it").?;
    try testing.expectEqualStrings("IMPMbytes", first);
    // Cached: the same slice comes back, not a second read.
    try testing.expectEqual(first.ptr, r.read("impulse-04.it").?.ptr);
    try testing.expect(r.read("absent.it") == null);
}
