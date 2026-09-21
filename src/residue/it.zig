//! The IT carriers: the trailing `TMPU` chunk and the message tail.
//!
//! Plan 04, "The IT carriers" — two carriers graded by survival.
//!
//! # 1. The chunk
//!
//! `'TMPU'` then a `u32 LE` length then a record list, written after all
//! IT data, where OpenMPT and Schism put their own extensions. IT and
//! every player load by parapointers and never read past the last region
//! they are pointed at, so the bytes are invisible to them. The IT core
//! already finds the chunk (`Module.tmpu`) and writes one back
//! (`itf.write.Options.tmpu`); this file decides what goes in it.
//!
//! Inside, the records use the envelope of `records.zig` with the length
//! that a `.mid`'s meta event supplies and a chunk does not:
//!
//! ```
//! 7D 74 65 6D  ver  kind  seq  total  len u32 LE  <body[len]>
//! ```
//!
//! in plan 04's own order — the essence, every lane record, the
//! conductor record. A record is never split here: the chunk has room.
//! Survival through a FOREIGN re-save is not expected (a tracker writes
//! from its in-memory module and drops trailing bytes it did not read),
//! which is why there is a second carrier.
//!
//! # 2. The message tail
//!
//! The song message is a first-class field, so every tracker keeps it.
//! After the human message comes a line `;; tempura` and then the
//! ADDRESSED SUMMARY as SJON text: the `(timeline …)` keys, the carrying
//! anchor's marker, every `(section …)` and `(cue …)`, every lane's
//! DECLARATION — name, kind, target, binding address, range — and every
//! pass-through `(control …)`. No native content, no phrases, no
//! records, so a dump from the tail alone rebuilds the shape of the
//! piece and nothing of what the file already holds.
//!
//! The marker's anchor is in the summary although plan 04's list does
//! not name it: every lane address is `:from <anchor>`, and a document
//! whose `:from` names nothing is not a document. It is the same marker
//! the essence carries (`essence.self_file`).
//!
//! **ASCII by construction.** OpenMPT transcodes the message (CP437 or
//! Windows-1252 to Unicode and back), so a byte outside printable ASCII
//! would not survive a round trip through a tracker. SJON has no escape
//! for a non-ASCII byte — its lexer rejects `\u{…}` deliberately, and an
//! identifier has no escape mechanism at all — so the tail spells such a
//! byte `%XX`, upper-case hex, with `%` itself as `%25`. Percent is a
//! legal identifier character (`SJON/docs/LANGUAGE.md` §2.3), so a
//! symbol survives the same treatment as a string. A name that needed it
//! is reported `it_message_encoding_lossy`.
//!
//! **Newlines are CR**, IT's own (`src/itf/write.zig` keeps the message
//! raw). `appendTail` is what joins a human message to a tail, because
//! the one CR between them is what keeps the marker at the start of a
//! line — `splitMessage` finds it there and nowhere else, and
//! `parseTail` undoes the `%XX` escaping on the way back.
//!
//! **4096 bytes.** What does not fit is dropped whole lines at a time,
//! and `residue_tail_truncated` names what fell off.

const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("../Diag.zig");
const Doc = @import("../doc/Value.zig");
const TimeMap = @import("../time/TimeMap.zig");
const essence = @import("essence.zig");
const records = @import("records.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Only resource exhaustion is an error.
pub const Error = error{OutOfMemory};

/// The 4-CC of the trailing chunk.
pub const tag = "TMPU";

/// The line that opens the message tail.
pub const marker = ";; tempura";

/// What the tail may cost, plan 04's budget.
pub const tail_budget: usize = 4096;

/// IT's own newline.
pub const newline: u8 = '\r';

// ---- the chunk -------------------------------------------------------

/// The payloads recovered from a chunk. `payloads` borrows `arena`.
pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    payloads: records.Payloads,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

/// What a chunk turned out to be.
pub const ParsedChunk = union(enum) {
    ok: Parsed,
    /// Nothing this build reads, and at least one record of a newer
    /// envelope version — the byte is that version (plan 04, rule 3).
    version: u8,
    /// The framing does not hold: `residue_corrupt`.
    corrupt: Diag.Code,

    pub fn deinit(self: *ParsedChunk) void {
        switch (self.*) {
            .ok => |*p| p.deinit(),
            .version, .corrupt => {},
        }
    }
};

/// The `TMPU` chunk's PAYLOAD — what `itf.write.Options.tmpu` takes.
/// Caller owns the bytes.
///
/// Plan 04's order: the essence, every lane record, the conductor
/// record. Nothing is written for a payload that is not there, so a
/// document with no rendered lane costs no records.
pub fn chunk(gpa: Allocator, payloads: records.Payloads) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    if (payloads.essence) |body| {
        // An essence offered and empty is `pack`'s report that the tier
        // is past SJON's limits (`residue_unencodable`, raised there);
        // there is no record to write for it.
        if (body.len > 0) try appendRecord(&out, gpa, .{
            .kind = @intFromEnum(records.Kind.essence),
            .body = body,
        });
    }
    for (payloads.lanes) |body| try appendRecord(&out, gpa, .{
        .kind = @intFromEnum(records.Kind.lane),
        .body = body,
    });
    if (payloads.conductor) |body| try appendRecord(&out, gpa, .{
        .kind = @intFromEnum(records.Kind.conductor),
        .body = body,
    });
    return out.toOwnedSlice(gpa);
}

/// One record: the envelope, the length the chunk has to supply, the
/// body.
fn appendRecord(out: *std.ArrayList(u8), gpa: Allocator, p: records.Payload) Error!void {
    try records.writeHead(out, gpa, p);
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(p.body.len), .little);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, p.body);
}

/// A chunk payload back into payloads. Total on arbitrary bytes.
///
/// A record whose `ver` this build does not write is STEPPED OVER by its
/// length — which is what the length is for — and, when nothing readable
/// is left, the chunk is a newer tempura's and stays where it is
/// (plan 04, rule 3).
pub fn parseChunk(gpa: Allocator, bytes: []const u8) Error!ParsedChunk {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    // `.corrupt` and `.version` are RETURNS, not errors, so `errdefer`
    // would not fire on them and a chunk whose framing broke after a
    // record had already been duped would leak the lot. The flag covers
    // every way out but the one that hands the arena on.
    var kept = false;
    defer if (!kept) arena.deinit();

    var taken: records.Gathered = .{};
    var newer: ?u8 = null;

    var at: usize = 0;
    // Bounded by the chunk's own length: every record read moves `at`
    // past its head, and a head that does not fit ends the walk.
    while (at < bytes.len) {
        const rec = framedAt(bytes, at) orelse return .{ .corrupt = .residue_corrupt };
        at = rec.next;
        if (rec.payload.ver != records.version) {
            if (newer == null) newer = rec.payload.ver;
            continue;
        }
        // `04` is midivia's; anything else is nobody's this build
        // knows. The chunk is re-emitted whole by the IT writer, so
        // stepping over them here loses nothing.
        _ = try taken.take(arena.allocator(), rec.payload);
    }

    // The framing held but nothing in it is this version's: the whole
    // chunk belongs to a newer tempura.
    if (newer) |v| {
        if (taken.isEmpty()) return .{ .version = v };
    }

    // A chunk never splits the essence — it has room — but a reader that
    // refused a split one would be brittle for no gain, so the same
    // all-or-none reassembly runs here. Its diagnostic is the caller's
    // business, and `choose` is where a corrupt chunk becomes one.
    var quiet: Diag.List = .init(gpa);
    defer quiet.deinit();
    const essence_body = try records.reassemble(arena.allocator(), taken.parts.items, &quiet);
    if (quiet.count(.residue_corrupt) > 0) return .{ .corrupt = .residue_corrupt };

    kept = true;
    return .{ .ok = .{
        .arena = arena,
        .payloads = .{
            .essence = essence_body,
            .conductor = taken.conductor,
            .lanes = taken.lanes.items,
        },
    } };
}

/// One record as the chunk frames it, at `at`: the envelope, the `u32
/// LE` length the chunk supplies, and the body it promises — with
/// `next` the offset of the record after it. Null when the framing does
/// not hold: no envelope, no room for the length, or a body the chunk
/// has not got. Pure over the bytes, and total on any of them.
const Framed = struct { payload: records.Payload, next: usize };

fn framedAt(bytes: []const u8, at: usize) ?Framed {
    var p = records.readHead(bytes[at..]) orelse return null;
    var cursor = at + records.head_len;
    if (bytes.len - cursor < 4) return null;
    const len = std.mem.readInt(u32, bytes[cursor..][0..4], .little);
    cursor += 4;
    if (bytes.len - cursor < len) return null;
    p.body = bytes[cursor..][0..len];
    return .{ .payload = p, .next = cursor + len };
}

// ---- the message tail ------------------------------------------------

/// A song message, split at the marker.
pub const Split = struct {
    /// What a tracker shows as the song's text, the separating newline
    /// removed.
    human: []const u8,
    /// The tail, from `;; tempura` to the end, or null.
    tail: ?[]const u8,
};

/// The tail and what it cost to write it.
pub const Tail = struct {
    bytes: []u8,
    diags: Diag.List,

    pub fn deinit(self: *Tail, gpa: Allocator) void {
        gpa.free(self.bytes);
        self.diags.deinit();
    }
};

/// The addressed summary of `doc`, as the message tail.
///
/// `map` is the document's own `TimeMap`: a tick's spelling is a
/// question only a bar table can answer, exactly as for the canonical
/// printer.
pub fn tail(gpa: Allocator, doc: *const Doc.Doc, map: *const TimeMap.TimeMap) Error!Tail {
    doc.invariants();
    map.invariants();
    var t: Tailer = .{
        .gpa = gpa,
        .doc = doc,
        .map = map,
        .diags = .init(gpa),
    };
    errdefer {
        t.out.deinit(gpa);
        t.line.deinit(gpa);
        t.diags.deinit();
    }
    try t.write();
    // The last allocation BEFORE the line is freed: the `errdefer`
    // above frees it too, and a failed `toOwnedSlice` after a `deinit`
    // freed it twice.
    const bytes = try t.out.toOwnedSlice(gpa);
    t.line.deinit(gpa);
    return .{ .bytes = bytes, .diags = t.diags };
}

/// Where the human message ends and the tail begins.
///
/// The marker counts only at the start of a line, so a song text that
/// mentions `;; tempura` in a sentence is still all human.
pub fn splitMessage(message: []const u8) Split {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, message, from, marker)) |at| {
        if (at == 0 or message[at - 1] == '\r' or message[at - 1] == '\n') {
            var human_end = at;
            if (human_end > 0 and message[human_end - 1] == '\n') human_end -= 1;
            if (human_end > 0 and message[human_end - 1] == '\r') human_end -= 1;
            return .{ .human = message[0..human_end], .tail = message[at..] };
        }
        from = at + 1;
    }
    return .{ .human = message, .tail = null };
}

/// A tail back into SJON source: the marker line dropped, the `%XX`
/// escaping undone, IT's CR newlines turned into the LF a parser reads.
/// Caller owns the text.
///
/// The reversal is exact because the writer escapes `%` itself as
/// `%25`, so every `%` followed by two hex digits in a tail is an
/// escape and nothing else. It is safe for a SYMBOL as well as for a
/// string: SJON's identifiers are ASCII (`LANGUAGE.md` §2.3), so the
/// only byte a name spelled as a symbol can ever have had escaped is
/// the `%`.
pub fn parseTail(gpa: Allocator, text: []const u8) Error![:0]u8 {
    var body = text;
    if (std.mem.startsWith(u8, body, marker)) {
        body = body[marker.len..];
        if (body.len > 0 and body[0] == '\r') body = body[1..];
        if (body.len > 0 and body[0] == '\n') body = body[1..];
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '%') {
            if (i + 2 < body.len) {
                if (unhex(body[i + 1])) |hi| {
                    if (unhex(body[i + 2])) |lo| {
                        try out.append(gpa, hi * 16 + lo);
                        i += 3;
                        continue;
                    }
                }
            }
            // A `%` this writer did not put there: kept as it stands.
            try out.append(gpa, c);
            i += 1;
            continue;
        }
        if (c == '\r') {
            // A lone CR is a newline; a CRLF is one newline, not two.
            i += 1;
            if (i < body.len and body[i] == '\n') continue;
            try out.append(gpa, '\n');
            continue;
        }
        try out.append(gpa, c);
        i += 1;
    }
    return out.toOwnedSliceSentinel(gpa, 0);
}

fn unhex(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A' + 10,
        'a'...'f' => c - 'a' + 10,
        else => null,
    };
}

/// `message` with `tail` after it, one CR between them when there is a
/// message to separate — what `itf.write.Options.message_tail` wants.
///
/// It exists so a caller cannot produce a marker in the middle of a
/// line, which `splitMessage` would not find. Caller owns the bytes.
pub fn appendTail(gpa: Allocator, message: []const u8, text: []const u8) Error![]u8 {
    if (message.len == 0) return gpa.dupe(u8, text);
    const ends_in_newline = message[message.len - 1] == '\r' or message[message.len - 1] == '\n';
    return std.mem.concat(gpa, u8, &.{
        message,
        if (ends_in_newline) "" else &[_]u8{newline},
        text,
    });
}

/// Builds the tail one form at a time, and stops when the budget is
/// spent rather than cutting a form in half.
const Tailer = struct {
    gpa: Allocator,
    doc: *const Doc.Doc,
    map: *const TimeMap.TimeMap,
    diags: Diag.List,
    out: std.ArrayList(u8) = .empty,
    line: std.ArrayList(u8) = .empty,
    /// How many forms did not fit, by group.
    dropped: [4]u32 = @splat(0),
    /// Whether any name had to be spelled with `%XX`.
    lossy: bool = false,

    const group_section = 0;
    const group_cue = 1;
    const group_lane = 2;
    const group_control = 3;

    fn write(self: *Tailer) Error!void {
        try self.out.appendSlice(self.gpa, marker);
        try self.out.append(self.gpa, newline);

        try self.timeline();
        try self.anchor();
        for (self.doc.sections) |s| try self.section(s);
        for (self.doc.cues) |c| try self.cue(c);
        for (self.doc.lanes) |l| try self.lane(l);
        for (self.doc.passthrough) |pt| {
            if (!std.mem.eql(u8, pt.head, "control")) continue;
            try self.passthrough(pt);
        }

        var lost: u32 = 0;
        for (self.dropped) |n| lost += n;
        if (lost > 0) try self.diags.add(
            .residue_tail_truncated,
            .warning,
            .{ .start = 0, .end = 0 },
            "the message tail is {d} bytes of {d}; {d} forms did not fit ({d} sections, {d} " ++
                "cues, {d} lanes, {d} controls)",
            .{
                self.out.items.len, tail_budget,     lost,
                self.dropped[0],    self.dropped[1], self.dropped[2],
                self.dropped[3],
            },
        );
    }

    /// The line just built, if it fits. A form is never cut: what does
    /// not fit is counted and left out whole.
    fn commit(self: *Tailer, group: usize) Error!void {
        defer self.line.clearRetainingCapacity();
        if (self.out.items.len + self.line.items.len + 1 > tail_budget) {
            self.dropped[group] += 1;
            return;
        }
        try self.keep();
    }

    /// The line just built, budget or no budget — the two forms a tail
    /// is not a tail without. They are the first things written, so
    /// this can only overrun on a document whose own header is longer
    /// than 4096 bytes, and a truncated header would be worse than a
    /// long one.
    fn keep(self: *Tailer) Error!void {
        defer self.line.clearRetainingCapacity();
        try self.out.appendSlice(self.gpa, self.line.items);
        try self.out.append(self.gpa, newline);
    }

    fn timeline(self: *Tailer) Error!void {
        const d = self.doc;
        try self.raw("(timeline");
        if (d.title) |t| {
            try self.raw(" :title ");
            try self.string(t);
        }
        if (d.length) |tick| {
            try self.raw(" :length ");
            try self.pos(tick);
        }
        if (d.end != .hold) try self.raw(" :end loop");
        if (d.conductor) |c| {
            try self.raw(" :conductor ");
            try self.symbol(c);
        }
        try self.raw(")");
        // Never dropped: `(timeline …)` is the document's first root and
        // a tail without it does not read at all.
        try self.keep();
    }

    /// The carrying anchor, as the same marker the essence carries.
    /// Plan 04's list of the tail's content does not name it, and every
    /// address below is `:from <anchor>` — so it is here, spelled
    /// `:file "self"`, and nothing of the path, the size or the digest
    /// that the residue itself changes.
    fn anchor(self: *Tailer) Error!void {
        const id = essence.carrierOf(self.doc) orelse return;
        const carrier = self.doc.anchorById(id) orelse return;
        try self.raw("(anchor :id ");
        try self.symbol(carrier.id);
        try self.raw(" :kind ");
        try self.raw(@tagName(carrier.kind));
        try self.raw(" :file ");
        try self.string(essence.self_file);
        try self.raw(")");
        // Never dropped either: every address below is `:from` this.
        try self.keep();
    }

    fn section(self: *Tailer, s: Doc.Section) Error!void {
        try self.raw("(section :name ");
        try self.symbol(s.name);
        try self.raw(" :at ");
        try self.pos(s.at);
        try self.raw(" :dur ");
        try self.pos(s.dur);
        try self.raw(")");
        try self.commit(group_section);
    }

    fn cue(self: *Tailer, c: Doc.Cue) Error!void {
        try self.raw("(cue :name ");
        try self.string(c.name);
        try self.raw(" :at ");
        try self.pos(c.at);
        try self.raw(")");
        try self.commit(group_cue);
    }

    /// A lane's DECLARATION: what it is, what it drives, where it is
    /// bound and what its range is. Never its content — that is the
    /// essence's, and for a bound lane it is the file's.
    fn lane(self: *Tailer, l: Doc.Lane) Error!void {
        try self.raw("(lane :name ");
        try self.symbol(l.name);
        try self.raw(" :kind ");
        try self.raw(@tagName(l.kind));
        if (!std.mem.eql(u8, l.target, l.name)) {
            try self.raw(" :target ");
            try self.symbol(l.target);
        }
        if (l.binding) |b| {
            try self.raw(" :from ");
            try self.symbol(b.anchor);
            switch (b.address) {
                .smf => |s| try self.smfAddress(s),
                .it => |s| try self.itAddress(s),
            }
        }
        if (l.range) |r| {
            try self.raw(" :range [");
            try self.float(r[0]);
            try self.raw(" ");
            try self.float(r[1]);
            try self.raw("]");
        }
        // The two source-text keys are DECLARATIONS, not content: a
        // `query` lane without its `:query` does not read back at all.
        if (l.query_src) |q| {
            try self.raw(" :query ");
            try self.raw(q);
        }
        if (l.expr_src) |e| {
            try self.raw(" :expr ");
            try self.raw(e);
        }
        try self.raw(")");
        try self.commit(group_lane);
    }

    /// A `.mid` address's keys: the track, the channel or channel set,
    /// and the key and the controller that narrow it, in the canonical
    /// printer's order and spelling.
    fn smfAddress(self: *Tailer, s: @FieldType(Doc.Address, "smf")) Error!void {
        try self.raw(" :track ");
        try self.int(s.track);
        try self.raw(" :ch ");
        try self.channels(s.ch);
        if (s.key) |k| {
            try self.raw(" :key ");
            try self.int(k);
        }
        if (s.curve) |curve| try self.curveKey(curve);
    }

    /// The canonical printer's spelling of a channel set: `2` for one
    /// channel, `[1 2]` for several, 1-based as the document counts.
    fn channels(self: *Tailer, chs: Doc.Channels) Error!void {
        if (chs.count() == 1) return self.int(@as(u8, chs.first()) + 1);
        try self.raw("[");
        var it = chs.iterator();
        var sep = false;
        while (it.next()) |c| {
            if (sep) try self.raw(" ");
            sep = true;
            try self.int(@as(u8, c) + 1);
        }
        try self.raw("]");
    }

    /// The one key that names a curve's controller surface.
    fn curveKey(self: *Tailer, curve: Doc.SmfCurve) Error!void {
        switch (curve) {
            .cc => |n| {
                try self.raw(" :cc ");
                try self.int(n);
            },
            .cc14 => |pair| {
                try self.raw(" :cc [");
                try self.int(pair[0]);
                try self.raw(" ");
                try self.int(pair[1]);
                try self.raw("]");
            },
            .bend => try self.raw(" :bend true"),
            .pressure => try self.raw(" :pressure true"),
            .velocity => try self.raw(" :velocity true"),
        }
    }

    /// A `.it` address's keys: the channel, 1-based, and the column and
    /// effect letter that narrow it.
    fn itAddress(self: *Tailer, s: @FieldType(Doc.Address, "it")) Error!void {
        try self.raw(" :channel ");
        try self.int(@as(u8, s.channel) + 1);
        if (s.column) |col| {
            try self.raw(" :column ");
            try self.raw(@tagName(col));
        }
        if (s.fx) |letter| {
            try self.raw(" :fx ");
            try self.string(&[_]u8{letter});
        }
    }

    /// A pacer root, verbatim but for its newlines, which become IT's.
    fn passthrough(self: *Tailer, pt: Doc.Passthrough) Error!void {
        for (pt.text) |c| {
            if (c == '\n') {
                try self.line.append(self.gpa, newline);
            } else {
                try self.byte(c);
            }
        }
        try self.commit(group_control);
    }

    // ---- atoms --------------------------------------------------------

    fn raw(self: *Tailer, text: []const u8) Error!void {
        try self.line.appendSlice(self.gpa, text);
    }

    /// One byte, ASCII or percent-escaped. Everything that reaches the
    /// tail goes through here.
    fn byte(self: *Tailer, c: u8) Error!void {
        if (c >= 0x20 and c < 0x7F and c != '%') {
            try self.line.append(self.gpa, c);
            return;
        }
        // A literal `%` is escaped so the spelling stays reversible, but
        // it is ASCII already: nothing was lost and nothing is reported.
        if (c != '%') self.lossy = true;
        var buf: [3]u8 = undefined;
        // `%` and the two hex digits of one byte: exactly three.
        const text = std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch unreachable;
        try self.line.appendSlice(self.gpa, text);
    }

    /// A symbol: percent-escaped, unquoted. `%` is a legal identifier
    /// character, so the escape stays one symbol.
    fn symbol(self: *Tailer, text: []const u8) Error!void {
        try self.escaped(text);
    }

    /// A quoted string: percent-escaped first, so SJON's own escaping
    /// only ever sees printable ASCII and the result is ASCII too.
    fn string(self: *Tailer, text: []const u8) Error!void {
        const before = self.line.items.len;
        try self.escaped(text);
        const ascii = try self.gpa.dupe(u8, self.line.items[before..]);
        defer self.gpa.free(ascii);
        self.line.shrinkRetainingCapacity(before);
        try sjon.StringEscape.appendQuoted(&self.line, self.gpa, ascii);
    }

    fn escaped(self: *Tailer, text: []const u8) Error!void {
        const was = self.lossy;
        self.lossy = false;
        for (text) |c| try self.byte(c);
        if (self.lossy) try self.diags.add(
            .it_message_encoding_lossy,
            .warning,
            .{ .start = 0, .end = 0 },
            "\"{s}\" is not ASCII and the song message is transcoded by every tracker; the tail " ++
                "spells it with %XX escapes",
            .{text},
        );
        self.lossy = was or self.lossy;
    }

    fn pos(self: *Tailer, tick: i64) Error!void {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        // `Pos.spell`'s widest line is 25 bytes, against 64: an i64 with
        // `bar` is 23 and with `t` 21, and a quarter decimal is a sign,
        // at most twelve digits (`maxInt(i64) / 9009 / 5120`), the point,
        // ten decimals and `q`.
        self.map.spell(&w, tick) catch unreachable;
        try self.raw(w.buffered());
    }

    fn int(self: *Tailer, v: anytype) Error!void {
        // The widest integer this is asked for is 64 bits: twenty digits
        // and a sign, against 32.
        comptime std.debug.assert(@bitSizeOf(@TypeOf(v)) <= 64);
        var buf: [32]u8 = undefined;
        try self.raw(std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
    }

    fn float(self: *Tailer, x: f32) Error!void {
        var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
        if (@floor(x) == x and @abs(x) < 16_777_216) {
            // A whole number below 2^24: eight digits and a sign, into
            // a buffer sized for the widest f64 decimal.
            const whole: i32 = @intFromFloat(x);
            try self.raw(std.fmt.bufPrint(&buf, "{d}", .{whole}) catch unreachable);
        } else {
            // `bufferSize`'s bound for an f64 in decimal: an f32 has
            // fewer digits and a smaller exponent, so it is narrower.
            try self.raw(std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable);
        }
    }
};

// ---- which carrier a dump reads --------------------------------------

/// The carrier a dump should believe.
pub const Chosen = union(enum) {
    chunk: Parsed,
    /// The tail's text, BORROWED from the message it was found in.
    tail: []const u8,
    none,

    pub fn deinit(self: *Chosen) void {
        switch (self.*) {
            .chunk => |*p| p.deinit(),
            .tail, .none => {},
        }
    }
};

/// Plan 04's rule 5, as far as a carrier can answer it: the chunk wins
/// when it is present and readable, the tail is used when the chunk is
/// absent, corrupt or of a version this build does not read, and
/// `residue_partial` names what the tail cannot carry.
///
/// A chunk that parses but holds nothing counts as absent: an empty
/// `TMPU` says no more than no `TMPU` at all.
pub fn choose(
    gpa: Allocator,
    chunk_bytes: ?[]const u8,
    message: []const u8,
    diags: *Diag.List,
) Error!Chosen {
    if (chunk_bytes) |bytes| {
        var parsed = try parseChunk(gpa, bytes);
        switch (parsed) {
            .ok => |p| {
                const empty = p.payloads.essence == null and
                    p.payloads.conductor == null and
                    p.payloads.lanes.len == 0;
                // Rule 5 gives the tail every chunk "of a version the
                // reader does not know", and the essence's own Binary IR
                // wire version is one of those: a body this substrate
                // will not decode is a chunk it cannot use, whatever its
                // envelope says (`essence.newerWire`). It stays in the
                // file, as the envelope case does.
                const wire = if (p.payloads.essence) |body| essence.newerWire(body) else null;
                if (!empty and wire == null) return .{ .chunk = p };
                parsed.deinit();
                if (wire) |v| try diags.add(
                    .residue_version,
                    .warning,
                    .{ .start = 0, .end = 0 },
                    "the TMPU chunk's essence is SJON Binary IR of wire version {d}, which this " ++
                        "substrate does not decode; it stays in the file and the message tail " ++
                        "is read instead",
                    .{v},
                );
            },
            .version => |v| try diags.add(
                .residue_version,
                .warning,
                .{ .start = 0, .end = 0 },
                "the TMPU chunk is envelope version {d} (this build reads {d}); it stays in the " ++
                    "file and the message tail is read instead",
                .{ v, records.version },
            ),
            .corrupt => |code| try diags.add(
                code,
                .warning,
                .{ .start = 0, .end = 0 },
                "the TMPU chunk's framing does not hold; the message tail is read instead",
                .{},
            ),
        }
    }

    const split = splitMessage(message);
    if (split.tail) |text| {
        try diags.add(
            .residue_partial,
            .warning,
            .{ .start = 0, .end = 0 },
            "only the message tail was readable: it carries the timeline's shape — sections, " ++
                "cues, lane declarations, pass-through controls — and no native content and no " ++
                "records, so every rendered lane stays bound",
            .{},
        );
        return .{ .tail = text };
    }
    return .none;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const Schema = @import("../Schema.zig");
const fromSjon = @import("../doc/fromSjon.zig");
const itf = @import("../itf/itf.zig");
const itf_read = @import("../itf/read.zig");
const itf_write = @import("../itf/write.zig");

const example_source =
    \\(timeline :title "impulsos" :length 16bar :end loop :conductor song)
    \\
    \\(anchor :id song :kind it :file "impulse-04.it" :size 1284403 :sha256 "9f2a")
    \\
    \\(section :name intro :at 0bar :dur 4bar)
    \\(cue :name "bar 9" :at 8bar)
    \\
    \\(lane :name kick :kind notes :from song :channel 3 :target drums)
    \\(lane :name bass-vol :kind curve :from song :channel 5 :column vol :range [0 1])
    \\(lane :name flash :kind notes :target flash
    \\  (note :at 0q :dur 0.5q :key 36 :vel 110))
    \\
    \\(control :id glow-amt :type slider :min 0 :max 1 :value 0.5 :target glow-amt)
    \\
;

/// The example, loaded with NO resolver — these tests are about the
/// carriers and not about the file.
///
/// `anchor_unavailable` is expected and skipped over: the example is
/// conducted by an anchor whose file nobody here hands over, so the load
/// says (correctly, since plan 03's C1 fix) that every position is the
/// placeholder's. That is the document's condition and not a defect of
/// the tail, the chunk or the budget these tests pin. Every OTHER error
/// still fails the test.
fn loadExample(gpa: Allocator, schema: *const Schema, source: [:0]const u8) !fromSjon.Result {
    var res = try fromSjon.fromSource(gpa, schema, source, null);
    errdefer res.deinit();
    var unexpected = false;
    for (res.diags.items()) |d| {
        if (d.severity != .err or d.code == .anchor_unavailable) continue;
        std.debug.print("  {t}: {s}\n", .{ d.code, d.message });
        unexpected = true;
    }
    if (unexpected) return error.UnexpectedDiagnostics;
    return res;
}

test "it: the chunk is the record list, framed, in plan 04's order" {
    const gpa = testing.allocator;

    const lane = try records.encodeLane(gpa, .{
        .lane = "kick",
        .address = .{ .it = .{ .channel = 2, .column = null, .fx = null } },
        .hash = @splat(0x33),
    });
    defer gpa.free(lane);
    const conductor = records.encodeConductor(.{ .hash = @splat(0x44) });

    const bytes = try chunk(gpa, .{
        .essence = "ESSENCE",
        .conductor = &conductor,
        .lanes = &.{lane},
    });
    defer gpa.free(bytes);

    // Record one: the essence.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7D, 0x74, 0x65, 0x6D, 1, 1, 0, 1 }, bytes[0..8]);
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, bytes[8..12], .little));
    try testing.expectEqualStrings("ESSENCE", bytes[12..19]);
    // Then the lane record, then the conductor's.
    try testing.expectEqual(@as(u8, 2), bytes[19 + 5]);
    const after_lane = 19 + 12 + lane.len;
    try testing.expectEqual(@as(u8, 3), bytes[after_lane + 5]);
    try testing.expectEqual(bytes.len, after_lane + 12 + conductor.len);

    var got = try parseChunk(gpa, bytes);
    defer got.deinit();
    try testing.expectEqualStrings("ESSENCE", got.ok.payloads.essence.?);
    try testing.expectEqualSlices(u8, &conductor, got.ok.payloads.conductor.?);
    try testing.expectEqual(@as(usize, 1), got.ok.payloads.lanes.len);
    try testing.expectEqualSlices(u8, lane, got.ok.payloads.lanes[0]);
}

test "it: a chunk that does not frame is corrupt, and a newer ver is kept opaque" {
    const gpa = testing.allocator;
    const bytes = try chunk(gpa, .{ .essence = "ESSENCE" });
    defer gpa.free(bytes);

    for ([_][]const u8{
        bytes[0 .. bytes.len - 1], // a body cut short
        bytes[0..6], // not even a head
        "\x7Dpau\x01\x01\x00\x01\x00\x00\x00\x00", // somebody else's tag
    }) |bad| {
        var c = try parseChunk(gpa, bad);
        defer c.deinit();
        try testing.expectEqual(Diag.Code.residue_corrupt, c.corrupt);
    }

    // An empty chunk holds nothing and is not an error.
    var empty = try parseChunk(gpa, "");
    defer empty.deinit();
    try testing.expect(empty.ok.payloads.essence == null);

    // A record from a newer tempura: nothing this build can read.
    const newer = try gpa.dupe(u8, bytes);
    defer gpa.free(newer);
    newer[4] = records.version + 1;
    var v = try parseChunk(gpa, newer);
    defer v.deinit();
    try testing.expectEqual(@as(u8, records.version + 1), v.version);
}

test "it: the tail is the addressed summary, ASCII, CR newlines, marker first" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var res = try loadExample(gpa, &schema, example_source);
    defer res.deinit();

    var t = try tail(gpa, &res.doc, &res.map);
    defer t.deinit(gpa);
    try testing.expect(!t.diags.hasErrors());

    try testing.expect(std.mem.startsWith(u8, t.bytes, marker));
    try testing.expect(t.bytes.len <= tail_budget);
    for (t.bytes) |c| try testing.expect(c == newline or (c >= 0x20 and c < 0x7F));

    // What it carries: the header, the anchor the addresses name, the
    // windows, the points, every lane DECLARATION, the pass-through.
    for ([_][]const u8{
        "(timeline :title \"impulsos\" :length 16bar :end loop :conductor song)",
        "(anchor :id song :kind it :file \"self\")",
        "(section :name intro :at 0bar :dur 4bar)",
        "(cue :name \"bar 9\" :at 8bar)",
        "(lane :name kick :kind notes :target drums :from song :channel 3)",
        "(lane :name bass-vol :kind curve :from song :channel 5 :column vol :range [0 1])",
        "(lane :name flash :kind notes)",
        "(control :id glow-amt",
    }) |needle| {
        if (std.mem.indexOf(u8, t.bytes, needle) == null) {
            std.debug.print("tail:\n{s}\n missing: {s}\n", .{ t.bytes, needle });
            return error.TailMissingForm;
        }
    }

    // …and what it does not: no native content, no phrases, no records.
    try testing.expect(std.mem.indexOf(u8, t.bytes, "(note ") == null);
    try testing.expect(std.mem.indexOf(u8, t.bytes, "(phrase ") == null);
    try testing.expect(std.mem.indexOf(u8, t.bytes, "impulse-04.it") == null);
    try testing.expect(std.mem.indexOf(u8, t.bytes, "\n") == null);

    // It reads back as a document: the shape of the piece, no content.
    const source = try parseTail(gpa, t.bytes);
    defer gpa.free(source);
    var back = try loadExample(gpa, &schema, source);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 3), back.doc.lanes.len);
    try testing.expectEqual(@as(usize, 1), back.doc.sections.len);
    try testing.expectEqual(@as(usize, 1), back.doc.cues.len);
    try testing.expectEqual(@as(usize, 1), back.doc.passthrough.len);
    try testing.expectEqual(@as(usize, 0), back.doc.lanes[2].notes.len);
    try testing.expectEqualStrings(essence.self_file, back.doc.anchorById("song").?.file);
}

test "it: a name that is not ASCII is percent-escaped and reported" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    const source =
        \\(timeline :title "impulsos — cinco")
        \\(tempo-point :at 0q :qpm 125)
        \\(meter-point :at 0bar :sig [4 4])
        \\(cue :name "café" :at 0bar)
        \\
    ;
    var res = try loadExample(gpa, &schema, source);
    defer res.deinit();

    var t = try tail(gpa, &res.doc, &res.map);
    defer t.deinit(gpa);

    for (t.bytes) |c| try testing.expect(c == newline or (c >= 0x20 and c < 0x7F));
    try testing.expect(std.mem.indexOf(u8, t.bytes, "caf%C3%A9") != null);
    try testing.expect(std.mem.indexOf(u8, t.bytes, "impulsos %E2%80%94 cinco") != null);
    try testing.expectEqual(@as(usize, 2), t.diags.count(.it_message_encoding_lossy));
}

test "it: the 4096 budget drops whole lines and says what fell off" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    // Enough sections to run past the budget on their own.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(
        gpa,
        "(timeline :title \"big\" :conductor song)\n(anchor :id song :kind it :file \"big.it\")\n",
    );
    for (0..200) |i| {
        var line: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(
            &line,
            "(section :name s{d} :at {d}bar :dur 1bar)\n",
            .{ i, i },
        );
        try src.appendSlice(gpa, text);
    }
    const source = try src.toOwnedSliceSentinel(gpa, 0);
    defer gpa.free(source);

    var res = try loadExample(gpa, &schema, source);
    defer res.deinit();

    var t = try tail(gpa, &res.doc, &res.map);
    defer t.deinit(gpa);

    try testing.expect(t.bytes.len <= tail_budget);
    try testing.expectEqual(@as(usize, 1), t.diags.count(.residue_tail_truncated));
    // Whole lines: the tail never ends mid-form.
    try testing.expectEqual(newline, t.bytes[t.bytes.len - 1]);
    // What survived still reads.
    const back_src = try parseTail(gpa, t.bytes);
    defer gpa.free(back_src);
    var back = try loadExample(gpa, &schema, back_src);
    defer back.deinit();
    try testing.expect(back.doc.sections.len > 0);
    try testing.expect(back.doc.sections.len < 200);
}

test "it: splitMessage finds the marker, and a message without one is all human" {
    const human = "a song about the sea";
    const with = human ++ "\r" ++ marker ++ "\r(timeline)";

    const split = splitMessage(with);
    try testing.expectEqualStrings(human, split.human);
    try testing.expectEqualStrings(marker ++ "\r(timeline)", split.tail.?);

    const none = splitMessage(human);
    try testing.expectEqualStrings(human, none.human);
    try testing.expect(none.tail == null);

    // A message that IS a tail, and a `;; tempura` that does not start a
    // line (part of the human text, not a marker).
    const only = splitMessage(marker ++ "\r(timeline)");
    try testing.expectEqualStrings("", only.human);
    try testing.expectEqualStrings(marker ++ "\r(timeline)", only.tail.?);
    const inline_marker = splitMessage("see ;; tempura for more");
    try testing.expect(inline_marker.tail == null);
}

test "it: the chunk wins, the tail is the fallback, and residue_partial names the loss" {
    const gpa = testing.allocator;
    const bytes = try chunk(gpa, .{ .essence = "ESSENCE" });
    defer gpa.free(bytes);
    const message = "a song\r" ++ marker ++ "\r(timeline :title \"x\")";

    // Both present: the chunk wins and nothing is reported.
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();
    var won = try choose(gpa, bytes, message, &diags);
    defer won.deinit();
    try testing.expectEqualStrings("ESSENCE", won.chunk.payloads.essence.?);
    try testing.expectEqual(@as(usize, 0), diags.items().len);

    // No chunk: the tail, and the loss named.
    var only_tail = try choose(gpa, null, message, &diags);
    defer only_tail.deinit();
    try testing.expect(std.mem.startsWith(u8, only_tail.tail, marker));
    try testing.expectEqual(@as(usize, 1), diags.count(.residue_partial));

    // A corrupt chunk falls back to the tail, and says both things.
    var broken = try choose(gpa, bytes[0..6], message, &diags);
    defer broken.deinit();
    try testing.expect(broken == .tail);
    try testing.expectEqual(@as(usize, 1), diags.count(.residue_corrupt));

    // Neither: nothing at all, and no new complaint about the tail.
    const before = diags.count(.residue_partial);
    var nothing = try choose(gpa, null, "just a song", &diags);
    defer nothing.deinit();
    try testing.expect(nothing == .none);
    try testing.expectEqual(before, diags.count(.residue_partial));
}

test "it: chunk → write → read → parse, the whole carrier round trip" {
    // The corpus case `residue-it-exact` (plan 04, phase 4's gate), held
    // as a unit test until the runner learns `(build)` / `(dump)`.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var res = try loadExample(gpa, &schema, example_source);
    defer res.deinit();

    var packed_essence = try essence.pack(gpa, &res.doc, example_source);
    defer packed_essence.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), packed_essence.diags.items().len);
    const payload = try chunk(gpa, .{ .essence = packed_essence.bytes });
    defer gpa.free(payload);
    var t = try tail(gpa, &res.doc, &res.map);
    defer t.deinit(gpa);

    var b: itf.Builder = .init(gpa);
    errdefer b.deinit();
    _ = try b.addPattern(64);
    try b.addOrder(0);
    try b.setMessage("a song about the sea");
    var module = b.finish();
    defer module.deinit();

    // `appendTail` is what puts the CR in: a marker mid-line is a marker
    // `splitMessage` never finds.
    const whole = try appendTail(gpa, module.message, t.bytes);
    defer gpa.free(whole);
    var file = try itf_write.write(gpa, &module, null, .{
        .tmpu = payload,
        .message_tail = whole[module.message.len..],
    });
    defer file.deinit();
    try testing.expect(!file.diags.hasErrors());

    var back = try itf_read.read(gpa, file.bytes);
    defer back.deinit();
    try testing.expect(!back.diags.hasErrors());

    // Both carriers came through the file, the chunk under its 4CC.
    try testing.expect(std.mem.indexOf(u8, file.bytes, tag) != null);
    const chunk_bytes = back.module.tmpu.?.slice(file.bytes).?;
    var diags: Diag.List = .init(gpa);
    defer diags.deinit();
    var chosen = try choose(gpa, chunk_bytes, back.module.message, &diags);
    defer chosen.deinit();
    try testing.expectEqualSlices(u8, packed_essence.bytes, chosen.chunk.payloads.essence.?);

    const split = splitMessage(back.module.message);
    try testing.expectEqualStrings("a song about the sea", split.human);
    try testing.expectEqualStrings(t.bytes, split.tail.?);

    // And the essence is the document again, form for form.
    var unpacked = try essence.unpack(gpa, chosen.chunk.payloads.essence.?);
    defer unpacked.deinit(gpa);
    var again = try loadExample(gpa, &schema, unpacked.ok.text);
    defer again.deinit();
    try testing.expectEqual(res.doc.lanes.len, again.doc.lanes.len);
    try testing.expectEqual(@as(usize, 1), again.doc.lanes[2].notes.len);
}

test "it: a chunk that breaks AFTER a record frees what it had taken" {
    // The leak this closes: `.corrupt` is a returned VALUE, so the
    // `errdefer` on the arena never fired, and by then a record had
    // already been duped into it. `std.testing.allocator` is the
    // assertion.
    const gpa = testing.allocator;
    const good = try chunk(gpa, .{ .essence = "ESSENCE" });
    defer gpa.free(good);

    const with_rubbish = try std.mem.concat(gpa, u8, &.{ good, "\x7Dtem\x01" });
    defer gpa.free(with_rubbish);

    var broken = try parseChunk(gpa, with_rubbish);
    defer broken.deinit();
    try testing.expectEqual(Diag.Code.residue_corrupt, broken.corrupt);

    // The same, one record further in: a lane record duped, then a head
    // that promises a length the chunk does not have.
    const lane = try records.encodeLane(gpa, .{
        .lane = "kick",
        .address = .{ .it = .{ .channel = 0, .column = null, .fx = null } },
        .hash = @splat(1),
    });
    defer gpa.free(lane);
    const two = try chunk(gpa, .{ .essence = "ESSENCE", .lanes = &.{lane} });
    defer gpa.free(two);
    const cut = try gpa.dupe(u8, two[0 .. two.len - 3]);
    defer gpa.free(cut);

    var short = try parseChunk(gpa, cut);
    defer short.deinit();
    try testing.expectEqual(Diag.Code.residue_corrupt, short.corrupt);
}

test "it: parseTail undoes the %XX escaping, in a string and in a symbol" {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    // Spelled as bytes, because a SJON source file carries UTF-8 raw and
    // this test is about what happens to those bytes.
    const utf8 =
        "(timeline :title \"50% caf\xC3\xA9\" :conductor song)\n" ++
        "(anchor :id song :kind it :file \"x.it\")\n" ++
        "(cue :name \"caf\xC3\xA9\" :at 0bar)\n";
    var res = try loadExample(gpa, &schema, utf8);
    defer res.deinit();

    var t = try tail(gpa, &res.doc, &res.map);
    defer t.deinit(gpa);
    for (t.bytes) |c| try testing.expect(c == newline or (c >= 0x20 and c < 0x7F));
    try testing.expect(std.mem.indexOf(u8, t.bytes, "50%25 caf%C3%A9") != null);

    // …and back: the bytes the author wrote, not the escaping.
    const back_src = try parseTail(gpa, t.bytes);
    defer gpa.free(back_src);
    try testing.expect(std.mem.indexOf(u8, back_src, "50% caf\xC3\xA9") != null);

    var back = try loadExample(gpa, &schema, back_src);
    defer back.deinit();
    try testing.expectEqualStrings("50% caf\xC3\xA9", back.doc.title.?);
    try testing.expectEqualStrings("caf\xC3\xA9", back.doc.cues[0].name);
}

test "it: appendTail puts the marker at the start of a line, whatever the message" {
    const gpa = testing.allocator;
    const text = marker ++ "\r(timeline :title \"x\")";

    for ([_][]const u8{ "", "a song", "a song\r", "a song\n" }) |message| {
        const whole = try appendTail(gpa, message, text);
        defer gpa.free(whole);
        const split = splitMessage(whole);
        try testing.expect(split.tail != null);
        try testing.expectEqualStrings(text, split.tail.?);
        // The human half is the message, its own trailing newline gone.
        try testing.expect(std.mem.startsWith(u8, message, split.human));
    }
}

test "it.chunk: every allocation failure is OutOfMemory, cleanly, with nothing leaked" {
    // Goal: prove the errdefer discipline behind "an owned struct with
    // arena-backed deinit": at EVERY allocation index the call fails with
    // error.OutOfMemory and testing.allocator sees no leak; past the last
    // index it succeeds. Bounded by the number of allocations the call
    // makes, which the loop discovers.
    const gpa = testing.allocator;
    const lane = try records.encodeLane(gpa, .{
        .lane = "kick",
        .address = .{ .it = .{ .channel = 2, .column = null, .fx = null } },
        .hash = @splat(0x33),
    });
    defer gpa.free(lane);
    const conductor = records.encodeConductor(.{ .hash = @splat(0x44) });

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const result = chunk(failing.allocator(), .{
            .essence = "ESSENCE",
            .conductor = &conductor,
            .lanes = &.{lane},
        });
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const bytes = try result;
            failing.allocator().free(bytes);
            break;
        }
    }
}

test "it.parseChunk: every allocation failure is OutOfMemory, cleanly, with nothing leaked" {
    // Goal: prove the errdefer discipline behind "an owned struct with
    // arena-backed deinit": at EVERY allocation index the call fails with
    // error.OutOfMemory and testing.allocator sees no leak; past the last
    // index it succeeds. Bounded by the number of allocations the call
    // makes, which the loop discovers.
    const gpa = testing.allocator;
    const lane = try records.encodeLane(gpa, .{
        .lane = "kick",
        .address = .{ .it = .{ .channel = 2, .column = null, .fx = null } },
        .hash = @splat(0x33),
    });
    defer gpa.free(lane);
    const conductor = records.encodeConductor(.{ .hash = @splat(0x44) });
    const bytes = try chunk(gpa, .{
        .essence = "ESSENCE",
        .conductor = &conductor,
        .lanes = &.{lane},
    });
    defer gpa.free(bytes);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const result = parseChunk(failing.allocator(), bytes);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var value = try result;
            defer value.deinit();
            try testing.expect(value == .ok);
            break;
        }
    }
}

test "it.tail: every allocation failure is OutOfMemory, cleanly, with nothing leaked" {
    // Goal: prove the errdefer discipline behind "an owned struct with
    // arena-backed deinit": at EVERY allocation index the call fails with
    // error.OutOfMemory and testing.allocator sees no leak; past the last
    // index it succeeds. Bounded by the number of allocations the call
    // makes, which the loop discovers.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    var res = try loadExample(gpa, &schema, example_source);
    defer res.deinit();

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const result = tail(failing.allocator(), &res.doc, &res.map);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var value = try result;
            value.deinit(failing.allocator());
            break;
        }
    }
}
