//! The `midi/` bridge: a `Sequence` ⇄ the hosted SMF vocabulary.
//!
//! Plan 05, "The `midi/` bridge". One `(midi/smf :format :division)`
//! root and one `(midi/mtrk …)` per track, one form per event, spelled
//! exactly as the midi set's 02 says and as `schema/midi.sjon` types it:
//! heads are RP-001's names in kebab-case, `:ch` is 1..16 in text and
//! 0..15 on the wire, `:at` is the ABSOLUTE SMF tick, byte payloads are
//! hex strings and text payloads SJON strings when the bytes are valid
//! UTF-8.
//!
//! A SMPTE division is printed as the grid it converted to, and every
//! `set-tempo` on that grid as 500 000 µs — the tempo the conversion
//! assumed (`smf.Division.tempoOnGrid`, the one seam beside
//! `pulsesPerQuarter`). The `Sequence` keeps the event as read; the dump
//! is the first place the file's ticks are BELIEVED on a musical grid,
//! so it is the first place the tempo has to be the grid's own, or a
//! `tempura build` of the dump would conduct a wall-clock file at a
//! tempo it never had. The `; smpte …` note beside the header says how
//! many events were rewritten.
//!
//! Above the text sit the two derivations a BOUND lane needs: note
//! pairing (`pairNotes`) and controller steps (`curveSteps`). Neither
//! writes anything back — a bound lane's content lives in the file
//! (plan 04, "One home").
//!
//! **What the manifest says, this file does not re-say.** The 7-bit and
//! 14-bit ranges, `set-tempo :us` 1..16 777 215, `:ch` 1..16: every one
//! of them is a `(value-kind …)` in `schema/midi.sjon` with its own
//! numeric bounds, so a document that breaks one is refused at
//! validation and rides across as `sjon_diagnostic` — the split
//! `fromSjon.zig`'s header states. The readers here are TOTAL and
//! saturate, exactly as that file's casts do, so an unvalidated tree
//! still lowers without trapping.

const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("../Diag.zig");
const Doc = @import("Value.zig");
const Schema = @import("../Schema.zig");
const smf = @import("../smf/smf.zig");

const Ast = sjon.Ast;
const NodeIndex = Ast.NodeIndex;
const Allocator = std.mem.Allocator;
/// The note payload the core keeps behind `Payload.note`, named here for
/// the pairing's helpers.
const Note = smf.Note;
const testing = std.testing;

/// Explicit error set: only resource exhaustion. Every defect of a
/// document or of a sequence is a diagnostic on a returned value.
pub const Error = error{OutOfMemory};

/// The printer's switches.
pub const Options = struct {
    /// Whether the two global heads carry their tier's namespace
    /// (`(midi/smf …)` rather than `(smf …)`). Qualified is the default:
    /// it is the spelling that survives composition with midivia's full
    /// manifest (plan 02, "The `note` collision with midivia"). The
    /// EVENT heads are slot-local to `(mtrk …)` and are never qualified
    /// — a namespace on one would name a global form that does not
    /// exist.
    qualify: bool = true,
};

// ---------------------------------------------------------------------
// Sequence → forms
// ---------------------------------------------------------------------

/// The `(midi/smf …)` + `(midi/mtrk …)` text of `seq`, owned by the
/// caller.
///
/// `source_map` is the reader's, when there was one: its only use here
/// is the SMPTE note, because a SMPTE division is never written back
/// (plan 05, "Chunks") and the dump would otherwise not say what the
/// file held. A hand-built sequence passes `null` and the note comes
/// from `seq.division` itself.
///
/// A SMPTE sequence's `set-tempo :us` is `tempoOnGrid`'s 500 000, not
/// the event's own number, and the note counts the events rewritten —
/// the same rule the canonical writer applies to the same bytes, so a
/// dump and a write of one file agree on what its grid means.
pub fn sequenceToForms(
    gpa: Allocator,
    seq: *const smf.Sequence,
    source_map: ?*const smf.SourceMap,
    opts: Options,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var p: Printer = .{ .gpa = gpa, .out = &out, .seq = seq, .opts = opts };
    try p.document(source_map);
    return out.toOwnedSlice(gpa);
}

/// The head each `Kind` is spelled with — RP-001's name in kebab-case
/// (midi 02, "The file document, core tier").
///
/// Three kinds share one head. `meta_unknown` is `meta`, the vocabulary's
/// escape hatch for a type it does not name. `ease_hint` and
/// `tempura_residue` are `sequencer-specific`, the `FF 7F` event they
/// both ARE: the manifest hosts midivia's `(ease-hint …)` for the
/// typed spelling of one, and DECODING that payload into pacer's easing
/// vocabulary is plan 08's work (the reader keeps its body as bytes for
/// exactly that reason). Until then both dump as the hex they are, which
/// is byte-exact in both directions.
fn headName(kind: smf.Kind) []const u8 {
    return switch (kind) {
        .note_off => "note-off",
        .note_on => "note-on",
        .poly_pressure => "poly-pressure",
        .control_change => "control-change",
        .program_change => "program-change",
        .channel_pressure => "channel-pressure",
        .pitch_bend => "pitch-bend",
        .sysex => "sysex",
        .escape => "escape",
        .sequence_number => "sequence-number",
        .text_event => "text-event",
        .copyright_notice => "copyright-notice",
        .sequence_name => "sequence-name",
        .instrument_name => "instrument-name",
        .lyric => "lyric",
        .marker => "marker",
        .cue_point => "cue-point",
        .program_name => "program-name",
        .device_name => "device-name",
        .midi_channel_prefix => "midi-channel-prefix",
        .midi_port => "midi-port",
        .end_of_track => "end-of-track",
        .set_tempo => "set-tempo",
        .smpte_offset => "smpte-offset",
        .time_signature => "time-signature",
        .key_signature => "key-signature",
        .sequencer_specific, .ease_hint, .tempura_residue => "sequencer-specific",
        .meta_unknown => "meta",
    };
}

/// The `Kind` a head names, or null. The inverse of `headName` for the
/// heads that have one: `sequencer-specific` reads back as the plain
/// kind and `smf.classifySequencerSpecific` re-types it from the payload,
/// which is what the READER does with the same bytes.
fn kindOfHead(head: []const u8) ?smf.Kind {
    inline for (@typeInfo(smf.Kind).@"enum".fields) |f| {
        const kind: smf.Kind = @enumFromInt(f.value);
        switch (kind) {
            .ease_hint, .tempura_residue => {},
            else => if (std.mem.eql(u8, head, headName(kind))) return kind,
        }
    }
    return null;
}

const Printer = struct {
    gpa: Allocator,
    out: *std.ArrayList(u8),
    seq: *const smf.Sequence,
    opts: Options,

    fn document(self: *Printer, source_map: ?*const smf.SourceMap) Error!void {
        try self.raw("(");
        try self.qualified("smf");
        try self.raw(" :format ");
        try self.int(self.seq.format);
        try self.raw(" :division ");
        try self.int(self.seq.division.pulsesPerQuarter());
        try self.raw(")");
        // A SMPTE division is converted on read and never written back
        // (plan 05, "Chunks"), so the dump says what the file held —
        // midi 02's own `; smpte 25 fps × 40` note — and how many
        // `set-tempo` events `event()` spelled as the grid's 500 000 µs
        // rather than their own number, so a reader of the dump knows
        // the tier was rewritten to keep the clock, not authored so.
        const smpte = if (source_map) |m| m.smpte else null;
        if (smpte) |s| {
            try self.smpteNote(s.fps, s.tpf);
        } else switch (self.seq.division) {
            .smpte => |s| try self.smpteNote(s.fps, s.tpf),
            .ppq => {},
        }
        try self.raw("\n");

        for (self.seq.tracks) |track| {
            try self.raw("\n(");
            try self.qualified("mtrk");
            for (track.events) |e| {
                try self.raw("\n  ");
                try self.event(e);
            }
            try self.raw(")\n");
        }
    }

    fn smpteNote(self: *Printer, fps: u8, tpf: u8) Error!void {
        try self.raw(" ; smpte ");
        try self.int(fps);
        try self.raw(" fps × ");
        try self.int(tpf);
        // The count is of what THIS printer rewrote, which keys on the
        // sequence's own division exactly as `event()` does — a source
        // map that says SMPTE over a PPQ sequence (which the reader never
        // produces) would note the conversion and count nothing.
        const rewritten = self.rewrittenTempos();
        if (rewritten == 0) return;
        try self.raw(", ");
        try self.int(rewritten);
        try self.raw(" set-tempo rewritten to ");
        try self.int(smf.Division.smpte_tempo_us);
        try self.raw(" µs on the converted grid");
    }

    /// How many `set-tempo` events `event()` will spell as the grid's
    /// tempo rather than their own: every one, for a SMPTE sequence;
    /// none otherwise.
    fn rewrittenTempos(self: *const Printer) usize {
        if (self.seq.division != .smpte) return 0;
        var n: usize = 0;
        for (self.seq.tracks) |track| {
            for (track.events) |e| {
                if (e.kind == .set_tempo) n += 1;
            }
        }
        return n;
    }

    /// A GLOBAL head, with the tier's namespace when asked for. The event
    /// heads are slot-local to `(mtrk …)` and never take one.
    fn qualified(self: *Printer, head: []const u8) Error!void {
        if (self.opts.qualify) try self.raw("midi/");
        try self.raw(head);
    }

    fn event(self: *Printer, e: smf.Event) Error!void {
        try self.raw("(");
        try self.raw(headName(e.kind));
        try self.raw(" :at ");
        try self.int(e.at);
        switch (e.kind) {
            .note_off,
            .note_on,
            .poly_pressure,
            .control_change,
            .program_change,
            .channel_pressure,
            .pitch_bend,
            => try self.channelKeys(e),
            .sysex,
            .escape,
            .sequencer_specific,
            .ease_hint,
            .tempura_residue,
            .meta_unknown,
            => try self.bytesKeys(e),
            .text_event,
            .copyright_notice,
            .sequence_name,
            .instrument_name,
            .lyric,
            .marker,
            .cue_point,
            .program_name,
            .device_name,
            => try self.textOrBytes(self.seq.bytesOf(e.payload.bytes)),
            .sequence_number,
            .midi_channel_prefix,
            .midi_port,
            .end_of_track,
            .set_tempo,
            .smpte_offset,
            .time_signature,
            .key_signature,
            => try self.metaKeys(e),
        }
        try self.raw(")");
    }

    /// The keys of a channel event: its `:ch`, then what the kind
    /// carries. Called for the seven channel kinds only.
    fn channelKeys(self: *Printer, e: smf.Event) Error!void {
        switch (e.kind) {
            .note_off, .note_on => {
                const n = e.payload.note;
                try self.channel(n.ch);
                try self.key(" :key ", n.key);
                try self.key(" :vel ", n.vel);
            },
            .poly_pressure => {
                const n = e.payload.poly;
                try self.channel(n.ch);
                try self.key(" :key ", n.key);
                try self.key(" :val ", n.val);
            },
            .control_change => {
                const n = e.payload.control;
                try self.channel(n.ch);
                try self.key(" :num ", n.num);
                try self.key(" :val ", n.val);
            },
            .program_change => {
                const n = e.payload.program;
                try self.channel(n.ch);
                try self.key(" :num ", n.num);
            },
            .channel_pressure => {
                const n = e.payload.pressure;
                try self.channel(n.ch);
                try self.key(" :val ", n.val);
            },
            .pitch_bend => {
                const n = e.payload.bend;
                try self.channel(n.ch);
                try self.raw(" :val ");
                try self.int(n.value);
            },
            else => unreachable,
        }
    }

    /// The keys of an event whose payload is bytes: `:data` as hex, and
    /// an unknown meta's `:type` ahead of it. Called for those six kinds
    /// only.
    fn bytesKeys(self: *Printer, e: smf.Event) Error!void {
        switch (e.kind) {
            .sysex, .escape, .sequencer_specific, .ease_hint => {
                try self.raw(" :data ");
                try self.hex(self.seq.bytesOf(e.payload.bytes));
            },
            .tempura_residue => {
                // The envelope, rebuilt: the four header bytes live in
                // the payload and the body in the pool, and the hex is
                // the whole `FF 7F` payload the file carried.
                const r = e.payload.residue;
                const body = self.seq.bytesOf(r.body);
                const head = smf.residueHead(r);
                try self.raw(" :data ");
                try self.hexTwo(&head, body);
            },
            .meta_unknown => {
                try self.raw(" :type 0x");
                try self.hexByte(e.payload.meta.meta_type);
                try self.raw(" :data ");
                try self.hex(self.seq.bytesOf(e.payload.meta.bytes));
            },
            else => unreachable,
        }
    }

    /// The keys of a structured meta event. Called for those eight
    /// kinds only.
    fn metaKeys(self: *Printer, e: smf.Event) Error!void {
        switch (e.kind) {
            .sequence_number => {
                try self.raw(" :num ");
                try self.int(e.payload.number);
            },
            // RP-001's channel prefix is 0..15 and the manifest's `:ch`
            // is 1..16, so a byte past 15 — which only a malformed file
            // holds — saturates and does not read back as itself.
            .midi_channel_prefix => try self.channel(@min(e.payload.byte, 15)),
            .midi_port => {
                try self.raw(" :port ");
                try self.int(e.payload.byte);
            },
            .end_of_track => {},
            .set_tempo => {
                // The grid's tempo, not the event's: on a converted SMPTE
                // grid that is 500 000 whatever the file said, or the
                // dump would conduct wall-clock ticks at a tempo their
                // grid was never derived for (`Division.tempoOnGrid`).
                try self.raw(" :us ");
                try self.int(self.seq.division.tempoOnGrid(e.payload.tempo));
            },
            .smpte_offset => {
                const s = e.payload.smpte;
                try self.key(" :hr ", s.hr);
                try self.key(" :mn ", s.mn);
                try self.key(" :se ", s.se);
                try self.key(" :fr ", s.fr);
                try self.key(" :ff ", s.ff);
            },
            .time_signature => {
                const t = e.payload.time_sig;
                try self.key(" :num ", t.nn);
                try self.raw(" :denom ");
                // RP-001 writes the denominator as its power of two; the
                // manifest writes the number it is. 128 is the largest
                // the kind admits, so a `dd` past 7 saturates there.
                try self.int(@as(u16, if (t.dd < 8) @as(u16, 1) << @intCast(t.dd) else 128));
                try self.key(" :clocks ", t.cc);
                try self.key(" :thirty-seconds ", t.bb);
            },
            .key_signature => {
                const k = e.payload.key_sig;
                try self.raw(" :sf ");
                try self.int(k.sf);
                try self.key(" :mi ", k.mi);
            },
            else => unreachable,
        }
    }

    /// `:ch` is 1..16 in text and 0..15 on the wire (midi 02).
    fn channel(self: *Printer, wire: u8) Error!void {
        try self.raw(" :ch ");
        try self.int(@as(u16, wire) + 1);
    }

    fn key(self: *Printer, name: []const u8, value: anytype) Error!void {
        try self.raw(name);
        try self.int(value);
    }

    /// A text meta's payload: an SJON string when the bytes are valid
    /// UTF-8, `:bytes` hex otherwise (midi 02; plan 05's encoding risk —
    /// storing bytes and rendering UTF-8 when valid is lossless).
    fn textOrBytes(self: *Printer, bytes: []const u8) Error!void {
        if (std.unicode.utf8ValidateSlice(bytes)) {
            try self.raw(" :text ");
            try sjon.StringEscape.appendQuoted(self.out, self.gpa, bytes);
        } else {
            try self.raw(" :bytes ");
            try self.hex(bytes);
        }
    }

    /// A byte payload as hex: two digits per byte, one space between.
    fn hex(self: *Printer, bytes: []const u8) Error!void {
        try self.hexTwo(bytes, &.{});
    }

    fn hexTwo(self: *Printer, a: []const u8, b: []const u8) Error!void {
        try self.raw("\"");
        var first = true;
        for ([_][]const u8{ a, b }) |run| {
            for (run) |byte| {
                if (!first) try self.raw(" ");
                first = false;
                try self.hexByte(byte);
            }
        }
        try self.raw("\"");
    }

    fn hexByte(self: *Printer, byte: u8) Error!void {
        var buf: [2]u8 = undefined;
        // `{X:0>2}` of a u8 is exactly two digits, and the buffer is two.
        _ = std.fmt.bufPrint(&buf, "{X:0>2}", .{byte}) catch unreachable;
        try self.raw(&buf);
    }

    fn raw(self: *Printer, text: []const u8) Error!void {
        return self.out.appendSlice(self.gpa, text);
    }

    fn int(self: *Printer, v: anytype) Error!void {
        var buf: [32]u8 = undefined;
        // The widest integer printed here is an i64 tick: a sign and 19
        // digits, 20 bytes, into 32.
        const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
        return self.raw(text);
    }
};

// ---------------------------------------------------------------------
// Forms → Sequence
// ---------------------------------------------------------------------

/// What `formsToSequence` returns: the sequence and the report.
pub const Read = struct {
    sequence: smf.Sequence,
    diags: Diag.List,

    pub fn deinit(self: *Read) void {
        self.sequence.deinit();
        self.diags.deinit();
    }
};

/// The inverse of `sequenceToForms` over a validated tree.
///
/// `roots` is the dump in document order: the `(midi/smf …)` form and
/// the `(midi/mtrk …)` forms that follow it. The walk is total — a form
/// this vocabulary does not name is skipped, and a missing key reads as
/// its zero.
pub fn formsToSequence(gpa: Allocator, tree: *const Ast.Tree, roots: []const NodeIndex) Error!Read {
    var b: smf.Builder = .init(gpa);
    errdefer b.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);

    var r: Reader = .{ .gpa = gpa, .tree = tree, .b = &b, .diags = &diags, .scratch = &scratch };
    try r.document(roots);
    return .{ .sequence = try b.finish(), .diags = diags };
}

const Reader = struct {
    gpa: Allocator,
    tree: *const Ast.Tree,
    b: *smf.Builder,
    diags: *Diag.List,
    /// One reusable buffer for decoded hex, copied into the pool by
    /// `addBytes` before the next use.
    scratch: *std.ArrayList(u8),

    fn document(self: *Reader, roots: []const NodeIndex) Error!void {
        for (roots) |idx| {
            if (self.tree.tagOf(idx) != .form) continue;
            const hdr = self.tree.formHeader(idx);
            if (hdr.namespace) |ns| {
                if (!std.mem.eql(u8, ns, "midi")) continue;
            }
            if (std.mem.eql(u8, hdr.head, "smf")) {
                self.b.format = castInt(u8, kvNumber(self.tree, hdr.children, "format"), 1);
                const ppq = castInt(u15, kvNumber(self.tree, hdr.children, "division"), 480);
                self.b.division = .{ .ppq = ppq };
            } else if (std.mem.eql(u8, hdr.head, "mtrk")) {
                try self.track(idx);
            }
        }
    }

    fn track(self: *Reader, form: NodeIndex) Error!void {
        const index = try self.b.addTrack();
        const children = self.tree.formHeader(form).children;

        var last_at: i64 = 0;
        var count: usize = 0;
        var last_kind: ?smf.Kind = null;
        for (children) |child| {
            if (self.tree.tagOf(child) != .form) continue;
            const kind = kindOfHead(self.tree.formHeader(child).head) orelse continue;
            // `smf-tick` is `:min 0` in the manifest, so a negative `:at`
            // is already refused; lowered anyway, it floors at 0, which
            // keeps every tick a bound lane pairs and converts inside
            // `[0, maxInt(i64)]` — the one range whose differences fit.
            const at = @max(0, castInt(
                i64,
                kvNumber(self.tree, self.tree.formHeader(child).children, "at"),
                0,
            ));

            if (count > 0 and at < last_at) try self.diags.add(
                .at_not_monotone,
                .err,
                spanOf(self.tree, child),
                "this event sits at tick {d}, behind the {d} before it; a track's ticks never " ++
                    "step back",
                .{ at, last_at },
            );
            // An end-of-track that is not the last event: the one the
            // writer refuses to place (plan 05, the canonical writer).
            if (last_kind == .end_of_track) try self.diags.add(
                .end_of_track_early,
                .err,
                spanOf(self.tree, child),
                "an (end-of-track …) already closed this track",
                .{},
            );

            try self.event(index, child, kind, at);
            last_at = at;
            last_kind = kind;
            count += 1;
        }

        if (last_kind != .end_of_track) try self.diags.add(
            .end_of_track_missing,
            .err,
            spanOf(self.tree, form),
            "every track ends with an (end-of-track …)",
            .{},
        );
    }

    fn event(self: *Reader, track_index: u32, form: NodeIndex, kind: smf.Kind, at: i64) Error!void {
        const tree = self.tree;
        const children = tree.formHeader(form).children;

        const payload: smf.Payload, const real: smf.Kind = switch (kind) {
            .note_off,
            .note_on,
            .poly_pressure,
            .control_change,
            .program_change,
            .channel_pressure,
            .pitch_bend,
            => .{ channelPayload(tree, children, kind), kind },
            .sysex, .escape => .{ .{ .bytes = try self.hexBytes(children, "data") }, kind },
            .sequencer_specific => blk: {
                const raw = try self.decodeHex(children, "data");
                const run = try self.b.addBytes(raw);
                const c = smf.classifySequencerSpecific(raw, run);
                break :blk .{ c.payload, c.kind };
            },
            .text_event,
            .copyright_notice,
            .sequence_name,
            .instrument_name,
            .lyric,
            .marker,
            .cue_point,
            .program_name,
            .device_name,
            => .{ .{ .bytes = try self.textBytes(children) }, kind },
            .meta_unknown => .{ .{ .meta = .{
                .bytes = try self.hexBytes(children, "data"),
                .meta_type = castInt(u8, kvNumber(tree, children, "type"), 0),
            } }, kind },
            .sequence_number,
            .midi_channel_prefix,
            .midi_port,
            .end_of_track,
            .set_tempo,
            .smpte_offset,
            .time_signature,
            .key_signature,
            => .{ metaPayload(tree, children, kind), kind },
            // Never produced by `kindOfHead`: both spell
            // `sequencer-specific` and are re-typed from the payload.
            .ease_hint, .tempura_residue => unreachable,
        };
        try self.b.addEvent(track_index, at, real, payload);
    }

    /// `:text "…"` or `:bytes "hex"` — the exclusive pair every text meta
    /// carries.
    fn textBytes(self: *Reader, children: []const NodeIndex) Error!smf.Bytes {
        if (kvNode(self.tree, children, "text")) |node| {
            const text_node = self.tree.tagOf(node) == .string;
            if (text_node) return self.b.addBytes(self.tree.stringText(node));
        }
        return self.hexBytes(children, "bytes");
    }

    fn hexBytes(self: *Reader, children: []const NodeIndex, name: []const u8) Error!smf.Bytes {
        return self.b.addBytes(try self.decodeHex(children, name));
    }

    /// The decoded bytes of a hex string key, in the reader's scratch
    /// buffer — valid until the next call.
    fn decodeHex(self: *Reader, children: []const NodeIndex, name: []const u8) Error![]const u8 {
        self.scratch.clearRetainingCapacity();
        const node = kvNode(self.tree, children, name) orelse return &.{};
        if (self.tree.tagOf(node) != .string) return &.{};

        var high: ?u8 = null;
        for (self.tree.stringText(node)) |c| {
            const digit = std.fmt.charToDigit(c, 16) catch continue;
            if (high) |h| {
                try self.scratch.append(self.gpa, (h << 4) | digit);
                high = null;
            } else high = digit;
        }
        return self.scratch.items;
    }
};

/// Whose `FF 7F` payload is this? The reader's own rule
/// (`smf/read.zig`'s `sequencerSpecific`), restated so a dump read back
/// carries the same typed kinds the file did.
/// A channel event's payload from its keys, every number narrowed to
/// its byte with the kind's own fallback. For the seven channel kinds
/// only.
fn channelPayload(tree: *const Ast.Tree, children: []const NodeIndex, kind: smf.Kind) smf.Payload {
    return switch (kind) {
        .note_off, .note_on => .{ .note = .{
            .ch = wireChannel(tree, children),
            .key = castInt(u8, kvNumber(tree, children, "key"), 0),
            .vel = castInt(u8, kvNumber(tree, children, "vel"), 0),
        } },
        .poly_pressure => .{ .poly = .{
            .ch = wireChannel(tree, children),
            .key = castInt(u8, kvNumber(tree, children, "key"), 0),
            .val = castInt(u8, kvNumber(tree, children, "val"), 0),
        } },
        .control_change => .{ .control = .{
            .ch = wireChannel(tree, children),
            .num = castInt(u8, kvNumber(tree, children, "num"), 0),
            .val = castInt(u8, kvNumber(tree, children, "val"), 0),
        } },
        .program_change => .{ .program = .{
            .ch = wireChannel(tree, children),
            .num = castInt(u8, kvNumber(tree, children, "num"), 0),
        } },
        .channel_pressure => .{ .pressure = .{
            .ch = wireChannel(tree, children),
            .val = castInt(u8, kvNumber(tree, children, "val"), 0),
        } },
        .pitch_bend => .{ .bend = .{
            .ch = wireChannel(tree, children),
            .value = castInt(u16, kvNumber(tree, children, "val"), 8192),
        } },
        else => unreachable,
    };
}

/// A structured meta event's payload from its keys, with RP-001's
/// defaults where a key is absent. For those eight kinds only.
fn metaPayload(tree: *const Ast.Tree, children: []const NodeIndex, kind: smf.Kind) smf.Payload {
    return switch (kind) {
        .sequence_number => .{ .number = castInt(u16, kvNumber(tree, children, "num"), 0) },
        .midi_channel_prefix => .{ .byte = wireChannel(tree, children) },
        .midi_port => .{ .byte = castInt(u8, kvNumber(tree, children, "port"), 0) },
        .end_of_track => .empty,
        .set_tempo => .{ .tempo = castInt(u32, kvNumber(tree, children, "us"), 0) },
        .smpte_offset => .{ .smpte = .{
            .hr = castInt(u8, kvNumber(tree, children, "hr"), 0),
            .mn = castInt(u8, kvNumber(tree, children, "mn"), 0),
            .se = castInt(u8, kvNumber(tree, children, "se"), 0),
            .fr = castInt(u8, kvNumber(tree, children, "fr"), 0),
            .ff = castInt(u8, kvNumber(tree, children, "ff"), 0),
        } },
        .time_signature => .{ .time_sig = .{
            .nn = castInt(u8, kvNumber(tree, children, "num"), 4),
            .dd = powerOfTwo(castInt(u16, kvNumber(tree, children, "denom"), 4)),
            .cc = castInt(u8, kvNumber(tree, children, "clocks"), 24),
            .bb = castInt(u8, kvNumber(tree, children, "thirty-seconds"), 8),
        } },
        .key_signature => .{ .key_sig = .{
            .sf = castInt(i8, kvNumber(tree, children, "sf"), 0),
            .mi = castInt(u8, kvNumber(tree, children, "mi"), 0),
        } },
        else => unreachable,
    };
}

// ---- tree readers, every one of them total ----

fn spanOf(tree: *const Ast.Tree, idx: NodeIndex) Diag.Span {
    const s = tree.spanOf(idx);
    return .{ .start = s.start, .end = s.end };
}

fn kvNode(tree: *const Ast.Tree, children: []const NodeIndex, name: []const u8) ?NodeIndex {
    for (children) |c| {
        if (tree.tagOf(c) != .kvpair) continue;
        const kv = tree.kvpairHeader(c);
        if (std.mem.eql(u8, kv.key, name)) return kv.value;
    }
    return null;
}

fn kvNumber(tree: *const Ast.Tree, children: []const NodeIndex, name: []const u8) ?f64 {
    const node = kvNode(tree, children, name) orelse return null;
    return switch (tree.tagOf(node)) {
        .number => tree.numberOf(node),
        .number_i64 => @floatFromInt(tree.numberI64Of(node)),
        .number_u64 => @floatFromInt(tree.numberU64Of(node)),
        else => null,
    };
}

/// `:ch` 1..16 back to the wire's 0..15. Absent or out of range is
/// channel 1, which is 0.
fn wireChannel(tree: *const Ast.Tree, children: []const NodeIndex) u8 {
    const v = kvNumber(tree, children, "ch") orelse return 0;
    return if (v >= 1 and v <= 16) @intFromFloat(v - 1) else 0;
}

/// A narrowing read that SATURATES rather than trapping. The manifest's
/// bounds have already refused anything outside them; this is what keeps
/// an unvalidated tree from taking the process with it.
fn castInt(comptime T: type, v: ?f64, fallback: T) T {
    const x = v orelse return fallback;
    if (std.math.isNan(x)) return fallback;
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(std.math.maxInt(T));
    if (x <= lo) return std.math.minInt(T);
    if (x >= hi) return std.math.maxInt(T);
    return @intFromFloat(x);
}

/// A time signature's denominator back to RP-001's `dd` exponent. A
/// number that is not a power of two takes the largest exponent below
/// it, which is the nearest note value the byte can spell.
fn powerOfTwo(denom: u16) u8 {
    if (denom == 0) return 0;
    return @intCast(std.math.log2_int(u16, denom));
}

// ---------------------------------------------------------------------
// Bound lanes: note pairing
// ---------------------------------------------------------------------

/// One sounding note, in the file's own SMF ticks.
///
/// Shared with `bridge_it.zig`, which spells the same value in IT ticks:
/// a paired note is a paired note whatever grid it was read off, and
/// `skeleton.zig` and `Playhead.sounding` want one type, not two.
pub const PairedNote = struct {
    at: i64,
    dur: i64,
    key: u7,
    vel: u7,
    /// The release velocity, when an explicit `note-off` ended the note.
    /// A retrigger and an end-of-track end one WITHOUT a release, and
    /// say so with `null` rather than inventing a zero.
    off_vel: ?u7,
    /// The MIDI channel the note sounded on, on the wire. A binding may
    /// name several channels of one track (`Doc.Channels`), and an onset
    /// carries its own so a render, a score and a materialised `(note
    /// :ch …)` put it back where the file had it. Defaulted because IT
    /// has no such thing: `bridge_it.zig` pairs by tracker channel,
    /// which is the address and not the note's.
    ch: u4 = 0,
};

/// What `pairNotes` returns.
pub const Paired = struct {
    notes: []PairedNote,
    /// `note-off`s with no `note-on` to close. Counted, never diagnosed:
    /// DAWs export such files and plan 05 says so in as many words.
    orphan_offs: u32,
    diags: Diag.List,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Paired) void {
        self.diags.deinit();
        self.arena.deinit();
    }
};

/// Pair `note-on` with `note-off` on one address (plan 05, "Note pairing
/// for bound lanes").
///
/// `track` is 1-BASED file order, the way `(lane :track …)` writes it;
/// `chs` is the set of WIRE channels (0..15) the lane reads, the way
/// `Doc.Address` stores it — one for a hand-written `:ch 2`, several for
/// a `:ch [1 2]` a dump wrote; `key` narrows to one key — a drum lane —
/// and `null` takes every key.
///
/// The rules, each one plan 05's: a `note-on` of velocity 0 is a
/// `note-off`; a second `note-on` on a held key ends the first at that
/// tick and the whole pairing says `note_retrigger` ONCE; an unclosed
/// note ends at the track's end-of-track. A key is held PER CHANNEL:
/// two channels of the set sounding the same key are two notes, not a
/// retrigger, exactly as a synth hears them. The result is in ONSET
/// order, the channels interleaved as the track interleaves them.
pub fn pairNotes(
    gpa: Allocator,
    seq: *const smf.Sequence,
    track: u16,
    chs: Doc.Channels,
    key: ?u7,
) Error!Paired {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    var p: Pairing = .{ .open = try arena.allocator().alloc(?usize, 16 * 128) };
    @memset(p.open, null);
    var retriggered = false;
    var track_end: i64 = 0;

    for (trackEvents(seq, track)) |e| {
        track_end = @max(track_end, e.at);
        const n = addressed(e, chs, key) orelse continue;
        // A `note-on` of velocity 0 is a note off on the wire; the
        // reader stored it as read and the pairing is what interprets it
        // (plan 05, "Events").
        if (e.kind == .note_on and n.vel > 0) {
            const retrigger = try p.on(arena.allocator(), e.at, n);
            if (retrigger and !retriggered) {
                retriggered = true;
                try diags.add(
                    .note_retrigger,
                    .warning,
                    .{ .start = 0, .end = 0 },
                    "a note-on landed on a key this lane was already sounding; " ++
                        "the held note ends there",
                    .{},
                );
            }
        } else p.off(e.at, n);
    }
    p.closeAll(track_end);

    return .{
        .notes = p.notes.items,
        .orphan_offs = p.orphan_offs,
        .diags = diags,
        .arena = arena,
    };
}

/// The note payload of `e` when it is a `note-on` or `note-off` on one
/// of `chs` (and on `key`, when one is asked for) — null for every other
/// event, and for a key no `u7` can hold.
fn addressed(e: smf.Event, chs: Doc.Channels, key: ?u7) ?Note {
    switch (e.kind) {
        .note_on, .note_off => {},
        else => return null,
    }
    const n = e.payload.note;
    if (!onChannels(chs, n.ch)) return null;
    if (key) |want| {
        if (n.key != @as(u8, want)) return null;
    }
    if (n.key > 127) return null;
    return n;
}

/// The pairing's state: the notes so far and, per (channel, key), which
/// of them is still sounding. `open` lives on the arena rather than the
/// stack: sixteen channels of 128 slots is more than a wasm frame should
/// carry.
const Pairing = struct {
    notes: std.ArrayList(PairedNote) = .empty,
    open: []?usize,
    orphan_offs: u32 = 0,

    fn slot(self: *Pairing, n: Note) *?usize {
        return &self.open[@as(usize, n.ch) * 128 + n.key];
    }

    /// A `note-on`: opens a note, and ends the one it retriggers. True
    /// when it did retrigger one.
    fn on(self: *Pairing, arena: Allocator, at: i64, n: Note) Error!bool {
        const held = self.slot(n);
        const retrigger = held.* != null;
        // A second on over a held key ends the first HERE, with no
        // release velocity: none was sent (midi 04's rule).
        if (held.*) |i| self.notes.items[i].dur = heldFor(self.notes.items[i].at, at);
        held.* = self.notes.items.len;
        try self.notes.append(arena, .{
            .at = at,
            .dur = 0,
            .key = @intCast(n.key),
            .vel = @intCast(@min(n.vel, 127)),
            .off_vel = null,
            .ch = @intCast(n.ch),
        });
        return retrigger;
    }

    /// A `note-off` (or a velocity-0 on): ends the held note with its
    /// release velocity, or counts an orphan — DAWs export such files
    /// (plan 05).
    fn off(self: *Pairing, at: i64, n: Note) void {
        const held = self.slot(n);
        const i = held.* orelse {
            self.orphan_offs += 1;
            return;
        };
        self.notes.items[i].dur = heldFor(self.notes.items[i].at, at);
        self.notes.items[i].off_vel = @intCast(@min(n.vel, 127));
        held.* = null;
    }

    /// What never closed ends at the track's end-of-track — its tick,
    /// or the last event's when the track has none.
    fn closeAll(self: *Pairing, track_end: i64) void {
        for (self.open) |maybe| {
            if (maybe) |i| self.notes.items[i].dur = heldFor(self.notes.items[i].at, track_end);
        }
    }
};

/// How long a note that sounded from `from` holds when it ends at `to`:
/// never backwards (an off behind its on, `at_not_monotone`, holds for
/// nothing) and never past `i64` — a `Sequence` carries whatever tick
/// its builder was handed, so the distance saturates rather than wraps.
fn heldFor(from: i64, to: i64) i64 {
    return @max(0, to -| from);
}

/// One track's events by 1-BASED index, or nothing when the document
/// names a track the file does not have.
fn trackEvents(seq: *const smf.Sequence, track: u16) []const smf.Event {
    if (track == 0 or track > seq.tracks.len) return &.{};
    return seq.tracks[track - 1].events;
}

// ---------------------------------------------------------------------
// Bound lanes: curve steps
// ---------------------------------------------------------------------

/// One value a controller reached, at the file's own tick. `value` is
/// NORMALISED to 0..1 (a bend to −1..1); `:range` scales it at export
/// (plan 02, plan 08), so nothing here knows what it drives.
pub const Step = struct {
    at: i64,
    value: f32,
};

/// The steps a bound `curve` lane reads off one address (plan 05, "Curve
/// lanes"). The slice is the CALLER's — `gpa.free` it.
///
/// `.cc14` pairs an MSB with an LSB by MIDI's own rule: an MSB message
/// resets the LSB to zero and an LSB message refines the MSB in force,
/// so a controller sent MSB-only reads as its coarse value and never as
/// a stale fine one. `chs` is the address's channel set, as `pairNotes`
/// takes it; the MSB in force is kept per channel, since a coarse
/// message on one channel says nothing about another's.
pub fn curveSteps(
    gpa: Allocator,
    seq: *const smf.Sequence,
    track: u16,
    chs: Doc.Channels,
    address: Doc.SmfCurve,
) Error![]Step {
    var steps: std.ArrayList(Step) = .empty;
    errdefer steps.deinit(gpa);

    // `:velocity` is the paired notes' velocities at their onsets, not an
    // event stream of its own (plan 05, "Curve lanes").
    if (address == .velocity) {
        var paired = try pairNotes(gpa, seq, track, chs, null);
        defer paired.deinit();
        for (paired.notes) |n| try steps.append(gpa, .{
            .at = n.at,
            .value = @as(f32, @floatFromInt(n.vel)) / 127.0,
        });
        return steps.toOwnedSlice(gpa);
    }

    var msb: [16]u16 = @splat(0);
    for (trackEvents(seq, track)) |e| switch (address) {
        .cc => |num| {
            if (e.kind != .control_change) continue;
            const c = e.payload.control;
            if (!onChannels(chs, c.ch) or c.num != @as(u8, num)) continue;
            try steps.append(gpa, .{ .at = e.at, .value = norm7(c.val) });
        },
        .cc14 => |pair| {
            if (e.kind != .control_change) continue;
            const c = e.payload.control;
            if (!onChannels(chs, c.ch)) continue;
            const coarse = &msb[c.ch & 0x0F];
            if (c.num == @as(u8, pair[0])) {
                // An MSB message resets the fine half to zero, which is
                // what makes an MSB-only controller read as its coarse
                // value and never as a stale fine one (midi 04).
                coarse.* = @as(u16, c.val) << 7;
                try steps.append(gpa, .{ .at = e.at, .value = norm14(coarse.*) });
            } else if (c.num == @as(u8, pair[1])) {
                try steps.append(gpa, .{ .at = e.at, .value = norm14(coarse.* | c.val) });
            }
        },
        .bend => {
            if (e.kind != .pitch_bend) continue;
            const b = e.payload.bend;
            if (!onChannels(chs, b.ch)) continue;
            // Centre 8192 is zero; the two halves are 8192 and 8191
            // wide, and the value is clamped so the top end reads 1.
            const centred = @as(f32, @floatFromInt(@as(i32, b.value) - 8192));
            const span: f32 = if (b.value >= 8192) 8191.0 else 8192.0;
            try steps.append(gpa, .{ .at = e.at, .value = centred / span });
        },
        .pressure => {
            if (e.kind != .channel_pressure) continue;
            const p = e.payload.pressure;
            if (!onChannels(chs, p.ch)) continue;
            try steps.append(gpa, .{ .at = e.at, .value = norm7(p.val) });
        },
        .velocity => unreachable,
    };
    return steps.toOwnedSlice(gpa);
}

/// Whether an event's channel byte, as the reader stored it, is one of
/// the address's. A byte past 15 is no channel at all.
fn onChannels(chs: Doc.Channels, ch: u8) bool {
    return ch <= 15 and chs.has(@intCast(ch));
}

fn norm7(v: u8) f32 {
    return @as(f32, @floatFromInt(@min(v, 127))) / 127.0;
}

fn norm14(v: u16) f32 {
    return @as(f32, @floatFromInt(@min(v, 16383))) / 16383.0;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

/// midi 02's own two-track example, verbatim — alignment, trailing
/// comments and all. It is the fixture for both directions.
const example =
    \\(midi/smf :format 1 :division 480)
    \\
    \\(midi/mtrk
    \\  (sequence-name  :at 0 :text "conductor")
    \\  (time-signature :at 0 :num 4 :denom 4 :clocks 24 :thirty-seconds 8)
    \\  (set-tempo      :at 0    :us 500000)          ; 120 BPM
    \\  (set-tempo      :at 7680 :us 400000)          ; 150 BPM from bar 5
    \\  (marker         :at 7680 :text "drop")
    \\  (end-of-track   :at 15360))
    \\
    \\(midi/mtrk
    \\  (sequence-name  :at 0 :text "drums")
    \\  (program-change :at 0 :ch 10 :num 0)
    \\  (note-on        :at 0    :ch 10 :key 36 :vel 110)
    \\  (note-off       :at 120  :ch 10 :key 36 :vel 0)
    \\  (control-change :at 0    :ch 10 :num 7 :val 100)
    \\  (pitch-bend     :at 240  :ch 10 :val 8192)
    \\  (sysex          :at 480  :data "F0 7E 7F 09 01 F7")
    \\  (end-of-track   :at 15360))
;

/// The same example as the CANONICAL printer spells it: one space
/// between tokens, two-space indent, no trailing comments. A canonical
/// text is what makes a dump comparable (plan 01's determinism rule),
/// and column alignment and margin notes are neither derivable from a
/// `Sequence` nor stable under an edit.
const example_canonical =
    \\(midi/smf :format 1 :division 480)
    \\
    \\(midi/mtrk
    \\  (sequence-name :at 0 :text "conductor")
    \\  (time-signature :at 0 :num 4 :denom 4 :clocks 24 :thirty-seconds 8)
    \\  (set-tempo :at 0 :us 500000)
    \\  (set-tempo :at 7680 :us 400000)
    \\  (marker :at 7680 :text "drop")
    \\  (end-of-track :at 15360))
    \\
    \\(midi/mtrk
    \\  (sequence-name :at 0 :text "drums")
    \\  (program-change :at 0 :ch 10 :num 0)
    \\  (note-on :at 0 :ch 10 :key 36 :vel 110)
    \\  (note-off :at 120 :ch 10 :key 36 :vel 0)
    \\  (control-change :at 0 :ch 10 :num 7 :val 100)
    \\  (pitch-bend :at 240 :ch 10 :val 8192)
    \\  (sysex :at 480 :data "F0 7E 7F 09 01 F7")
    \\  (end-of-track :at 15360))
    \\
;

/// Parse `source` with SJON alone (no schema): the bridge takes a tree,
/// and every test here wants the tree of a text it wrote by hand.
const Parsed = struct {
    tree: Ast.Tree,
    roots: []const NodeIndex,

    fn deinit(self: *Parsed) void {
        self.tree.deinit();
    }
};

fn parse(gpa: Allocator, source: [:0]const u8) !Parsed {
    var tree = try sjon.Parser.parse(gpa, source);
    errdefer tree.deinit();
    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    return .{ .tree = tree, .roots = tree.root };
}

test "bridge_smf: midi 02's two-track example reads to the expected Sequence" {
    const gpa = testing.allocator;
    var p = try parse(gpa, example);
    defer p.deinit();

    var read = try formsToSequence(gpa, &p.tree, p.roots);
    defer read.deinit();

    try testing.expectEqual(@as(u8, 1), read.sequence.format);
    try testing.expectEqual(@as(u15, 480), read.sequence.division.pulsesPerQuarter());
    try testing.expectEqual(@as(usize, 2), read.sequence.tracks.len);
    try testing.expectEqual(@as(usize, 6), read.sequence.tracks[0].events.len);
    try testing.expectEqual(@as(usize, 8), read.sequence.tracks[1].events.len);

    const t0 = read.sequence.tracks[0].events;
    try testing.expectEqual(smf.Kind.sequence_name, t0[0].kind);
    try testing.expectEqualStrings("conductor", read.sequence.bytesOf(t0[0].payload.bytes));
    try testing.expectEqual(smf.Kind.time_signature, t0[1].kind);
    try testing.expectEqual(@as(u8, 2), t0[1].payload.time_sig.dd);
    try testing.expectEqual(@as(u32, 500_000), t0[2].payload.tempo);
    try testing.expectEqual(@as(i64, 7680), t0[3].at);
    try testing.expectEqual(smf.Kind.end_of_track, t0[5].kind);

    const t1 = read.sequence.tracks[1].events;
    try testing.expectEqual(smf.Kind.note_on, t1[2].kind);
    try testing.expectEqual(@as(u8, 9), t1[2].payload.note.ch);
    try testing.expectEqual(@as(u8, 110), t1[2].payload.note.vel);
    try testing.expectEqual(@as(u16, 8192), t1[5].payload.bend.value);
    try testing.expectEqualStrings(
        &[_]u8{ 0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7 },
        read.sequence.bytesOf(t1[6].payload.bytes),
    );
}

test "bridge_smf: the example's second track is not monotone, and says so once" {
    // midi 02's own example puts `(control-change :at 0 …)` after
    // `(note-off :at 120 …)`, which is the rule its prose states two
    // paragraphs earlier. The bridge keeps document order — the
    // canonical writer's stable sort is what re-times a file — and
    // reports the one form that steps back.
    const gpa = testing.allocator;
    var p = try parse(gpa, example);
    defer p.deinit();

    var read = try formsToSequence(gpa, &p.tree, p.roots);
    defer read.deinit();

    try testing.expectEqual(@as(usize, 1), read.diags.count(.at_not_monotone));
}

test "bridge_smf: the example prints canonically and the print is a fixed point" {
    const gpa = testing.allocator;
    var p = try parse(gpa, example);
    defer p.deinit();

    var read = try formsToSequence(gpa, &p.tree, p.roots);
    defer read.deinit();

    const once = try sequenceToForms(gpa, &read.sequence, null, .{});
    defer gpa.free(once);
    try testing.expectEqualStrings(example_canonical, once);

    // …and reading THAT back and printing it again is the same text:
    // the round trip is an identity from the canonical form on.
    const source = try gpa.dupeZ(u8, once);
    defer gpa.free(source);
    var p2 = try parse(gpa, source);
    defer p2.deinit();
    var read2 = try formsToSequence(gpa, &p2.tree, p2.roots);
    defer read2.deinit();
    const twice = try sequenceToForms(gpa, &read2.sequence, null, .{});
    defer gpa.free(twice);
    try testing.expectEqualStrings(once, twice);
}

test "bridge_smf: formsToSequence ∘ sequenceToForms is event-identical" {
    const gpa = testing.allocator;

    var built = built: {
        var b: smf.Builder = .init(gpa);
        errdefer b.deinit();
        b.format = 1;
        b.division = .{ .ppq = 96 };
        const t0 = try b.addTrack();
        try b.addEvent(t0, 0, .sequence_number, .{ .number = 7 });
        try b.addEvent(t0, 0, .text_event, .{ .bytes = try b.addBytes("hello") });
        try b.addEvent(t0, 0, .copyright_notice, .{ .bytes = try b.addBytes("(c) 2026") });
        try b.addEvent(t0, 0, .instrument_name, .{ .bytes = try b.addBytes("bass") });
        try b.addEvent(t0, 0, .lyric, .{ .bytes = try b.addBytes("la") });
        try b.addEvent(t0, 0, .cue_point, .{ .bytes = try b.addBytes("here") });
        try b.addEvent(t0, 0, .program_name, .{ .bytes = try b.addBytes("patch") });
        try b.addEvent(t0, 0, .device_name, .{ .bytes = try b.addBytes("port A") });
        try b.addEvent(t0, 0, .midi_channel_prefix, .{ .byte = 3 });
        try b.addEvent(t0, 0, .midi_port, .{ .byte = 200 });
        try b.addEvent(
            t0,
            0,
            .smpte_offset,
            .{ .smpte = .{ .hr = 1, .mn = 2, .se = 3, .fr = 4, .ff = 5 } },
        );
        try b.addEvent(t0, 0, .key_signature, .{ .key_sig = .{ .sf = -3, .mi = 1 } });
        try b.addEvent(t0, 0, .meta_unknown, .{ .meta = .{
            .bytes = try b.addBytes(&[_]u8{ 0xDE, 0xAD }),
            .meta_type = 0x0A,
        } });
        // A text payload that is not UTF-8 dumps as `:bytes`, which reads
        // back as the same bytes.
        try b.addEvent(t0, 0, .marker, .{ .bytes = try b.addBytes(&[_]u8{ 0xFF, 0xFE }) });
        try b.addEvent(t0, 4, .poly_pressure, .{ .poly = .{ .ch = 0, .key = 60, .val = 40 } });
        try b.addEvent(t0, 4, .channel_pressure, .{ .pressure = .{ .ch = 15, .val = 90 } });
        try b.addEvent(t0, 8, .escape, .{ .bytes = try b.addBytes(&[_]u8{ 0xF7, 0x01 }) });
        try b.addEvent(
            t0,
            8,
            .sequencer_specific,
            .{ .bytes = try b.addBytes(&[_]u8{ 0x43, 0x01 }) },
        );
        try b.addEvent(t0, 96, .end_of_track, .empty);
        break :built try b.finish();
    };
    defer built.deinit();

    const text = try sequenceToForms(gpa, &built, null, .{});
    defer gpa.free(text);
    const source = try gpa.dupeZ(u8, text);
    defer gpa.free(source);

    var p = try parse(gpa, source);
    defer p.deinit();
    var read = try formsToSequence(gpa, &p.tree, p.roots);
    defer read.deinit();
    try expectSameEvents(&built, &read.sequence);
}

/// Event for event: kind, tick, the payload outside the pool, and the
/// pool bytes compared across the two pools (plan 05's rung 2 shape).
fn expectSameEvents(a: *const smf.Sequence, b: *const smf.Sequence) !void {
    try testing.expectEqual(a.format, b.format);
    try testing.expectEqual(a.tracks.len, b.tracks.len);
    for (a.tracks, b.tracks) |ta, tb| {
        try testing.expectEqual(ta.events.len, tb.events.len);
        for (ta.events, tb.events) |ea, eb| {
            try testing.expectEqual(ea.kind, eb.kind);
            try testing.expectEqual(ea.at, eb.at);
            try testing.expect(ea.payload.eqlOutsidePool(eb.payload, ea.kind));
            if (ea.payload.poolBytes(ea.kind)) |ra| {
                const rb = eb.payload.poolBytes(eb.kind).?;
                try testing.expectEqualSlices(u8, a.bytesOf(ra), b.bytesOf(rb));
            }
        }
    }
}

test "bridge_smf: end-of-track, missing and early" {
    const gpa = testing.allocator;

    var missing = try parse(gpa,
        \\(midi/smf :format 0 :division 96)
        \\(midi/mtrk (note-on :at 0 :ch 1 :key 60 :vel 100))
    );
    defer missing.deinit();
    var r1 = try formsToSequence(gpa, &missing.tree, missing.roots);
    defer r1.deinit();
    try testing.expectEqual(@as(usize, 1), r1.diags.count(.end_of_track_missing));

    var early = try parse(gpa,
        \\(midi/smf :format 0 :division 96)
        \\(midi/mtrk (end-of-track :at 0) (note-on :at 0 :ch 1 :key 60 :vel 100) (end-of-track :at 4))
    );
    defer early.deinit();
    var r2 = try formsToSequence(gpa, &early.tree, early.roots);
    defer r2.deinit();
    try testing.expectEqual(@as(usize, 1), r2.diags.count(.end_of_track_early));
}

test "bridge_smf: a SMPTE sequence dumps with the converted PPQ and says what it was" {
    const gpa = testing.allocator;

    var built = built: {
        var b: smf.Builder = .init(gpa);
        errdefer b.deinit();
        b.format = 0;
        b.division = .{ .smpte = .{ .fps = 25, .tpf = 40 } };
        const t = try b.addTrack();
        try b.addEvent(t, 0, .end_of_track, .empty);
        break :built try b.finish();
    };
    defer built.deinit();

    const text = try sequenceToForms(gpa, &built, null, .{});
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\(midi/smf :format 0 :division 500) ; smpte 25 fps × 40
        \\
        \\(midi/mtrk
        \\  (end-of-track :at 0))
        \\
    , text);
}

test "bridge_smf: a SMPTE sequence's set-tempo dumps as 500000 µs, and the note counts the rewrite" {
    const gpa = testing.allocator;

    // 60 QPM in the file; 120 QPM on the grid the file converted to.
    var built = built: {
        var b: smf.Builder = .init(gpa);
        errdefer b.deinit();
        b.format = 0;
        b.division = .{ .smpte = .{ .fps = 25, .tpf = 40 } };
        const t = try b.addTrack();
        try b.addEvent(t, 0, .set_tempo, .{ .tempo = 1_000_000 });
        try b.addEvent(t, 1000, .set_tempo, .{ .tempo = 250_000 });
        try b.addEvent(t, 1000, .end_of_track, .empty);
        break :built try b.finish();
    };
    defer built.deinit();

    const text = try sequenceToForms(gpa, &built, null, .{});
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\(midi/smf :format 0 :division 500) ; smpte 25 fps × 40, 2 set-tempo rewritten to 500000 µs on the converted grid
        \\
        \\(midi/mtrk
        \\  (set-tempo :at 0 :us 500000)
        \\  (set-tempo :at 1000 :us 500000)
        \\  (end-of-track :at 1000))
        \\
    , text);
    // The value was never touched: the rewrite is the printer's.
    try testing.expectEqual(@as(u32, 1_000_000), built.tracks[0].events[0].payload.tempo);

    // The same sequence with the reader's source map says the same.
    var map: smf.SourceMap = .{
        .arena = .init(gpa),
        .chunks = &.{},
        .tracks = &.{},
        .foreign = &.{},
        .smpte = .{ .fps = 25, .tpf = 40, .ppq = 500 },
        .riff = null,
    };
    defer map.deinit();
    const mapped = try sequenceToForms(gpa, &built, &map, .{});
    defer gpa.free(mapped);
    try testing.expectEqualStrings(text, mapped);

    // A PPQ sequence's tempo is its own, and there is no note to count in.
    var plain = plain: {
        var b: smf.Builder = .init(gpa);
        errdefer b.deinit();
        b.format = 0;
        b.division = .{ .ppq = 500 };
        const t = try b.addTrack();
        try b.addEvent(t, 0, .set_tempo, .{ .tempo = 1_000_000 });
        try b.addEvent(t, 0, .end_of_track, .empty);
        break :plain try b.finish();
    };
    defer plain.deinit();
    const plain_text = try sequenceToForms(gpa, &plain, null, .{});
    defer gpa.free(plain_text);
    try testing.expectEqualStrings(
        \\(midi/smf :format 0 :division 500)
        \\
        \\(midi/mtrk
        \\  (set-tempo :at 0 :us 1000000)
        \\  (end-of-track :at 0))
        \\
    , plain_text);
}

// Test-only imports: the wall-clock proof below reads the rebuilt tier
// through the document layer's own conductor — the one owner of plan
// 03's rule 2 — and the time map it feeds, rather than through a second
// model of tempo written into the test.
const fromSjon = @import("fromSjon.zig");
const Grid = @import("../time/Grid.zig");
const TimeMap = @import("../time/TimeMap.zig");

/// The seconds `fromSjon.smfConductor` gives `smf_tick` of `seq`, through
/// `TimeMap.derive`: the same path a dump's timeline takes.
fn conductedSeconds(gpa: Allocator, seq: *const smf.Sequence, smf_tick: i64) !f64 {
    var c = try fromSjon.smfConductor(gpa, seq, .{ .start = 0, .end = 1 });
    defer c.deinit();
    try testing.expect(!c.diags.hasErrors());
    var res = try TimeMap.derive(gpa, c.tempo, c.meter, c.end, .hold);
    defer res.deinit();
    const tick = Grid.smfToTicks(smf_tick, seq.division.pulsesPerQuarter()).tick;
    return res.map.secondsFromTick(tick);
}

test "bridge_smf: a SMPTE file's one-second note still lasts one second after dump → build" {
    const gpa = testing.allocator;

    // 25 fps × 40 tpf is 1000 ticks a second: the note runs 0..1000, one
    // second of wall clock, and the file's set-tempo says 60 QPM — which
    // a PPQ reader of the converted grid would believe, and double.
    var original = built: {
        var b: smf.Builder = .init(gpa);
        errdefer b.deinit();
        b.format = 0;
        b.division = .{ .smpte = .{ .fps = 25, .tpf = 40 } };
        const t = try b.addTrack();
        try b.addEvent(t, 0, .set_tempo, .{ .tempo = 1_000_000 });
        try b.addEvent(t, 0, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
        try b.addEvent(t, 1000, .note_off, .{ .note = .{ .ch = 0, .key = 60, .vel = 64 } });
        try b.addEvent(t, 1000, .end_of_track, .empty);
        break :built try b.finish();
    };
    defer original.deinit();

    // As read: the reader's promise, one 120 QPM segment over the grid.
    try testing.expectEqual(@as(f64, 1.0), try conductedSeconds(gpa, &original, 1000));

    // `tempura dump`: the tier as text, read back as a document's own
    // inline `midi/` tier — a PPQ sequence now, on 500 pulses.
    const text = try sequenceToForms(gpa, &original, null, .{});
    defer gpa.free(text);
    const source = try gpa.dupeZ(u8, text);
    defer gpa.free(source);
    var parsed = try parse(gpa, source);
    defer parsed.deinit();
    var tier = try formsToSequence(gpa, &parsed.tree, parsed.roots);
    defer tier.deinit();
    try testing.expectEqual(smf.Division{ .ppq = 500 }, tier.sequence.division);
    try testing.expectEqual(@as(u32, 500_000), tier.sequence.tracks[0].events[0].payload.tempo);
    try testing.expectEqual(@as(f64, 1.0), try conductedSeconds(gpa, &tier.sequence, 1000));

    // `tempura build` of that document: the inline tier through the
    // canonical writer, and the file it makes read back and conducted.
    var written = try smf.write(gpa, &tier.sequence, .{});
    defer written.deinit();
    try testing.expect(!written.diags.hasErrors());
    var rebuilt = try smf.read(gpa, written.bytes);
    defer rebuilt.deinit();
    try testing.expectEqual(smf.Division{ .ppq = 500 }, rebuilt.sequence.division);
    try testing.expectEqual(@as(i64, 1000), rebuilt.sequence.tracks[0].events[2].at);
    try testing.expectEqual(@as(f64, 1.0), try conductedSeconds(gpa, &rebuilt.sequence, 1000));

    // And the writer's own path on the ORIGINAL sequence — `write(read)`
    // without a dump between — is the same file, byte for byte.
    var direct = try smf.write(gpa, &original, .{});
    defer direct.deinit();
    try testing.expectEqualSlices(u8, written.bytes, direct.bytes);
}

test "bridge_smf: :qualify false spells the two global heads bare" {
    const gpa = testing.allocator;

    var built = built: {
        var b: smf.Builder = .init(gpa);
        errdefer b.deinit();
        b.format = 0;
        b.division = .{ .ppq = 96 };
        const t = try b.addTrack();
        try b.addEvent(t, 0, .end_of_track, .empty);
        break :built try b.finish();
    };
    defer built.deinit();

    const text = try sequenceToForms(gpa, &built, null, .{ .qualify = false });
    defer gpa.free(text);
    try testing.expectEqualStrings(
        \\(smf :format 0 :division 96)
        \\
        \\(mtrk
        \\  (end-of-track :at 0))
        \\
    , text);
}

/// A two-track fixture for the bound-lane derivations: a conductor track
/// and a drum track on channel 10 carrying every pairing case plan 05
/// names.
fn boundFixture(gpa: Allocator) !smf.Sequence {
    var b: smf.Builder = .init(gpa);
    errdefer b.deinit();
    b.format = 1;
    b.division = .{ .ppq = 480 };

    const conductor = try b.addTrack();
    try b.addEvent(conductor, 0, .set_tempo, .{ .tempo = 500_000 });
    try b.addEvent(conductor, 960, .end_of_track, .empty);

    const drums = try b.addTrack();
    const ch: u8 = 9; // `:ch 10` on the wire
    try b.addEvent(drums, 0, .note_on, .{ .note = .{ .ch = ch, .key = 36, .vel = 110 } });
    try b.addEvent(drums, 0, .control_change, .{ .control = .{ .ch = ch, .num = 7, .val = 100 } });
    try b.addEvent(drums, 120, .note_off, .{ .note = .{ .ch = ch, .key = 36, .vel = 64 } });
    try b.addEvent(drums, 240, .note_on, .{ .note = .{ .ch = ch, .key = 38, .vel = 90 } });
    // A second on over a held key: the first ends here (the retrigger).
    try b.addEvent(drums, 300, .note_on, .{ .note = .{ .ch = ch, .key = 38, .vel = 100 } });
    // A `note-on` of velocity 0 IS the off (stored as read, plan 05).
    try b.addEvent(drums, 480, .note_on, .{ .note = .{ .ch = ch, .key = 38, .vel = 0 } });
    try b.addEvent(drums, 480, .control_change, .{ .control = .{ .ch = ch, .num = 7, .val = 0 } });
    // An off with nothing to close: counted, never diagnosed.
    try b.addEvent(drums, 600, .note_off, .{ .note = .{ .ch = ch, .key = 40, .vel = 0 } });
    // …and one that never closes, so it ends at end-of-track.
    try b.addEvent(drums, 700, .note_on, .{ .note = .{ .ch = ch, .key = 41, .vel = 70 } });
    // Another channel's traffic, which this address never sees.
    try b.addEvent(drums, 700, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 99 } });
    try b.addEvent(drums, 960, .end_of_track, .empty);

    return b.finish();
}

test "bridge_smf.pairNotes: retriggers, orphan offs and the unclosed note" {
    const gpa = testing.allocator;
    var seq = try boundFixture(gpa);
    defer seq.deinit();

    var paired = try pairNotes(gpa, &seq, 2, .single(9), null);
    defer paired.deinit();

    try testing.expectEqualSlices(PairedNote, &[_]PairedNote{
        .{ .at = 0, .dur = 120, .key = 36, .vel = 110, .off_vel = 64, .ch = 9 },
        // Ended by the retrigger at 300: no release velocity was sent.
        .{ .at = 240, .dur = 60, .key = 38, .vel = 90, .off_vel = null, .ch = 9 },
        .{ .at = 300, .dur = 180, .key = 38, .vel = 100, .off_vel = 0, .ch = 9 },
        // Never closed: it ends at the track's end-of-track, tick 960.
        .{ .at = 700, .dur = 260, .key = 41, .vel = 70, .off_vel = null, .ch = 9 },
    }, paired.notes);

    try testing.expectEqual(@as(u32, 1), paired.orphan_offs);
    // The warning is the PAIRING's, once, however many keys retriggered.
    try testing.expectEqual(@as(usize, 1), paired.diags.count(.note_retrigger));
    try testing.expect(!paired.diags.hasErrors());
}

test "bridge_smf.pairNotes: ticks at i64's ends pair without overflowing, never backwards" {
    // A `Sequence` holds any `i64` tick its builder was handed. `at -
    // notes[i].at` and `track_end - …` were plain subtractions: an
    // unclosed note-on at `minInt(i64)` overflowed at the end-of-track,
    // and an off behind its on made a negative duration.
    const gpa = testing.allocator;
    var b: smf.Builder = .init(gpa);
    errdefer b.deinit();
    b.division = .{ .ppq = 480 };
    const t = try b.addTrack();
    const min = std.math.minInt(i64);
    const max = std.math.maxInt(i64);
    try b.addEvent(t, min, .note_on, .{ .note = .{ .ch = 0, .key = 36, .vel = 100 } });
    try b.addEvent(t, max, .note_on, .{ .note = .{ .ch = 0, .key = 38, .vel = 100 } });
    try b.addEvent(t, 0, .note_off, .{ .note = .{ .ch = 0, .key = 38, .vel = 64 } });
    try b.addEvent(t, min, .note_on, .{ .note = .{ .ch = 0, .key = 40, .vel = 100 } });
    try b.addEvent(t, max, .note_on, .{ .note = .{ .ch = 0, .key = 40, .vel = 100 } });
    try b.addEvent(t, 0, .end_of_track, .empty);
    var seq = try b.finish();
    defer seq.deinit();

    var paired = try pairNotes(gpa, &seq, 1, .single(0), null);
    defer paired.deinit();
    try testing.expectEqual(@as(usize, 4), paired.notes.len);
    for (paired.notes) |n| try testing.expect(n.dur >= 0);
    // The on at `minInt` held to the track's end saturates; the off
    // behind its on holds for nothing; the retrigger's span saturates.
    try testing.expectEqual(@as(i64, max), paired.notes[0].dur);
    try testing.expectEqual(@as(i64, 0), paired.notes[1].dur);
    try testing.expectEqual(@as(i64, max), paired.notes[2].dur);
}

test "bridge_smf: a negative :at reads as tick 0 — the manifest refuses it, the reader floors it" {
    // `smf-tick` is `:min 0` in `schema/midi.sjon`, so the document is
    // already refused; lowering it anyway (an unvalidated tree) keeps a
    // bound lane's arithmetic on non-negative ticks.
    const gpa = testing.allocator;
    var p = try parse(gpa,
        \\(midi/smf :format 1 :division 480)
        \\(midi/mtrk
        \\  (note-on :at -1e30 :ch 1 :key 36 :vel 100)
        \\  (end-of-track :at 0))
    );
    defer p.deinit();
    var read = try formsToSequence(gpa, &p.tree, p.roots);
    defer read.deinit();
    try testing.expectEqual(@as(i64, 0), read.sequence.tracks[0].events[0].at);
}

test "bridge_smf.pairNotes: :key narrows the address to one drum" {
    const gpa = testing.allocator;
    var seq = try boundFixture(gpa);
    defer seq.deinit();

    var paired = try pairNotes(gpa, &seq, 2, .single(9), 38);
    defer paired.deinit();

    try testing.expectEqual(@as(usize, 2), paired.notes.len);
    for (paired.notes) |n| try testing.expectEqual(@as(u7, 38), n.key);
    // The key-40 orphan is not this lane's off either.
    try testing.expectEqual(@as(u32, 0), paired.orphan_offs);
}

test "bridge_smf.pairNotes: a channel SET reads every channel in it, each onset with its own" {
    // A dump binds a lane that was rendered on several channels at all
    // of them (`Doc.Channels`), and the notes come back interleaved as
    // the track holds them, each saying which channel it sounded on.
    const gpa = testing.allocator;
    var seq = try boundFixture(gpa);
    defer seq.deinit();

    var both = try pairNotes(gpa, &seq, 2, Doc.Channels.single(9).with(0), null);
    defer both.deinit();
    try testing.expectEqual(@as(usize, 5), both.notes.len);
    // Channel 1's note at 700 sits BETWEEN channel 10's, in track order,
    // and is not a retrigger of anything: the key is held per channel.
    try testing.expectEqual(@as(i64, 700), both.notes[3].at);
    try testing.expectEqual(@as(u4, 9), both.notes[3].ch);
    try testing.expectEqual(@as(u7, 41), both.notes[3].key);
    try testing.expectEqual(@as(i64, 700), both.notes[4].at);
    try testing.expectEqual(@as(u4, 0), both.notes[4].ch);
    try testing.expectEqual(@as(u7, 60), both.notes[4].key);
    try testing.expectEqual(@as(usize, 1), both.diags.count(.note_retrigger));

    // The same key on two channels of the set is two notes, not one
    // retriggered: a synth hears them apart, and so does this.
    var b: smf.Builder = .init(gpa);
    errdefer b.deinit();
    const t = try b.addTrack();
    try b.addEvent(t, 0, .note_on, .{ .note = .{ .ch = 0, .key = 60, .vel = 100 } });
    try b.addEvent(t, 10, .note_on, .{ .note = .{ .ch = 1, .key = 60, .vel = 90 } });
    try b.addEvent(t, 20, .note_off, .{ .note = .{ .ch = 0, .key = 60, .vel = 64 } });
    try b.addEvent(t, 30, .note_off, .{ .note = .{ .ch = 1, .key = 60, .vel = 64 } });
    try b.addEvent(t, 40, .end_of_track, .empty);
    var two = try b.finish();
    defer two.deinit();

    var pair = try pairNotes(gpa, &two, 1, Doc.Channels.single(0).with(1), null);
    defer pair.deinit();
    try testing.expectEqualSlices(PairedNote, &[_]PairedNote{
        .{ .at = 0, .dur = 20, .key = 60, .vel = 100, .off_vel = 64, .ch = 0 },
        .{ .at = 10, .dur = 20, .key = 60, .vel = 90, .off_vel = 64, .ch = 1 },
    }, pair.notes);
    try testing.expectEqual(@as(usize, 0), pair.diags.count(.note_retrigger));
}

test "bridge_smf.pairNotes: a track out of range is empty, not a trap" {
    const gpa = testing.allocator;
    var seq = try boundFixture(gpa);
    defer seq.deinit();

    var none = try pairNotes(gpa, &seq, 9, .single(9), null);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.notes.len);

    var zero = try pairNotes(gpa, &seq, 0, .single(9), null);
    defer zero.deinit();
    try testing.expectEqual(@as(usize, 0), zero.notes.len);
}

test "bridge_smf.curveSteps: cc, bend, pressure and velocity" {
    const gpa = testing.allocator;
    var seq = try boundFixture(gpa);
    defer seq.deinit();

    const cc = try curveSteps(gpa, &seq, 2, .single(9), .{ .cc = 7 });
    defer gpa.free(cc);
    try testing.expectEqual(@as(usize, 2), cc.len);
    try testing.expectEqual(@as(i64, 0), cc[0].at);
    try testing.expectApproxEqAbs(@as(f32, 100.0 / 127.0), cc[0].value, 1e-6);
    try testing.expectEqual(@as(i64, 480), cc[1].at);
    try testing.expectApproxEqAbs(@as(f32, 0), cc[1].value, 1e-6);

    // Velocity reads the PAIRED notes at their onsets.
    const vel = try curveSteps(gpa, &seq, 2, .single(9), .velocity);
    defer gpa.free(vel);
    try testing.expectEqual(@as(usize, 4), vel.len);
    try testing.expectApproxEqAbs(@as(f32, 110.0 / 127.0), vel[0].value, 1e-6);
    try testing.expectEqual(@as(i64, 700), vel[3].at);
}

test "bridge_smf.curveSteps: the 14-bit pair and the MSB-only rule" {
    const gpa = testing.allocator;

    var seq = seq: {
        var b: smf.Builder = .init(gpa);
        errdefer b.deinit();
        b.division = .{ .ppq = 96 };
        const t = try b.addTrack();
        try b.addEvent(t, 0, .control_change, .{ .control = .{ .ch = 0, .num = 1, .val = 64 } });
        try b.addEvent(t, 10, .control_change, .{ .control = .{ .ch = 0, .num = 33, .val = 12 } });
        // A second MSB resets the fine half: 65 is 65 · 128, not 65 · 128 + 12.
        try b.addEvent(t, 20, .control_change, .{ .control = .{ .ch = 0, .num = 1, .val = 65 } });
        try b.addEvent(t, 96, .end_of_track, .empty);
        break :seq try b.finish();
    };
    defer seq.deinit();

    const steps = try curveSteps(gpa, &seq, 1, .single(0), .{ .cc14 = .{ 1, 33 } });
    defer gpa.free(steps);
    try testing.expectEqual(@as(usize, 3), steps.len);
    try testing.expectApproxEqAbs(@as(f32, 8192.0 / 16383.0), steps[0].value, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 8204.0 / 16383.0), steps[1].value, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 8320.0 / 16383.0), steps[2].value, 1e-6);
}

test "bridge_smf.curveSteps: bend is −1..1 around its centre" {
    const gpa = testing.allocator;

    var seq = seq: {
        var b: smf.Builder = .init(gpa);
        errdefer b.deinit();
        b.division = .{ .ppq = 96 };
        const t = try b.addTrack();
        try b.addEvent(t, 0, .pitch_bend, .{ .bend = .{ .ch = 3, .value = 8192 } });
        try b.addEvent(t, 4, .pitch_bend, .{ .bend = .{ .ch = 3, .value = 0 } });
        try b.addEvent(t, 8, .pitch_bend, .{ .bend = .{ .ch = 3, .value = 16383 } });
        try b.addEvent(t, 12, .channel_pressure, .{ .pressure = .{ .ch = 3, .val = 127 } });
        try b.addEvent(t, 96, .end_of_track, .empty);
        break :seq try b.finish();
    };
    defer seq.deinit();

    const bend = try curveSteps(gpa, &seq, 1, .single(3), .bend);
    defer gpa.free(bend);
    try testing.expectEqual(@as(usize, 3), bend.len);
    try testing.expectApproxEqAbs(@as(f32, 0), bend[0].value, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1), bend[1].value, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), bend[2].value, 1e-3);

    const press = try curveSteps(gpa, &seq, 1, .single(3), .pressure);
    defer gpa.free(press);
    try testing.expectEqual(@as(usize, 1), press.len);
    try testing.expectApproxEqAbs(@as(f32, 1), press[0].value, 1e-6);
}

/// Validate `source` against the preloaded timeline bundle and require
/// SILENCE from the schema. `(timeline …)`'s "once, first" is a HOST
/// check and not the manifest's, so a bare dump is a legal document as
/// far as validation is concerned — which is exactly the question here:
/// does every spelling this file writes type against `schema/midi.sjon`?
fn expectValidates(source: [:0]const u8) !void {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try Schema.validate(gpa, &schema, source);
    defer res.deinit();
    if (res.diagnostics.len == 0) return;

    std.debug.print("\nthe hosted midi manifest refused this dump:\n{s}\n", .{source});
    for (res.diagnostics) |d| std.debug.print("  {s}\n", .{d.message});
    return error.DumpDoesNotValidate;
}

test "bridge_smf: every spelling the printer writes validates against schema/midi.sjon" {
    const gpa = testing.allocator;

    // The example, and then a sequence carrying one of every other form:
    // between them the two cover every head the hosted tier declares.
    try expectValidates(example_canonical);

    var seq = seq: {
        var b: smf.Builder = .init(gpa);
        errdefer b.deinit();
        b.format = 2;
        b.division = .{ .ppq = 96 };
        const t = try b.addTrack();
        try b.addEvent(t, 0, .sequence_number, .{ .number = 7 });
        try b.addEvent(t, 0, .text_event, .{ .bytes = try b.addBytes("text") });
        try b.addEvent(t, 0, .copyright_notice, .{ .bytes = try b.addBytes("(c)") });
        try b.addEvent(t, 0, .instrument_name, .{ .bytes = try b.addBytes("bass") });
        try b.addEvent(t, 0, .lyric, .{ .bytes = try b.addBytes("la") });
        try b.addEvent(t, 0, .cue_point, .{ .bytes = try b.addBytes("cue") });
        try b.addEvent(t, 0, .program_name, .{ .bytes = try b.addBytes("patch") });
        try b.addEvent(t, 0, .device_name, .{ .bytes = try b.addBytes("port") });
        try b.addEvent(t, 0, .midi_channel_prefix, .{ .byte = 3 });
        try b.addEvent(t, 0, .midi_port, .{ .byte = 200 });
        try b.addEvent(
            t,
            0,
            .smpte_offset,
            .{ .smpte = .{ .hr = 1, .mn = 2, .se = 3, .fr = 4, .ff = 5 } },
        );
        try b.addEvent(t, 0, .key_signature, .{ .key_sig = .{ .sf = -3, .mi = 1 } });
        try b.addEvent(t, 0, .meta_unknown, .{ .meta = .{
            .bytes = try b.addBytes(&[_]u8{ 0xDE, 0xAD }),
            .meta_type = 0x0A,
        } });
        try b.addEvent(t, 0, .marker, .{ .bytes = try b.addBytes(&[_]u8{ 0xFF, 0xFE }) });
        try b.addEvent(t, 1, .poly_pressure, .{ .poly = .{ .ch = 0, .key = 60, .val = 40 } });
        try b.addEvent(t, 1, .channel_pressure, .{ .pressure = .{ .ch = 15, .val = 90 } });
        try b.addEvent(t, 1, .escape, .{ .bytes = try b.addBytes(&[_]u8{ 0xF7, 0x01 }) });
        try b.addEvent(
            t,
            1,
            .sequencer_specific,
            .{ .bytes = try b.addBytes(&[_]u8{ 0x43, 0x01 }) },
        );
        try b.addEvent(
            t,
            2,
            .time_signature,
            .{ .time_sig = .{ .nn = 7, .dd = 3, .cc = 24, .bb = 8 } },
        );
        try b.addEvent(t, 96, .end_of_track, .empty);
        break :seq try b.finish();
    };
    defer seq.deinit();

    const text = try sequenceToForms(gpa, &seq, null, .{});
    defer gpa.free(text);
    const source = try gpa.dupeZ(u8, text);
    defer gpa.free(source);
    try expectValidates(source);
}

test "bridge_smf: the 7-bit, 14-bit and tempo ranges are the MANIFEST's, and it refuses them" {
    // Plan 05 lists these among `fromSjon`'s checks. They are not
    // re-spelled here: `data7`, `bend14` and `tempo-us` are
    // `(value-kind …)`s with their own `(numeric-bounds …)`, so the
    // document is refused at validation and the complaint rides across
    // as `sjon_diagnostic` — the split `fromSjon.zig`'s header states,
    // and the reason this file's readers are total rather than fussy.
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    for ([_][:0]const u8{
        "(midi/smf :format 1 :division 480)\n(midi/mtrk (note-on :at 0 :ch 1 :key 60 :vel 200))",
        "(midi/smf :format 1 :division 480)\n(midi/mtrk (pitch-bend :at 0 :ch 1 :val 20000))",
        "(midi/smf :format 1 :division 480)\n(midi/mtrk (set-tempo :at 0 :us 0))",
        "(midi/smf :format 1 :division 480)\n(midi/mtrk (note-on :at 0 :ch 17 :key 60 :vel 1))",
        "(midi/smf :format 1 :division 0)",
    }) |source| {
        var res = try Schema.validate(gpa, &schema, source);
        defer res.deinit();
        if (res.diagnostics.len == 0) {
            std.debug.print("\nthe manifest accepted an out-of-range value:\n{s}\n", .{source});
            return error.ManifestTooPermissive;
        }
    }
}
