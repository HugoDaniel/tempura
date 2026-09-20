//! Never-panic fuzz harnesses for tempura's byte-eating and
//! arbitrary-input entrypoints.
//!
//! Each harness generates an input (via `std.testing.fuzz` + `Smith`, or
//! the baked-in corpus on a plain `zig build fuzz`), feeds it to the
//! target, and asserts ONLY invariants that must hold for ARBITRARY
//! input — never "it parsed" or "no diagnostics", since random bytes trip
//! every diagnostic there is. Leaks are caught by `testing.allocator`.
//!
//! Shipped as a SEPARATE target so `zig build test` and `verify` stay
//! fast (the SJON precedent). Every harness is also a plain `test {}`, so
//! its corpus runs on each invocation even without the instrumented
//! fuzzer.
//!
//! The readers, the VLQ decoder, pattern unpack and residue unpack join
//! as their parts land (P100, P101, P104). What is here now is the one
//! surface that already eats arbitrary bytes: diagnostic messages, which
//! quote whatever a malformed document or file contained.

const std = @import("std");
const Diag = @import("Diag.zig");

const Smith = std.testing.Smith;
const testing = std.testing;

/// Maximum message body any harness eats. Keeps fuzzing cheap; nothing
/// here has a length contract of its own.
const MAX_INPUT: usize = 1024;

/// A diagnostic message quotes its input — a lane name, a chunk tag, a
/// stretch of a `.it`'s CP437 text — so arbitrary bytes reach the
/// formatter. Invariants for ANY input: the message is a byte-for-byte
/// copy owned by the list, entries keep insertion order, `hasErrors`
/// tracks only severity, and `count` only the code.
fn fuzzDiagList(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const input = buf[0..smith.sliceWithHash(&buf, 0x7D_1A_67)];

    var list: Diag.List = .init(testing.allocator);
    defer list.deinit();

    const end: u32 = @intCast(input.len);
    const span: Diag.Span = .{ .start = 0, .end = end };

    try list.add(.it_message_encoding_lossy, .warning, span, "{s}", .{input});
    try testing.expect(!list.hasErrors());

    try list.add(.smf_unknown_chunk, .err, span, "chunk {s} at {d}", .{ input, end });
    try testing.expect(list.hasErrors());

    const got = list.items();
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings(input, got[0].message);
    try testing.expectEqual(Diag.Code.it_message_encoding_lossy, got[0].code);
    try testing.expectEqual(@as(usize, 1), list.count(.smf_unknown_chunk));
    try testing.expectEqual(@as(usize, 0), list.count(.walk_runaway));
}

test "fuzz Diag.List: arbitrary message bytes are copied whole and never panic" {
    try testing.fuzz({}, fuzzDiagList, .{
        .corpus = &.{
            "",
            "kick",
            // A format specifier in the DATA must stay data.
            "{s} {d} {{",
            // Invalid UTF-8: `.it` text is CP437, `.mid` text is anything.
            "\xff\xfe\x00\x80",
        },
    });
}
