//! The `it/` bridge: a `Module` ⇄ the hosted Impulse Tracker vocabulary.
//!
//! Plan 06, "The binary model". tempura MATERIALISES the timing subset —
//! the header's timing and option fields, the channel defaults, the
//! order list, every pattern's rows and the song message — and keeps
//! everything else OPAQUE: an instrument is its name and a `(bin …)`
//! body, a sample its name, its header region and a `(data …)` whose
//! extent the reader computed. Nothing here decodes a sample or an
//! envelope, and the writer copies the bytes those regions name.
//!
//! Spellings are the it set's 02, as `schema/it.sjon` types them:
//! `(ev 3 "C-5" :ins 2 :vol 64 :fx "SD1")`, orders as numbers with
//! `skip` and `end`, `:at` and `:len` in hex (it 03's 2026-08-25
//! decision). The module's own children are the `it` plugin's GLOBAL
//! heads and carry the tier's namespace inside a timeline document;
//! `row`, `ev`, `ch`, `data` and `bin` are slot-locals and never do.
//!
//! Above the text sit the three derivations a BOUND lane needs:
//! `boundNotes`, `curveSteps` and `orderCues`, each in IT TICKS along a
//! `RowMap` the timing walk produced. Plan 03 turns an IT tick into
//! `Grid.IT_TICK` tempura ticks; nothing here knows that number.

const std = @import("std");
const sjon = @import("sjon");

const Diag = @import("../Diag.zig");
const Doc = @import("Value.zig");
const Schema = @import("../Schema.zig");
const bridge_smf = @import("bridge_smf.zig");
const itf = @import("../itf/itf.zig");
const model = itf.model;
const walk = itf.walk;

const Ast = sjon.Ast;
const NodeIndex = Ast.NodeIndex;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Explicit error set: only resource exhaustion.
pub const Error = error{OutOfMemory};

/// One sounding note, here in IT ticks. The same value `bridge_smf`
/// pairs off a `Sequence` — one type for one concept, so a consumer
/// that reads a bound lane never asks which format it came from.
pub const PairedNote = bridge_smf.PairedNote;

/// One value a column reached, at its row's IT tick.
pub const Step = bridge_smf.Step;

/// The printer's switches (plan 06's table; it 03's `--patterns=bin`,
/// `--preserve-foreign` and `--preserve-history`).
pub const Options = struct {
    /// Whether the module's own children carry the tier's namespace.
    qualify: bool = true,
    /// Dump packed pattern data by reference instead of rows — it 03's
    /// skeleton view. It needs the reader's `SourceMap`, which is where
    /// a pattern's packed region is recorded; without one there is
    /// nothing to point at and the rows are dumped as usual.
    patterns_bin: bool = false,
    /// Keep the trailing chunks another tracker wrote.
    preserve_foreign: bool = false,
    /// Keep the edit-history block.
    preserve_history: bool = false,
    /// Where the reader recorded each region, for `patterns_bin`.
    source_map: ?*const itf.read.SourceMap = null,
    /// Patterns printed as rows even under `patterns_bin`, ascending.
    /// A dump that CONSUMED a cell (plan 04, rule 2:
    /// `residue/reconcile.zig`'s `consumeIt`) has a pattern the file's
    /// own bytes no longer describe, and a `(bin :at :len)` region
    /// cannot lose a cell; those patterns are spelled out.
    rows_for: []const u16 = &.{},
    /// Where the printer reports what it could not spell — a volume
    /// column byte outside IT's own table. Optional because a caller
    /// that only wants the text need not collect one.
    diags: ?*Diag.List = null,
};

// ---------------------------------------------------------------------
// Module → forms
// ---------------------------------------------------------------------

/// The `(it/module …)` text of `module`, owned by the caller.
pub fn moduleToForms(gpa: Allocator, module: *const itf.Module, opts: Options) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var p: Printer = .{ .gpa = gpa, .out = &out, .m = module, .opts = opts };
    try p.document();
    return out.toOwnedSlice(gpa);
}

/// IT's own volume-column table (it 04, "Pattern unpacking") with the
/// letters IT's editor shows (IT.TXT, and the display code batida's 02
/// cites; SUMMARY.TXT has A/C and B/D swapped and is never the source).
///
/// `o` is NOT IT's: bytes 223..232 are OpenMPT's volume-column
/// SAMPLE-OFFSET extension (it 04, "Volume-column byte": "not strict IT;
/// read with a diagnostic, dropped on write"), spelled with OpenMPT's own
/// letter and NAMED whenever it is read or written
/// (`it_command_unknown`). Bytes 125..127, 213..222 and 233..254 mean
/// nothing in either tracker and have no spelling at all.
const VolFamily = struct { letter: u8, base: u8, span: u8, it: bool = true };

const vol_families = [_]VolFamily{
    .{ .letter = 'a', .base = 65, .span = 10 },
    .{ .letter = 'b', .base = 75, .span = 10 },
    .{ .letter = 'c', .base = 85, .span = 10 },
    .{ .letter = 'd', .base = 95, .span = 10 },
    .{ .letter = 'e', .base = 105, .span = 10 },
    .{ .letter = 'f', .base = 115, .span = 10 },
    .{ .letter = 'p', .base = 128, .span = 65 },
    .{ .letter = 'g', .base = 193, .span = 10 },
    .{ .letter = 'h', .base = 203, .span = 10 },
    .{ .letter = 'o', .base = 223, .span = 10, .it = false },
};

/// The volume column's set-volume ceiling: 0..64 is a number, not a code.
const vol_max: u8 = 64;

fn volFamily(byte: u8) ?VolFamily {
    for (vol_families) |f| {
        if (byte >= f.base and byte < f.base + f.span) return f;
    }
    return null;
}

/// The note names IT's editor shows: a letter, `-` or `#`, the octave.
const note_names = [12][2]u8{
    .{ 'C', '-' }, .{ 'C', '#' }, .{ 'D', '-' }, .{ 'D', '#' },
    .{ 'E', '-' }, .{ 'F', '-' }, .{ 'F', '#' }, .{ 'G', '-' },
    .{ 'G', '#' }, .{ 'A', '-' }, .{ 'A', '#' }, .{ 'B', '-' },
};

/// IT's default header scalars, which an omitted key means (it 02's
/// third design rule: "omission = IT default"). They are the manifest's
/// `:default`s, restated here because the printer omits a value that
/// equals one and the reader supplies it when the key is absent.
const defaults = struct {
    const speed: u8 = 6;
    const tempo: u8 = 125;
    const global_vol: u8 = 128;
    const mix_vol: u8 = 48;
    const pan_separation: u8 = 128;
    const pitch_wheel_depth: u8 = 0;
    const pan: u8 = 32;
    const channel_vol: u8 = 64;
    const rows: u16 = 64;
    /// `Flags`, as the manifest's booleans default: stereo,
    /// instrument mode and linear slides on, the rest off.
    const flags: u16 = model.flag.stereo | model.flag.instruments | model.flag.linear_slides;
};

/// `(it/options …)`'s boolean keys, in the manifest's own order, each
/// with its `Flags` bit.
const option_flags = [_]struct { []const u8, u16 }{
    .{ "stereo", model.flag.stereo },
    .{ "vol0-optimizations", model.flag.vol0_optimise },
    .{ "instruments", model.flag.instruments },
    .{ "linear-slides", model.flag.linear_slides },
    .{ "old-effects", model.flag.old_effects },
    .{ "compat-gxx", model.flag.compat_gxx },
    .{ "midi-pitch", model.flag.midi_pitch },
    .{ "embedded-midi", model.flag.embed_midi },
};

/// The embedded MIDI configuration's slots (`model.midi_config_size` =
/// 153 × 32): the nine globals in ITTECH's block order — OpenMPT's
/// `MIDIMacroConfig::szMidiGlb`: MIDI start, MIDI stop, MIDI tick, note
/// on, note off, change volume, change pan, bank select, program change
/// — then the sixteen parametric `SFx` macros and the 128 fixed `Zxx`
/// ones. `(it/midi …)` spells each non-empty slot as `(macro <name>
/// "<body>")`; `schema/it.sjon`'s `macro-name` states the set.
const global_macro_names = [_][]const u8{
    "start", "stop", "tick", "note-on", "note-off", "volume", "pan", "bank", "program",
};
const sfx_macros: usize = 16;
const zxx_macros: usize = 128;
const macro_slots: usize = global_macro_names.len + sfx_macros + zxx_macros;
/// One slot: 32 bytes, NUL-padded, and a full slot has no terminator.
const macro_len: usize = 32;

comptime {
    std.debug.assert(macro_slots * macro_len == model.midi_config_size);
}

/// The name of slot `slot`, spelled into `buf` for the two hex families
/// (`sf0`..`sff`, `z80`..`zff`, lower-case as written).
fn macroName(slot: usize, buf: *[3]u8) []const u8 {
    if (slot < global_macro_names.len) return global_macro_names[slot];
    const hex = "0123456789abcdef";
    if (slot < global_macro_names.len + sfx_macros) {
        buf.* = .{ 's', 'f', hex[slot - global_macro_names.len] };
        return buf;
    }
    const z = 0x80 + (slot - global_macro_names.len - sfx_macros);
    buf.* = .{ 'z', hex[z >> 4], hex[z & 15] };
    return buf;
}

/// The slot `name` spells, or null. Hex digits read in either case.
fn macroSlot(name: []const u8) ?usize {
    for (global_macro_names, 0..) |n, i| {
        if (std.mem.eql(u8, name, n)) return i;
    }
    if (name.len != 3) return null;
    const lead = std.ascii.toLower(name[0]);
    if (lead == 's' and std.ascii.toLower(name[1]) == 'f') {
        const d = std.fmt.charToDigit(name[2], 16) catch return null;
        return global_macro_names.len + d;
    }
    if (lead == 'z') {
        const hi = std.fmt.charToDigit(name[1], 16) catch return null;
        const lo = std.fmt.charToDigit(name[2], 16) catch return null;
        const z = @as(usize, hi) * 16 + lo;
        if (z < 0x80) return null;
        return global_macro_names.len + sfx_macros + (z - 0x80);
    }
    return null;
}

/// Whether every byte is printable ASCII — the only text a macro slot
/// carries between the block and the document (`schema/it.sjon`,
/// `macro-string`). SJON strings carry bytes ≥ 0x80 raw and have no
/// escape for a control byte, so anything else has no lossless spelling.
fn printableAscii(text: []const u8) bool {
    for (text) |c| {
        if (c < 0x20 or c > 0x7E) return false;
    }
    return true;
}

const Printer = struct {
    gpa: Allocator,
    out: *std.ArrayList(u8),
    m: *const itf.Module,
    opts: Options,

    fn document(self: *Printer) Error!void {
        try self.raw("(");
        try self.qualified("module");
        const title = model.nameText(&self.m.header.title);
        if (title.len > 0) {
            try self.raw(" :title ");
            try self.string(title);
        }

        try self.timing();
        try self.options();
        try self.channels();
        try self.orders();
        try self.message();
        try self.midi();
        for (self.m.instruments, 0..) |ins, i| try self.instrument(ins, i);
        for (self.m.samples, 0..) |smp, i| try self.sample(smp, i);
        for (self.m.patterns, 0..) |pat, i| try self.pattern(pat, i);
        if (self.opts.preserve_foreign) for (self.m.foreign) |f| try self.foreignChunk(f);
        if (self.opts.preserve_history) if (self.m.edit_history) |h| {
            try self.child("edit-history");
            try self.raw(" ");
            try self.bin(h);
            try self.raw(")");
        };

        try self.raw(")\n");
    }

    /// A GLOBAL head of the `it` plugin, namespaced when asked for. The
    /// slot-locals — `ch`, `row`, `ev`, `data`, `bin` — never take one.
    fn qualified(self: *Printer, head: []const u8) Error!void {
        if (self.opts.qualify) try self.raw("it/");
        try self.raw(head);
    }

    /// Open one of the module's children on its own line.
    fn child(self: *Printer, head: []const u8) Error!void {
        try self.raw("\n  (");
        try self.qualified(head);
    }

    fn timing(self: *Printer) Error!void {
        const h = self.m.header;
        const highlight = (h.special & model.special.highlight) != 0 and h.highlight_minor > 0;
        if (h.initial_speed == defaults.speed and
            h.initial_tempo == defaults.tempo and !highlight) return;

        try self.child("timing");
        // The two the walk starts from are always written when the form
        // is: a timing section that leaves them out reads as a guess.
        // Both kinds are 1-based, so a zero on disk prints as the one IT
        // itself substitutes.
        try self.raw(" :speed ");
        try self.int(@max(1, h.initial_speed));
        try self.raw(" :tempo ");
        try self.int(@max(1, h.initial_tempo));
        if (highlight) {
            try self.raw(" :highlight [");
            try self.int(h.highlight_minor);
            try self.raw(" ");
            try self.int(h.highlight_major);
            try self.raw("]");
        }
        try self.raw(")");
    }

    fn options(self: *Printer) Error!void {
        const h = self.m.header;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);

        var inner: Printer = .{ .gpa = self.gpa, .out = &body, .m = self.m, .opts = self.opts };
        for (option_flags) |entry| {
            const on = (h.flags & entry[1]) != 0;
            if (on == ((defaults.flags & entry[1]) != 0)) continue;
            try inner.raw(" :");
            try inner.raw(entry[0]);
            try inner.raw(if (on) " true" else " false");
        }
        try inner.scalar("global-vol", h.global_volume, defaults.global_vol);
        try inner.scalar("mix-vol", h.mix_volume, defaults.mix_vol);
        try inner.scalar("pan-separation", h.pan_separation, defaults.pan_separation);
        try inner.scalar("pitch-wheel-depth", h.pitch_wheel_depth, defaults.pitch_wheel_depth);
        // The version words are the module's identity: written only when
        // they are not the pair tempura stamps on a module it authored
        // (plan 06, "The canonical writer").
        if (h.cwtv != model.cwtv_tempura) try inner.word("cwtv", h.cwtv);
        if (h.cmwt != model.cmwt_tempura) try inner.word("cmwt", h.cmwt);

        if (body.items.len == 0) return;
        try self.child("options");
        try self.raw(body.items);
        try self.raw(")");
    }

    fn scalar(self: *Printer, key: []const u8, value: u8, default: u8) Error!void {
        if (value == default) return;
        try self.raw(" :");
        try self.raw(key);
        try self.raw(" ");
        try self.int(value);
    }

    fn word(self: *Printer, key: []const u8, value: u16) Error!void {
        try self.raw(" :");
        try self.raw(key);
        try self.raw(" 0x");
        var buf: [4]u8 = undefined;
        // `{X:0>4}` of a u16 is exactly four digits, and the buffer is four.
        _ = std.fmt.bufPrint(&buf, "{X:0>4}", .{value}) catch unreachable;
        try self.raw(&buf);
    }

    fn channels(self: *Printer) Error!void {
        const h = self.m.header;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var inner: Printer = .{ .gpa = self.gpa, .out = &body, .m = self.m, .opts = self.opts };

        for (0..model.channels) |i| {
            const raw_pan = h.channel_pan[i];
            const vol = h.channel_vol[i];
            // 0xFF is an unused slot, and the vocabulary has no spelling
            // for one: it is left out, and a re-read gives the defaults.
            if (raw_pan == 0xFF) continue;
            const muted = (raw_pan & 0x80) != 0;
            const p = raw_pan & 0x7F;
            const surround = p == 100;
            const pan: u8 = if (p <= 64) p else defaults.pan;
            if (pan == defaults.pan and vol == defaults.channel_vol and !muted and !surround) {
                continue;
            }

            try inner.raw("\n    (ch ");
            try inner.int(i + 1);
            if (!surround and pan != defaults.pan) {
                try inner.raw(" :pan ");
                try inner.int(pan);
            }
            if (vol != defaults.channel_vol) {
                try inner.raw(" :vol ");
                try inner.int(vol);
            }
            if (muted) try inner.raw(" :muted true");
            if (surround) try inner.raw(" :surround true");
            try inner.raw(")");
        }

        if (body.items.len == 0) return;
        try self.child("channels");
        try self.raw(body.items);
        try self.raw(")");
    }

    fn orders(self: *Printer) Error!void {
        if (self.m.orders.len == 0) return;
        try self.child("orders");
        for (self.m.orders) |o| {
            try self.raw(" ");
            if (o == walk.order_skip) {
                try self.raw("skip");
            } else if (o == walk.order_end) {
                try self.raw("end");
            } else try self.int(o);
        }
        try self.raw(")");
    }

    fn message(self: *Printer) Error!void {
        if (self.m.message.len == 0) return;
        var text = try model.cp437ToUtf8(self.gpa, self.m.message);
        defer text.deinit();

        // IT stores CR newlines and some writers store LF; both read as
        // one newline here (plan 06's header table — the autodetection
        // OpenMPT's loader does at `Load_it.cpp:750-753`). A CRLF pair
        // collapses to one, which is what makes the detection mechanical.
        var normalised: std.ArrayList(u8) = .empty;
        defer normalised.deinit(self.gpa);
        var i: usize = 0;
        while (i < text.bytes.len) : (i += 1) {
            const c = text.bytes[i];
            if (c == '\r') {
                if (i + 1 < text.bytes.len and text.bytes[i + 1] == '\n') i += 1;
                try normalised.append(self.gpa, '\n');
            } else try normalised.append(self.gpa, c);
        }

        try self.child("message");
        try self.raw(" ");
        try self.string(normalised.items);
        try self.raw(")");
    }

    /// `(it/midi (macro <name> "<body>") …)`: one child per NON-EMPTY
    /// slot of the block the module carries, in slot order, each body
    /// the slot's bytes up to their NUL. A module read from a file has
    /// the block only when it is not IT's default table
    /// (`regions.midiConfig`), so the form appears exactly when the
    /// file embedded something worth keeping.
    ///
    /// A slot whose text is not printable ASCII has no spelling the
    /// document can carry back byte for byte (`printableAscii`), so it
    /// is left out and NAMED, and the build writes it empty — the loss
    /// the old dump made silently, now said. A block with nothing to
    /// spell prints no form at all; `:embedded-midi true` in the options
    /// still makes the writer embed IT's default table.
    fn midi(self: *Printer) Error!void {
        const block = self.m.midi_config_bytes orelse return;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var inner: Printer = .{ .gpa = self.gpa, .out = &body, .m = self.m, .opts = self.opts };

        for (0..macro_slots) |slot| {
            const at = slot * macro_len;
            // Total over a block of any length: what is there is spelled.
            if (at + macro_len > block.len) break;
            const text = model.nameText(block[at..][0..macro_len]);
            if (text.len == 0) continue;
            var buf: [3]u8 = undefined;
            const slot_name = macroName(slot, &buf);
            if (!printableAscii(text)) {
                if (self.opts.diags) |diags| try diags.add(
                    .it_midi_macro_invalid,
                    .warning,
                    .{ .start = 0, .end = 0 },
                    "MIDI macro {s} holds a byte outside printable ASCII; the slot is not " ++
                        "spelled and rebuilds empty",
                    .{slot_name},
                );
                continue;
            }
            try inner.raw("\n    (macro ");
            try inner.raw(slot_name);
            try inner.raw(" ");
            try inner.string(text);
            try inner.raw(")");
        }

        if (body.items.len == 0) return;
        try self.child("midi");
        try self.raw(body.items);
        try self.raw(")");
    }

    fn instrument(self: *Printer, ins: model.Opaque, index: usize) Error!void {
        try self.child("instrument");
        try self.raw(" ");
        try self.int(index + 1);
        try self.name(model.nameText(&ins.name));
        if (!ins.raw.isEmpty()) {
            try self.raw(" :raw ");
            try self.bin(ins.raw);
        }
        try self.raw(")");
    }

    fn sample(self: *Printer, smp: model.Sample, index: usize) Error!void {
        try self.child("sample");
        try self.raw(" ");
        try self.int(index + 1);
        try self.name(model.nameText(&smp.name));
        if (!smp.raw.isEmpty()) {
            try self.raw(" :raw ");
            try self.bin(smp.raw);
        }
        if (!smp.data.isEmpty()) {
            try self.raw("\n    (data :bits ");
            try self.int(smp.bits);
            try self.raw(" :enc ");
            try self.raw(encName(smp.enc));
            if (smp.channels == 2) try self.raw(" :stereo true");
            try self.raw(" ");
            try self.bin(smp.data);
            try self.raw(")");
        }
        try self.raw(")");
    }

    fn name(self: *Printer, text: []const u8) Error!void {
        if (text.len == 0) return;
        try self.raw(" :name ");
        try self.string(text);
    }

    fn pattern(self: *Printer, pat: model.Pattern, index: usize) Error!void {
        try self.child("pattern");
        try self.raw(" ");
        try self.int(index);
        try self.raw(" :rows ");
        try self.int(pat.rows);

        // it 03's skeleton view: the packed stream by reference, which
        // only the reader's map knows where to find — unless a dump
        // changed this pattern's cells, in which case the file's bytes
        // are not this pattern any more.
        const forced = std.mem.indexOfScalar(
            u16,
            self.opts.rows_for,
            @intCast(@min(index, std.math.maxInt(u16))),
        ) != null;
        if (self.opts.patterns_bin and !forced) {
            if (self.opts.source_map) |map| {
                if (map.find(.pattern, @intCast(index))) |region| {
                    try self.raw(" ");
                    try self.bin(region);
                    try self.raw(")");
                    return;
                }
            }
        }

        for (0..pat.rows) |r| {
            var opened = false;
            for (0..model.channels) |c| {
                const ev = pat.at(r, c).*;
                if (ev.isEmpty()) continue;
                if (!opened) {
                    opened = true;
                    try self.raw("\n    (row ");
                    try self.int(r);
                }
                try self.raw(" ");
                try self.cell(ev, c);
            }
            if (opened) try self.raw(")");
        }
        try self.raw(")");
    }

    fn cell(self: *Printer, c: model.Cell, channel: usize) Error!void {
        try self.raw("(ev ");
        try self.int(channel + 1);
        if (c.note != model.note_none) {
            try self.raw(" ");
            switch (c.note) {
                model.note_off => try self.raw("off"),
                model.note_cut => try self.raw("cut"),
                else => if (c.note <= model.note_max) {
                    var buf: [3]u8 = undefined;
                    buf[0] = note_names[c.note % 12][0];
                    buf[1] = note_names[c.note % 12][1];
                    buf[2] = '0' + @as(u8, @intCast(c.note / 12));
                    try self.raw("\"");
                    try self.raw(&buf);
                    try self.raw("\"");
                } else {
                    // ITTECH gives 120..253 all to the fade, and the
                    // reader's own sentinel is one of them.
                    try self.raw("fade");
                },
            }
        }
        if (c.ins != 0) {
            try self.raw(" :ins ");
            try self.int(c.ins);
        }
        try self.volume(c.vol);
        if (model.fxLetter(c.fx)) |letter| {
            try self.raw(" :fx \"");
            try self.raw(&[_]u8{letter});
            var buf: [2]u8 = undefined;
            // `{X:0>2}` of a u8 is exactly two digits, and the buffer is two.
            _ = std.fmt.bufPrint(&buf, "{X:0>2}", .{c.param}) catch unreachable;
            try self.raw(&buf);
            try self.raw("\"");
        }
        try self.raw(")");
    }

    fn volume(self: *Printer, byte: u8) Error!void {
        if (byte == model.vol_none) return;
        if (byte <= vol_max) {
            try self.raw(" :vol ");
            try self.int(byte);
            return;
        }
        const family = volFamily(byte) orelse {
            try self.unspellable(byte, "no tracker gives it a meaning");
            return;
        };
        if (!family.it) try self.unspellable(
            byte,
            "OpenMPT's volume-column sample-offset extension, not IT's own column",
        );
        try self.raw(" :vol \"");
        try self.raw(&[_]u8{family.letter});
        try self.int(byte - family.base);
        try self.raw("\"");
    }

    fn unspellable(self: *Printer, byte: u8, why: []const u8) Error!void {
        const diags = self.opts.diags orelse return;
        try diags.add(
            .it_command_unknown,
            .warning,
            .{ .start = 0, .end = 0 },
            "volume-column byte {d} is {s}",
            .{ byte, why },
        );
    }

    fn foreignChunk(self: *Printer, f: model.Foreign) Error!void {
        try self.child("foreign");
        try self.raw(" :tag ");
        try self.string(&f.tag);
        try self.raw(" ");
        try self.bin(f.raw);
        try self.raw(")");
    }

    /// `(bin :at 0x… :len 0x…)` — offsets and lengths in hex, it 03's
    /// 2026-08-25 decision, so a dump reads next to a hex dump.
    fn bin(self: *Printer, region: model.Region) Error!void {
        try self.raw("(bin :at 0x");
        try self.hex(region.off);
        try self.raw(" :len 0x");
        try self.hex(region.len);
        try self.raw(")");
    }

    fn hex(self: *Printer, v: u32) Error!void {
        var buf: [8]u8 = undefined;
        // `{X}` of a u32 is at most eight digits, and the buffer is eight.
        const text = std.fmt.bufPrint(&buf, "{X}", .{v}) catch unreachable;
        try self.raw(text);
    }

    fn raw(self: *Printer, text: []const u8) Error!void {
        return self.out.appendSlice(self.gpa, text);
    }

    fn string(self: *Printer, text: []const u8) Error!void {
        return sjon.StringEscape.appendQuoted(self.out, self.gpa, text);
    }

    fn int(self: *Printer, v: anytype) Error!void {
        var buf: [32]u8 = undefined;
        // The widest integer printed here is a u32 offset or an i64 tick:
        // a sign and 19 digits, 20 bytes, into 32.
        const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
        return self.raw(text);
    }
};

/// The `:enc` member each stored encoding is spelled with.
///
/// ModPlug's ADPCM (`Cvt == 0xFF`) has NO member in the hosted manifest —
/// the it set's `enc-kind` names `pcm`, `pcm-unsigned`, `pcm-delta`,
/// `it214` and `it215` and nothing else — so it spells as `pcm`. The
/// region is copied byte for byte either way, so pass-through is exact
/// and only the descriptor drifts; an `adpcm` member is an ask to the it
/// set (recorded with the task).
fn encName(enc: model.Encoding) []const u8 {
    return switch (enc) {
        .pcm, .adpcm => "pcm",
        .it214 => "it214",
        .it215 => "it215",
    };
}

// ---------------------------------------------------------------------
// Forms → Module
// ---------------------------------------------------------------------

/// A hosted `(it/source …)` read out of an inline module, so the caller
/// can hold it against the timeline's own `(anchor …)` — plan 02's
/// `anchor_conflict`. The bridge never resolves it: the anchor is the
/// document's, and this is only what the dump claimed.
pub const Source = struct {
    file: []const u8,
    size: ?u64,
    sha256: ?[]const u8,
    span: Diag.Span,
};

/// What `formsToModule` returns.
pub const Read = struct {
    module: itf.Module,
    /// The `(source …)` the dump carried, when it carried one. Borrowed
    /// from the TREE, so it is valid as long as the tree is.
    source: ?Source,
    diags: Diag.List,

    pub fn deinit(self: *Read) void {
        self.module.deinit();
        self.diags.deinit();
    }
};

/// The inverse of `moduleToForms` over a validated tree.
///
/// `roots` is the dump in document order — one `(it/module …)` form.
/// `anchor_bytes` is the anchor's VERIFIED content, when the host could
/// produce it: every `(bin :at :len)` is meaningful only against that
/// exact file (it 03, "The anchor"), so a region that runs past it is
/// `it_parapointer_out_of_range` and nothing is dereferenced.
///
/// The brief spells the last parameter as a `Resolver`. It is the bytes
/// instead because the bridge never reads a path: an anchor's `:file`
/// belongs to the DOCUMENT, `checks.anchorBytes` is what verifies it
/// against `:size` and `:sha256`, and all this needs of the result is
/// how long it is.
pub fn formsToModule(
    gpa: Allocator,
    tree: *const Ast.Tree,
    roots: []const NodeIndex,
    anchor_bytes: ?[]const u8,
) Error!Read {
    var b: itf.Builder = .init(gpa);
    errdefer b.deinit();
    var diags: Diag.List = .init(gpa);
    errdefer diags.deinit();

    // Not `Header.fresh`: that is what a module tempura AUTHORED starts
    // from, and this one is being read. IT's own defaults plus tempura's
    // version words is what "omission = IT default" means here.
    b.module.header = .{
        .cwtv = model.cwtv_tempura,
        .cmwt = model.cmwt_tempura,
        .flags = defaults.flags,
        .global_volume = defaults.global_vol,
        .mix_volume = defaults.mix_vol,
        .initial_speed = defaults.speed,
        .initial_tempo = defaults.tempo,
        .pan_separation = defaults.pan_separation,
    };

    var r: Reader = .{
        .gpa = gpa,
        .tree = tree,
        .b = &b,
        .diags = &diags,
        .anchor_bytes = anchor_bytes,
    };
    for (roots) |idx| {
        if (tree.tagOf(idx) != .form) continue;
        const hdr = tree.formHeader(idx);
        if (hdr.namespace) |ns| {
            if (!std.mem.eql(u8, ns, "it")) continue;
        }
        if (!std.mem.eql(u8, hdr.head, "module")) continue;
        try r.module(idx);
    }

    return .{ .module = b.finish(), .source = r.source, .diags = diags };
}

/// The instrument and sample keys and children tempura does NOT
/// materialise (plan 06's table): a document that spells one is valid
/// against the hosted manifest and `it_field_not_materialized` at build,
/// until `--full` exists.
const instrument_unmaterialised = [_][]const u8{
    "nna",     "dct",   "dca",     "fadeout", "global-vol",
    "pan",     "swing", "filter",  "midi",    "pitch-pan",
    "notemap", "wav",   "vol-env", "pan-env", "pitch-env",
};

const sample_unmaterialised = [_][]const u8{
    "c5",        "vol", "global-vol",   "pan",          "loop",
    "loop-mode", "wav", "sustain-loop", "sustain-mode", "vibrato",
};

const Reader = struct {
    gpa: Allocator,
    tree: *const Ast.Tree,
    b: *itf.Builder,
    diags: *Diag.List,
    anchor_bytes: ?[]const u8,
    source: ?Source = null,

    fn module(self: *Reader, form: NodeIndex) Error!void {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        if (kvNode(tree, children, "title")) |n| {
            if (tree.tagOf(n) == .string) self.b.setTitle(tree.stringText(n));
        }

        for (children) |child| {
            if (tree.tagOf(child) != .form) continue;
            const head = tree.formHeader(child).head;
            if (std.mem.eql(u8, head, "source")) {
                try self.readSource(child);
            } else if (std.mem.eql(u8, head, "timing")) {
                try self.timing(child);
            } else if (std.mem.eql(u8, head, "options")) {
                try self.options(child);
            } else if (std.mem.eql(u8, head, "channels")) {
                try self.channels(child);
            } else if (std.mem.eql(u8, head, "orders")) {
                try self.orders(child);
            } else if (std.mem.eql(u8, head, "message")) {
                try self.message(child);
            } else if (std.mem.eql(u8, head, "midi")) {
                try self.midi(child);
            } else if (std.mem.eql(u8, head, "instrument")) {
                try self.instrument(child);
            } else if (std.mem.eql(u8, head, "sample")) {
                try self.sample(child);
            } else if (std.mem.eql(u8, head, "pattern")) {
                try self.pattern(child);
            } else if (std.mem.eql(u8, head, "foreign")) {
                try self.foreignChunk(child);
            } else if (std.mem.eql(u8, head, "edit-history")) {
                self.b.module.edit_history = try self.binChild(child);
            }
        }
    }

    fn readSource(self: *Reader, form: NodeIndex) Error!void {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const span = tree.spanOf(form);
        self.source = .{
            .file = if (kvNode(tree, children, "file")) |n|
                if (tree.tagOf(n) == .string) tree.stringText(n) else ""
            else
                "",
            // Saturating, for `fromSjon.readAnchors`' reason: a `:size`
            // no `u64` can hold is user input, not a cast's problem, and
            // a saturated one disagrees with the file and says
            // `anchor_conflict` / `anchor_mismatch` with a span.
            .size = if (kvNumber(tree, children, "size")) |v| castInt(u64, v, 0) else null,
            .sha256 = if (kvNode(tree, children, "sha256")) |n|
                if (tree.tagOf(n) == .string) tree.stringText(n) else null
            else
                null,
            .span = .{ .start = span.start, .end = span.end },
        };
    }

    fn timing(self: *Reader, form: NodeIndex) Error!void {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const h = &self.b.module.header;
        h.initial_speed = castInt(u8, kvNumber(tree, children, "speed"), defaults.speed);
        h.initial_tempo = castInt(u8, kvNumber(tree, children, "tempo"), defaults.tempo);
        if (kvNode(tree, children, "highlight")) |n| {
            if (tree.tagOf(n) == .vector) {
                const elems = tree.vectorElements(n);
                if (elems.len == 2) {
                    h.highlight_minor = castInt(u8, numberOf(tree, elems[0]), 4);
                    h.highlight_major = castInt(u8, numberOf(tree, elems[1]), 16);
                    h.special |= model.special.highlight;
                }
            }
        }
    }

    fn options(self: *Reader, form: NodeIndex) Error!void {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const h = &self.b.module.header;
        for (option_flags) |entry| {
            const on = boolAt(tree, children, entry[0]) orelse continue;
            if (on) h.flags |= entry[1] else h.flags &= ~entry[1];
        }
        h.global_volume = castInt(u8, kvNumber(tree, children, "global-vol"), defaults.global_vol);
        h.mix_volume = castInt(u8, kvNumber(tree, children, "mix-vol"), defaults.mix_vol);
        h.pan_separation = castInt(
            u8,
            kvNumber(tree, children, "pan-separation"),
            defaults.pan_separation,
        );
        h.pitch_wheel_depth = castInt(
            u8,
            kvNumber(tree, children, "pitch-wheel-depth"),
            defaults.pitch_wheel_depth,
        );
        h.cwtv = castInt(u16, kvNumber(tree, children, "cwtv"), model.cwtv_tempura);
        h.cmwt = castInt(u16, kvNumber(tree, children, "cmwt"), model.cmwt_tempura);
    }

    fn channels(self: *Reader, form: NodeIndex) Error!void {
        const tree = self.tree;
        const h = &self.b.module.header;
        for (tree.formHeader(form).children) |child| {
            if (tree.tagOf(child) != .form) continue;
            if (!std.mem.eql(u8, tree.formHeader(child).head, "ch")) continue;
            const children = tree.formHeader(child).children;
            const number = positionalNumber(tree, children) orelse continue;
            if (number < 1 or number > model.channels) continue;
            const i: usize = @intFromFloat(number - 1);

            const surround = boolAt(tree, children, "surround") orelse false;
            const muted = boolAt(tree, children, "muted") orelse false;
            const pan = castInt(u8, kvNumber(tree, children, "pan"), defaults.pan);
            h.channel_pan[i] = (if (surround) @as(
                u8,
                100,
            ) else pan) | (if (muted) @as(u8, 0x80) else 0);
            h.channel_vol[i] = castInt(u8, kvNumber(tree, children, "vol"), defaults.channel_vol);
        }
    }

    fn orders(self: *Reader, form: NodeIndex) Error!void {
        const tree = self.tree;
        for (tree.formHeader(form).children) |child| {
            switch (tree.tagOf(child)) {
                .symbol => {
                    const text = tree.symbolText(child);
                    if (std.mem.eql(u8, text, "skip")) {
                        try self.b.addOrder(walk.order_skip);
                    } else if (std.mem.eql(u8, text, "end")) {
                        try self.b.addOrder(walk.order_end);
                    }
                },
                .number, .number_i64, .number_u64 => {
                    try self.b.addOrder(castInt(u8, numberOf(tree, child), 0));
                },
                else => {},
            }
        }
    }

    fn message(self: *Reader, form: NodeIndex) Error!void {
        const tree = self.tree;
        for (tree.formHeader(form).children) |child| {
            if (tree.tagOf(child) != .string) continue;
            var text = try model.utf8ToCp437(self.gpa, tree.stringText(child));
            defer text.deinit();
            for (text.diags.items()) |d| {
                try self.diags.add(d.code, d.severity, d.span, "{s}", .{d.message});
            }
            // The document's newline is IT's CR on the way back (plan 06,
            // "The canonical writer": CR newlines, NUL-terminated).
            const bytes = try self.b.module.allocator().dupe(u8, text.bytes);
            for (bytes) |*c| {
                if (c.* == '\n') c.* = '\r';
            }
            self.b.module.message = bytes;
            self.b.module.header.special |= model.special.message;
            return;
        }
    }

    /// `(it/midi …)` → the 4896-byte block, every slot the form does not
    /// spell empty, owned by the module (`Module.midi_config_bytes`: a
    /// built module has no anchor for a region to point into). Both
    /// header bits go on, as the writer would set them anyway (it 05's
    /// header policy), so the VALUE says what the file will.
    fn midi(self: *Reader, form: NodeIndex) Error!void {
        const tree = self.tree;
        const block = try self.b.module.allocator().alloc(u8, model.midi_config_size);
        @memset(block, 0);
        var seen: [macro_slots]bool = @splat(false);

        for (tree.formHeader(form).children) |child| {
            if (tree.tagOf(child) != .form) continue;
            if (!std.mem.eql(u8, tree.formHeader(child).head, "macro")) continue;
            try self.macro(child, block, &seen);
        }

        self.b.module.midi_config_bytes = block;
        self.b.module.header.flags |= model.flag.embed_midi;
        self.b.module.header.special |= model.special.midi_config;
    }

    /// One `(macro <name> "<body>")` into its slot. Every refusal is
    /// `it_midi_macro_invalid` at the node that caused it (the volume
    /// column's `it_command_unknown` shape): a name that is no slot
    /// seats nothing; a body past 32 characters is cut; a body with a
    /// byte outside printable ASCII leaves the slot empty, since the
    /// printer could not have written it; a slot spelled twice keeps
    /// the later body.
    fn macro(self: *Reader, form: NodeIndex, block: []u8, seen: *[macro_slots]bool) Error!void {
        const tree = self.tree;
        var name_node: ?NodeIndex = null;
        var body_node: ?NodeIndex = null;
        for (tree.formHeader(form).children) |c| switch (tree.tagOf(c)) {
            .symbol => if (name_node == null) {
                name_node = c;
            },
            .string => if (body_node == null) {
                body_node = c;
            },
            else => {},
        };
        // The manifest already refused a macro with no name; an
        // unvalidated tree's is skipped.
        const name = tree.symbolText(name_node orelse return);
        const slot = macroSlot(name) orelse {
            try self.diags.add(
                .it_midi_macro_invalid,
                .err,
                spanOf(tree, name_node.?),
                "no MIDI macro slot is called {s}: the globals are start, stop, tick, note-on, " ++
                    "note-off, volume, pan, bank and program, then sf0..sff and z80..zff",
                .{name},
            );
            return;
        };
        if (seen[slot]) try self.diags.add(
            .it_midi_macro_invalid,
            .warning,
            spanOf(tree, form),
            "MIDI macro {s} is spelled twice; this later body stands",
            .{name},
        );
        seen[slot] = true;

        const dst = block[slot * macro_len ..][0..macro_len];
        @memset(dst, 0);
        const body_idx = body_node orelse return;
        const body = tree.stringText(body_idx);
        if (!printableAscii(body)) {
            try self.diags.add(
                .it_midi_macro_invalid,
                .err,
                spanOf(tree, body_idx),
                "MIDI macro {s}'s body holds a byte outside printable ASCII; the slot is left " ++
                    "empty",
                .{name},
            );
            return;
        }
        if (body.len > macro_len) try self.diags.add(
            .it_midi_macro_invalid,
            .warning,
            spanOf(tree, body_idx),
            "MIDI macro {s}'s body is {d} characters; the slot holds {d}, so it was cut",
            .{ name, body.len, macro_len },
        );
        const n = @min(body.len, macro_len);
        @memcpy(dst[0..n], body[0..n]);
    }

    fn instrument(self: *Reader, form: NodeIndex) Error!void {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const number = positionalNumber(tree, children) orelse return;
        try self.unmaterialised(form, &instrument_unmaterialised, "instrument");

        var record: model.Opaque = .{ .raw = try self.binKey(children, "raw") };
        model.copyName(&record.name, textAt(tree, children, "name"));

        const index = recordIndex(number, max_record) orelse return;
        while (self.b.instruments.items.len <= index) try self.b.addInstrument("", .none);
        self.b.instruments.items[index] = record;
    }

    fn sample(self: *Reader, form: NodeIndex) Error!void {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const number = positionalNumber(tree, children) orelse return;
        try self.unmaterialised(form, &sample_unmaterialised, "sample");

        var record: model.Sample = .{ .raw = try self.binKey(children, "raw") };
        model.copyName(&record.name, textAt(tree, children, "name"));
        for (children) |child| {
            if (tree.tagOf(child) != .form) continue;
            if (!std.mem.eql(u8, tree.formHeader(child).head, "data")) continue;
            const data = tree.formHeader(child).children;
            record.data = try self.binChild(child);
            record.bits = castInt(u8, kvNumber(tree, data, "bits"), 8);
            record.channels = if (boolAt(tree, data, "stereo") orelse false) 2 else 1;
            record.enc = encOf(symbolAt(tree, data, "enc"));
        }

        const index = recordIndex(number, max_record) orelse return;
        while (self.b.samples.items.len <= index) try self.b.addSample(.{});
        self.b.samples.items[index] = record;
    }

    /// Every key and child the record spells that tempura keeps opaque.
    fn unmaterialised(
        self: *Reader,
        form: NodeIndex,
        names: []const []const u8,
        what: []const u8,
    ) Error!void {
        const tree = self.tree;
        for (tree.formHeader(form).children) |child| {
            const spelled: []const u8 = switch (tree.tagOf(child)) {
                .kvpair => tree.kvpairHeader(child).key,
                .form => tree.formHeader(child).head,
                else => continue,
            };
            for (names) |n| {
                if (!std.mem.eql(u8, spelled, n)) continue;
                try self.diags.add(
                    .it_field_not_materialized,
                    .err,
                    spanOf(tree, child),
                    "tempura keeps {s} bodies opaque: :{s} is written back from the :raw " ++
                        "region, not from this",
                    .{ what, n },
                );
            }
        }
    }

    fn pattern(self: *Reader, form: NodeIndex) Error!void {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const number = positionalNumber(tree, children) orelse return;
        const rows = castInt(u16, kvNumber(tree, children, "rows"), defaults.rows);

        // A pattern is numbered from 0, so its id is its index.
        if (number < 0 or number > max_pattern) return;
        const index: usize = @intFromFloat(number);
        while (self.b.patterns.items.len <= index) _ = try self.b.addPattern(rows);
        // The pattern this number names may have been grown as a filler
        // at another height; re-seat it at the one the form declares.
        if (self.b.patterns.items[index].rows != rows) {
            self.b.patterns.items[index] = .{
                .rows = rows,
                .cells = try self.b.module.allocator().alloc(
                    model.Cell,
                    @as(usize, rows) * model.channels,
                ),
            };
            @memset(self.b.patterns.items[index].cells, .empty);
        }
        const pat = self.b.patterns.items[index];

        for (children) |child| {
            if (tree.tagOf(child) != .form) continue;
            const head = tree.formHeader(child).head;
            if (std.mem.eql(u8, head, "bin")) {
                // it 03's skeleton view, read back. The region is bounds
                // checked and then DROPPED: unpacking it would need the
                // anchor's bytes through `itf.pattern`, and a document
                // whose patterns are references is a compaction for
                // LOOKING at a module, not for editing one. The pattern
                // keeps its declared height and no cells, which is what
                // `--patterns=bin` said it held.
                _ = try self.binRegion(child);
                continue;
            }
            if (!std.mem.eql(u8, head, "row")) continue;
            try self.row(pat, child);
        }
    }

    fn row(self: *Reader, pat: model.Pattern, form: NodeIndex) Error!void {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        const number = positionalNumber(tree, children) orelse return;
        if (number < 0 or number >= @as(f64, @floatFromInt(pat.rows))) return;
        const r: usize = @intFromFloat(number);

        for (children) |child| {
            if (tree.tagOf(child) != .form) continue;
            if (!std.mem.eql(u8, tree.formHeader(child).head, "ev")) continue;
            try self.cell(pat, r, child);
        }
    }

    fn cell(self: *Reader, pat: model.Pattern, r: usize, form: NodeIndex) Error!void {
        const tree = self.tree;
        const children = tree.formHeader(form).children;

        var channel: ?usize = null;
        var note: u8 = model.note_none;
        for (children) |child| switch (tree.tagOf(child)) {
            .number, .number_i64, .number_u64 => {
                if (channel != null) continue;
                const v = numberOf(tree, child) orelse continue;
                if (v >= 1 and v <= model.channels) channel = @intFromFloat(v - 1);
            },
            .string => note = parseNote(tree.stringText(child)) orelse note,
            .symbol => {
                const text = tree.symbolText(child);
                if (std.mem.eql(u8, text, "off")) {
                    note = model.note_off;
                } else if (std.mem.eql(u8, text, "cut")) {
                    note = model.note_cut;
                } else if (std.mem.eql(u8, text, "fade")) note = model.note_fade;
            },
            else => {},
        };
        const c = channel orelse return;

        var out: model.Cell = .{ .note = note };
        if (kvNumber(tree, children, "ins")) |v| out.ins = castInt(u8, v, 0);
        out.vol = try self.volume(children);
        if (kvNode(tree, children, "fx")) |n| {
            if (tree.tagOf(n) == .string) {
                const text = tree.stringText(n);
                if (text.len == 3) {
                    const letter = std.ascii.toUpper(text[0]);
                    if (letter >= 'A' and letter <= 'Z') {
                        out.fx = letter - '@';
                        out.param = (std.fmt.charToDigit(text[1], 16) catch 0) * 16 +
                            (std.fmt.charToDigit(text[2], 16) catch 0);
                    }
                }
            }
        }
        pat.at(r, c).* = out;
    }

    fn volume(self: *Reader, children: []const NodeIndex) Error!u8 {
        const tree = self.tree;
        const node = kvNode(tree, children, "vol") orelse return model.vol_none;
        if (numberOf(tree, node)) |v| return castInt(u8, v, model.vol_none);
        if (tree.tagOf(node) != .string) return model.vol_none;

        const text = tree.stringText(node);
        if (text.len < 2) return model.vol_none;
        const letter = std.ascii.toLower(text[0]);
        for (vol_families) |f| {
            if (f.letter != letter) continue;
            const value = std.fmt.parseInt(u16, text[1..], 10) catch return model.vol_none;
            if (value >= f.span) return model.vol_none;
            if (!f.it) try self.diags.add(
                .it_command_unknown,
                .warning,
                spanOf(tree, node),
                "volume-column code \"{s}\" is OpenMPT's volume-column sample-offset extension, " ++
                    "not IT's own column",
                .{text},
            );
            return f.base + @as(u8, @intCast(value));
        }
        return model.vol_none;
    }

    fn foreignChunk(self: *Reader, form: NodeIndex) Error!void {
        var tag: [4]u8 = @splat(' ');
        const text = textAt(self.tree, self.tree.formHeader(form).children, "tag");
        @memcpy(tag[0..@min(4, text.len)], text[0..@min(4, text.len)]);
        try self.b.addForeign(tag, try self.binChild(form));
    }

    /// The `(bin …)` child of a form.
    fn binChild(self: *Reader, form: NodeIndex) Error!model.Region {
        const tree = self.tree;
        for (tree.formHeader(form).children) |child| {
            if (tree.tagOf(child) != .form) continue;
            if (!std.mem.eql(u8, tree.formHeader(child).head, "bin")) continue;
            return self.binRegion(child);
        }
        return .none;
    }

    /// The `(bin …)` VALUE of a key.
    fn binKey(self: *Reader, children: []const NodeIndex, name: []const u8) Error!model.Region {
        const node = kvNode(self.tree, children, name) orelse return .none;
        if (self.tree.tagOf(node) != .form) return .none;
        if (!std.mem.eql(u8, self.tree.formHeader(node).head, "bin")) return .none;
        return self.binRegion(node);
    }

    fn binRegion(self: *Reader, form: NodeIndex) Error!model.Region {
        const tree = self.tree;
        const children = tree.formHeader(form).children;
        // `(bin :file …)` names bytes outside the anchor; tempura's
        // pass-through model has no home for them yet, so the region is
        // empty and the writer has nothing to copy.
        const at = kvNumber(tree, children, "at") orelse return .none;
        const region: model.Region = .{
            .off = castInt(u32, at, 0),
            .len = castInt(u32, kvNumber(tree, children, "len"), 0),
        };
        if (self.anchor_bytes) |bytes| {
            if (region.end() > bytes.len) try self.diags.add(
                .it_parapointer_out_of_range,
                .err,
                spanOf(tree, form),
                "this region ends at {d} and the anchor is {d} bytes; an offset is meaningful " ++
                    "only against that exact file",
                .{ region.end(), bytes.len },
            );
        }
        return region;
    }
};

/// The highest instrument or sample number the vocabulary admits (it 02:
/// 1..99), and the highest pattern id (0..199 in the manifest, up to
/// OpenMPT's itEx 239 in the wild).
///
/// They are BOUNDS, not validation: the manifest already refused a
/// number outside them, and these are what keep an unvalidated tree from
/// asking for a hundred million records or trapping on the narrowing
/// cast (plan 01: user input is never asserted on).
const max_record: f64 = 255;
const max_pattern: f64 = 1023;

/// A 1-based record number to its index, or null when the number is not
/// one this reader will seat.
fn recordIndex(number: f64, max: f64) ?usize {
    if (!(number >= 1) or number > max) return null;
    return @intFromFloat(number - 1);
}

/// A note name IT's editor would show, back to its number. Total: a
/// spelling this cannot read leaves the cell's note alone.
fn parseNote(text: []const u8) ?u8 {
    if (text.len != 3) return null;
    const octave = std.fmt.charToDigit(text[2], 10) catch return null;
    for (note_names, 0..) |n, step| {
        if (std.ascii.toUpper(text[0]) == n[0] and text[1] == n[1]) {
            return @intCast(octave * 12 + step);
        }
    }
    return null;
}

fn encOf(name: []const u8) model.Encoding {
    if (std.mem.eql(u8, name, "it214")) return .it214;
    if (std.mem.eql(u8, name, "it215")) return .it215;
    return .pcm;
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

fn numberOf(tree: *const Ast.Tree, idx: NodeIndex) ?f64 {
    return switch (tree.tagOf(idx)) {
        .number => tree.numberOf(idx),
        .number_i64 => @floatFromInt(tree.numberI64Of(idx)),
        .number_u64 => @floatFromInt(tree.numberU64Of(idx)),
        else => null,
    };
}

fn kvNumber(tree: *const Ast.Tree, children: []const NodeIndex, name: []const u8) ?f64 {
    return numberOf(tree, kvNode(tree, children, name) orelse return null);
}

fn boolAt(tree: *const Ast.Tree, children: []const NodeIndex, name: []const u8) ?bool {
    const node = kvNode(tree, children, name) orelse return null;
    return switch (tree.tagOf(node)) {
        .boolean_true => true,
        .boolean_false => false,
        else => null,
    };
}

fn textAt(tree: *const Ast.Tree, children: []const NodeIndex, name: []const u8) []const u8 {
    const node = kvNode(tree, children, name) orelse return "";
    return if (tree.tagOf(node) == .string) tree.stringText(node) else "";
}

fn symbolAt(tree: *const Ast.Tree, children: []const NodeIndex, name: []const u8) []const u8 {
    const node = kvNode(tree, children, name) orelse return "";
    return if (tree.tagOf(node) == .symbol) tree.symbolText(node) else "";
}

/// The FIRST positional number of a form — the leading id every one of
/// `instrument`, `sample`, `pattern`, `row` and `ch` carries.
fn positionalNumber(tree: *const Ast.Tree, children: []const NodeIndex) ?f64 {
    for (children) |c| {
        if (numberOf(tree, c)) |v| return v;
    }
    return null;
}

/// One user number narrowed to the field that holds it, SATURATING —
/// the doc layer's only float-to-integer reader, and the shape every one
/// of them has to have.
///
/// A document's numbers are user input, so a narrowing cast on one is a
/// panic waiting for `1e30` (`root.zig`: "user input is never asserted
/// on"). NaN takes the fallback, a value past either end takes that end,
/// and what is left is in range by construction. `fromSjon.readAnchors`
/// calls it for the same `:size` key this file reads two forms away —
/// which is why it is public rather than a second copy there.
pub fn castInt(comptime T: type, v: ?f64, fallback: T) T {
    const x = v orelse return fallback;
    if (std.math.isNan(x)) return fallback;
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(std.math.maxInt(T));
    if (x <= lo) return std.math.minInt(T);
    if (x >= hi) return std.math.maxInt(T);
    return @intFromFloat(x);
}

// ---------------------------------------------------------------------
// Bound lanes
// ---------------------------------------------------------------------

/// The notes a bound `notes` lane reads off one channel (plan 06, "Bound
/// lanes over a module"), in IT ticks, owned by the caller.
///
/// `channel` is the WIRE channel (0..63), the way `Doc.Address` stores
/// it. A cell with a note 0..119 starts a note at the row's start tick
/// plus its `SDx` delay — which the walk already put in the onset — and
/// it ends at the next cell on the channel that carries a note, `off`,
/// `cut` or `fade`, or at the walk's end. Velocity is `round(vol ×
/// 127 / 64)` floored at 1 when the volume column sets a volume, and 127
/// otherwise: a stated convention, since instrument volumes are opaque.
///
/// `module` is taken and not read. The walk already carries each onset's
/// CELL (`walk.Onset.cell`, "because what ENDS a note is a cell too"), so
/// the notes come off the `RowMap` alone — but the two derivations are
/// one surface and read as a pair, `curveSteps` genuinely needs the
/// module's grid, and no caller holds a `RowMap` without the `Module` it
/// was walked from. The parameter stays so the pair keeps one shape and
/// the day the walk stops carrying cells is a body change and not a
/// signature change.
pub fn boundNotes(
    gpa: Allocator,
    module: *const itf.Module,
    rowmap: *const walk.RowMap,
    channel: u6,
) Error![]PairedNote {
    _ = module;
    var notes: std.ArrayList(PairedNote) = .empty;
    errdefer notes.deinit(gpa);

    var open: ?usize = null;
    for (rowmap.onsets) |onset| {
        if (onset.channel != @as(u8, channel)) continue;
        const note = onset.cell.note;
        if (note == model.note_none) continue;

        // A note, `off`, `cut` or `fade` all END what was sounding; only
        // a pitch starts something new.
        if (open) |held| {
            notes.items[held].dur = onset.tick - notes.items[held].at;
            open = null;
        }
        if (note > model.note_max) continue;

        open = notes.items.len;
        try notes.append(gpa, .{
            .at = onset.tick,
            .dur = 0,
            .key = @intCast(note),
            .vel = velocityOf(onset.cell.vol),
            // IT has no release velocity; a note ends, it does not fade
            // at a value.
            .off_vel = null,
        });
    }
    if (open) |held| notes.items[held].dur = rowmap.total_ticks - notes.items[held].at;
    return notes.toOwnedSlice(gpa);
}

/// `round(vol × 127 / 64)`, floored at 1, when the volume column SETS a
/// volume; 127 otherwise (plan 06, "Bound lanes over a module"). A
/// stated convention, not IT semantics: the effective volume involves
/// instrument and sample volumes tempura keeps opaque.
fn velocityOf(vol: u8) u7 {
    if (vol > vol_max) return 127;
    const scaled = (@as(u16, vol) * 127 + 32) / 64;
    return @intCast(@max(1, @min(127, scaled)));
}

/// The steps a bound `curve` lane reads off one column (plan 06, "Bound
/// lanes over a module"), in IT ticks, owned by the caller.
///
/// `vol` reads the set-volume values (0..64 → 0..1); `pan` the `pXX`
/// volume-column codes and the `Xxx` effect (0..64 and 0..255, both to
/// 0..1); `fx` the parameter byte of every command whose letter is
/// `fx_letter` (0..255 → 0..1). `hold` between rows is the reader's, not
/// this: a step is a value AT a tick.
pub fn curveSteps(
    gpa: Allocator,
    module: *const itf.Module,
    rowmap: *const walk.RowMap,
    channel: u6,
    column: Doc.ItColumn,
    fx_letter: ?u8,
) Error![]Step {
    var steps: std.ArrayList(Step) = .empty;
    errdefer steps.deinit(gpa);

    // `Xxx` — set panning, the effect half of the pan column.
    const fx_x: u8 = 'X' - '@';

    for (rowmap.rows) |played| {
        if (played.pattern >= module.patterns.len) continue;
        const pat = module.patterns[played.pattern];
        if (played.row >= pat.rows) continue;
        const c = pat.at(played.row, channel).*;

        switch (column) {
            .vol => if (c.vol <= vol_max) try steps.append(gpa, .{
                .at = played.start_tick,
                .value = @as(f32, @floatFromInt(c.vol)) / 64.0,
            }),
            .pan => {
                // The volume column's `pXX` code first, then `Xxx`: one
                // cell can carry both, and each is a value at this tick.
                if (volFamily(c.vol)) |f| {
                    if (f.letter == 'p') try steps.append(gpa, .{
                        .at = played.start_tick,
                        .value = @as(f32, @floatFromInt(c.vol - f.base)) / 64.0,
                    });
                }
                if (c.fx == fx_x) try steps.append(gpa, .{
                    .at = played.start_tick,
                    .value = @as(f32, @floatFromInt(c.param)) / 255.0,
                });
            },
            .fx => {
                const letter = fx_letter orelse continue;
                const want = std.ascii.toUpper(letter) -% '@';
                if (c.fx != want) continue;
                try steps.append(gpa, .{
                    .at = played.start_tick,
                    .value = @as(f32, @floatFromInt(c.param)) / 255.0,
                });
            },
        }
    }
    return steps.toOwnedSlice(gpa);
}

/// A cue at an order boundary, in IT ticks.
pub const Cue = struct {
    name: []const u8,
    at: i64,
};

/// What `orderCues` returns: the cues and the arena their names live in.
pub const Cues = struct {
    items: []Cue,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Cues) void {
        self.arena.deinit();
    }
};

/// One `(cue :name "order N — pattern P")` per PLAYED order (plan 06,
/// "Bound lanes over a module"; it 09's anchor idiom). Orders are the
/// arrangement, so a cue marks where each one began.
pub fn orderCues(gpa: Allocator, rowmap: *const walk.RowMap) Error!Cues {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var items: std.ArrayList(Cue) = .empty;
    var seen = false;
    var last_order: u16 = 0;
    for (rowmap.rows) |played| {
        if (seen and played.order == last_order) continue;
        seen = true;
        last_order = played.order;
        try items.append(a, .{
            // The em dash is it 09's own idiom, and the name is what a
            // reader sees in a timeline beside the tracker's order list.
            .name = try std.fmt.allocPrint(
                a,
                "order {d} — pattern {d}",
                .{ played.order, played.pattern },
            ),
            .at = played.start_tick,
        });
    }
    return .{ .items = items.items, .arena = arena };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

/// it 02's example in tempura's materialisation (plan 06's table): the
/// header sections and the patterns as rows, the instruments and samples
/// as opaque records with their names, and no `(source …)` — the
/// timeline's own `(anchor …)` is what it 03 calls the source, and the
/// dump never says it twice.
const example =
    \\(it/module :title "acid groove"
    \\  (it/timing :speed 6 :tempo 125 :highlight [4 16])
    \\  (it/options :instruments false :global-vol 100)
    \\  (it/channels
    \\    (ch 1 :pan 16)
    \\    (ch 3 :muted true)
    \\    (ch 4 :surround true))
    \\  (it/orders 0 1 skip end)
    \\  (it/message "hello\ntracker")
    \\  (it/instrument 1 :name "poly bass" :raw (bin :at 0xC0 :len 0x22A))
    \\  (it/instrument 2 :name "lead" :raw (bin :at 0x2EA :len 0x22A))
    \\  (it/sample 1 :name "kick" :raw (bin :at 0x514 :len 0x50)
    \\    (data :bits 8 :enc pcm (bin :at 0x5B4 :len 0x400)))
    \\  (it/sample 2 :name "bass loop" :raw (bin :at 0x564 :len 0x50)
    \\    (data :bits 16 :enc it214 (bin :at 0x8728 :len 0x322A)))
    \\  (it/pattern 0 :rows 64
    \\    (row 0 (ev 1 "C-5" :ins 2 :vol 64 :fx "SD1") (ev 2 "G-5" :ins 2 :vol 40))
    \\    (row 4 (ev 1 off))
    \\    (row 8 (ev 1 "C-5" :ins 2 :fx "GFF") (ev 4 :fx "T80")))
    \\  (it/pattern 1 :rows 32))
    \\
;

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

/// Read `source` as a module and print it back. The fixed point of the
/// two halves is the whole contract of a canonical dump.
fn roundTrip(gpa: Allocator, source: [:0]const u8) ![]u8 {
    var p = try parse(gpa, source);
    defer p.deinit();
    var read = try formsToModule(gpa, &p.tree, p.roots, null);
    defer read.deinit();
    if (read.diags.items().len != 0) {
        for (read.diags.items()) |d| std.debug.print("  {t}: {s}\n", .{ d.code, d.message });
        return error.UnexpectedDiagnostics;
    }
    return moduleToForms(gpa, &read.module, .{});
}

test "bridge_it: the it 02 example round-trips to itself" {
    const gpa = testing.allocator;
    const text = try roundTrip(gpa, example);
    defer gpa.free(text);
    try testing.expectEqualStrings(example, text);
}

fn expectValidates(source: [:0]const u8) !void {
    const gpa = testing.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var res = try Schema.validate(gpa, &schema, source);
    defer res.deinit();
    if (res.diagnostics.len == 0) return;

    std.debug.print("\nthe hosted it manifest refused this dump:\n{s}\n", .{source});
    for (res.diagnostics) |d| std.debug.print("  {s}\n", .{d.message});
    return error.DumpDoesNotValidate;
}

test "bridge_it: every spelling the printer writes validates against schema/it.sjon" {
    try expectValidates(example);
}

test "bridge_it: a spelled instrument or sample field tempura does not materialise" {
    const gpa = testing.allocator;
    var p = try parse(gpa,
        \\(it/module
        \\  (it/instrument 1 :name "bass" :nna continue :fadeout 96
        \\    (vol-env (node 0 64) (node 12 48)))
        \\  (it/sample 1 :name "kick" :c5 44100 :loop [0 35000]))
    );
    defer p.deinit();

    var read = try formsToModule(gpa, &p.tree, p.roots, null);
    defer read.deinit();

    // `:nna`, `:fadeout`, `(vol-env …)`, `:c5`, `:loop` — five fields
    // beyond the name and the body, each named once.
    try testing.expectEqual(@as(usize, 5), read.diags.count(.it_field_not_materialized));
    // …and the records are still there, opaque, with their names.
    try testing.expectEqual(@as(usize, 1), read.module.instruments.len);
    try testing.expectEqualStrings("bass", model.nameText(&read.module.instruments[0].name));
    try testing.expectEqualStrings("kick", model.nameText(&read.module.samples[0].name));
}

test "bridge_it: a (it/source …) inside the dump is read out, never resolved" {
    const gpa = testing.allocator;
    var p = try parse(gpa,
        \\(it/module (it/source :file "acid.it" :size 1284403 :sha256 "9f2a"))
    );
    defer p.deinit();

    var read = try formsToModule(gpa, &p.tree, p.roots, null);
    defer read.deinit();

    try testing.expectEqualStrings("acid.it", read.source.?.file);
    try testing.expectEqual(@as(u64, 1284403), read.source.?.size.?);
    try testing.expectEqualStrings("9f2a", read.source.?.sha256.?);
    // The printer never writes one back: the timeline's (anchor …) says it.
    const text = try moduleToForms(gpa, &read.module, .{});
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "source") == null);
}

test "bridge_it: a (bin …) past the anchor's bytes is refused, never dereferenced" {
    const gpa = testing.allocator;
    var p = try parse(gpa,
        \\(it/module (it/instrument 1 :name "bass" :raw (bin :at 0x10 :len 0x400)))
    );
    defer p.deinit();

    const anchor = [_]u8{0} ** 64;
    var read = try formsToModule(gpa, &p.tree, p.roots, &anchor);
    defer read.deinit();
    try testing.expectEqual(@as(usize, 1), read.diags.count(.it_parapointer_out_of_range));
}

test "bridge_it: the volume column's families, both directions" {
    const gpa = testing.allocator;
    const source =
        \\(it/module
        \\  (it/pattern 0 :rows 64
        \\    (row 0 (ev 1 :vol 40) (ev 2 :vol "a4") (ev 3 :vol "b4") (ev 4 :vol "c4"))
        \\    (row 1 (ev 1 :vol "d4") (ev 2 :vol "e4") (ev 3 :vol "f4") (ev 4 :vol "g4"))
        \\    (row 2 (ev 1 :vol "h4") (ev 2 :vol "p32") (ev 3 :vol "p0") (ev 4 :vol "p64"))))
        \\
    ;
    const text = try roundTrip(gpa, source);
    defer gpa.free(text);
    try testing.expectEqualStrings(source, text);
    try expectValidates(source);
}

test "bridge_it: the OpenMPT volume-column extension is spelled and named" {
    const gpa = testing.allocator;

    var module = module: {
        var b: itf.Builder = .init(gpa);
        errdefer b.deinit();
        const p = try b.addPattern(64);
        // 223..232 is OpenMPT's volume-column SAMPLE-OFFSET extension
        // (it 04, "Volume-column byte"); 213..222 is unused in both IT
        // and OpenMPT and has no spelling at all.
        p.at(0, 0).* = .{ .vol = 226 };
        p.at(1, 0).* = .{ .vol = 215 };
        break :module b.finish();
    };
    defer module.deinit();

    var diags: Diag.List = .init(gpa);
    defer diags.deinit();
    const text = try moduleToForms(gpa, &module, .{ .diags = &diags });
    defer gpa.free(text);

    try testing.expect(std.mem.indexOf(u8, text, ":vol \"o3\"") != null);
    // The unused byte carries no column at all — and neither byte is
    // IT's, so both are named.
    try testing.expect(std.mem.indexOf(u8, text, "215") == null);
    try testing.expectEqual(@as(usize, 2), diags.count(.it_command_unknown));
}

test "bridge_it: the message's newlines, CR and LF alike" {
    const gpa = testing.allocator;

    // IT's own CR, and the LF some writers use instead: both read as one
    // newline in the document (plan 06's header table, the autodetection
    // OpenMPT's loader does at `Load_it.cpp:750-753`).
    for ([_][]const u8{ "one\rtwo", "one\ntwo", "one\r\ntwo" }) |stored| {
        var module = module: {
            var b: itf.Builder = .init(gpa);
            errdefer b.deinit();
            try b.setMessage(stored);
            break :module b.finish();
        };
        defer module.deinit();

        const text = try moduleToForms(gpa, &module, .{});
        defer gpa.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "(it/message \"one\\ntwo\")") != null);
    }

    // …and the document's newline is written back as IT's CR.
    var p = try parse(gpa, "(it/module (it/message \"one\\ntwo\"))");
    defer p.deinit();
    var read = try formsToModule(gpa, &p.tree, p.roots, null);
    defer read.deinit();
    try testing.expectEqualStrings("one\rtwo", read.module.message);
}

/// A block with a macro in each family — two globals, a parametric
/// `SFx`, the first and last `Zxx` — one slot full to its 32nd byte with
/// no terminator, and one whose bytes run on PAST a NUL (nobody reads
/// them, so the spelling ends there).
fn macroBlock() [model.midi_config_size]u8 {
    var block: [model.midi_config_size]u8 = @splat(0);
    @memcpy(block[0..2], "FA"); // start
    @memcpy(block[3 * 32 ..][0..6], "9c n v"); // note-on
    @memcpy(block[9 * 32 ..][0..7], "F0F000z"); // sf0
    @memcpy(block[(9 + 15) * 32 ..][0..32], "0123456789ABCDEF0123456789ABCDEF"); // sff, full
    @memcpy(block[25 * 32 ..][0..8], "F0F00000"); // z80
    @memcpy(block[(25 + 127) * 32 ..][0..12], "F0F0007F\x00xyz"); // zff, then noise
    return block;
}

/// `macroBlock` as a dump → build gives it back: the noise after `zff`'s
/// NUL is not text the document spells, so it rebuilds as zeros.
fn cleanMacroBlock() [model.midi_config_size]u8 {
    var block = macroBlock();
    @memset(block[(25 + 127) * 32 + 8 ..][0..4], 0);
    return block;
}

/// `macroBlock` as the printer spells it: slot order, one child per
/// non-empty slot, the noise after `zff`'s NUL gone.
const midi_example =
    \\(it/module :title "macros"
    \\  (it/timing :speed 6 :tempo 125 :highlight [4 16])
    \\  (it/options :instruments false :embedded-midi true)
    \\  (it/midi
    \\    (macro start "FA")
    \\    (macro note-on "9c n v")
    \\    (macro sf0 "F0F000z")
    \\    (macro sff "0123456789ABCDEF0123456789ABCDEF")
    \\    (macro z80 "F0F00000")
    \\    (macro zff "F0F0007F")))
    \\
;

test "bridge_it: the MIDI macros print per non-empty slot, in slot order, and read back byte for byte" {
    const gpa = testing.allocator;

    var module = module: {
        var b: itf.Builder = .init(gpa);
        errdefer b.deinit();
        b.setTitle("macros");
        try b.setMidiConfig(&macroBlock());
        // As a file's header would have it (it 05: both bits on).
        b.module.header.flags |= model.flag.embed_midi;
        b.module.header.special |= model.special.midi_config;
        break :module b.finish();
    };
    defer module.deinit();

    var diags: Diag.List = .init(gpa);
    defer diags.deinit();
    const text = try moduleToForms(gpa, &module, .{ .diags = &diags });
    defer gpa.free(text);
    try testing.expectEqualStrings(midi_example, text);
    try testing.expectEqual(@as(usize, 0), diags.items().len);
    try expectValidates(midi_example);

    // Read back: the block is the module's own, every unspelled slot
    // empty — which is what the noise after `zff`'s NUL becomes.
    var p = try parse(gpa, midi_example);
    defer p.deinit();
    var read = try formsToModule(gpa, &p.tree, p.roots, null);
    defer read.deinit();
    try testing.expectEqual(@as(usize, 0), read.diags.items().len);
    try testing.expectEqualSlices(u8, &cleanMacroBlock(), read.module.midi_config_bytes.?);
    try testing.expect(read.module.header.flags & model.flag.embed_midi != 0);
    try testing.expect(read.module.header.special & model.special.midi_config != 0);

    // …and the fixed point holds.
    const again = try roundTrip(gpa, midi_example);
    defer gpa.free(again);
    try testing.expectEqualStrings(midi_example, again);
}

test "bridge_it: a MIDI macro slot that is not printable ASCII is left out and named" {
    const gpa = testing.allocator;

    var block: [model.midi_config_size]u8 = @splat(0);
    @memcpy(block[9 * 32 ..][0..4], "F0\x80z"); // sf0, a high byte
    @memcpy(block[10 * 32 ..][0..2], "ok"); // sf1
    @memcpy(block[25 * 32 ..][0..3], "a\tb"); // z80, a control byte

    var module = module: {
        var b: itf.Builder = .init(gpa);
        errdefer b.deinit();
        try b.setMidiConfig(&block);
        break :module b.finish();
    };
    defer module.deinit();

    var diags: Diag.List = .init(gpa);
    defer diags.deinit();
    const text = try moduleToForms(gpa, &module, .{ .diags = &diags });
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "(it/midi\n    (macro sf1 \"ok\"))") != null);
    try testing.expect(std.mem.indexOf(u8, text, "sf0") == null);
    try testing.expect(std.mem.indexOf(u8, text, "z80") == null);
    try testing.expectEqual(@as(usize, 2), diags.count(.it_midi_macro_invalid));

    // Nothing spellable at all: no form, and the block's presence is
    // still in the options for the writer to embed IT's default table.
    @memset(block[10 * 32 ..][0..2], 0);
    var bare = module: {
        var b: itf.Builder = .init(gpa);
        errdefer b.deinit();
        try b.setMidiConfig(&block);
        b.module.header.flags |= model.flag.embed_midi;
        break :module b.finish();
    };
    defer bare.deinit();
    const none = try moduleToForms(gpa, &bare, .{});
    defer gpa.free(none);
    try testing.expect(std.mem.indexOf(u8, none, "it/midi") == null);
    try testing.expect(std.mem.indexOf(u8, none, ":embedded-midi true") != null);
}

test "bridge_it: a (macro …) the block cannot hold is it_midi_macro_invalid at its own node" {
    const gpa = testing.allocator;
    const source =
        "(it/module (it/midi\n" ++
        "  (macro sf0 \"F0F000z\")\n" ++
        "  (macro nope \"x\")\n" ++
        "  (macro SF0 \"F0F001z\")\n" ++
        "  (macro z80 \"0123456789ABCDEF0123456789ABCDEF0\")\n" ++
        "  (macro z81 \"a\\tb\")\n" ++
        "  (macro Z7F \"y\")))";
    var p = try parse(gpa, source);
    defer p.deinit();

    var read = try formsToModule(gpa, &p.tree, p.roots, null);
    defer read.deinit();
    const block = read.module.midi_config_bytes.?;

    // The unknown name, the repeat, the cut and the control byte — and
    // `Z7F`, which is below the `Zxx` range — five, each at its cause.
    try testing.expectEqual(@as(usize, 5), read.diags.count(.it_midi_macro_invalid));
    const items = read.diags.items();
    try testing.expectEqualStrings("nope", source[items[0].span.start..items[0].span.end]);
    try testing.expectEqual(Diag.Severity.err, items[0].severity);
    try testing.expectEqual(Diag.Severity.warning, items[1].severity); // SF0 again
    try testing.expectEqualStrings(
        "\"0123456789ABCDEF0123456789ABCDEF0\"",
        source[items[2].span.start..items[2].span.end],
    );
    try testing.expectEqualStrings("\"a\\tb\"", source[items[3].span.start..items[3].span.end]);
    try testing.expectEqualStrings("Z7F", source[items[4].span.start..items[4].span.end]);

    // The later spelling stands, hex names read in either case, the
    // long body is cut at 32, and the refused one is empty.
    try testing.expectEqualStrings("F0F001z", model.nameText(block[9 * 32 ..][0..32]));
    try testing.expectEqualStrings("0123456789ABCDEF0123456789ABCDEF", block[25 * 32 ..][0..32]);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 32), block[26 * 32 ..][0..32]);
}

test "bridge_it: dump → build keeps the MIDI configuration byte for byte" {
    // The defect this closes: a dump that never spelled the block, and a
    // build that wrote 4896 zero bytes in its place. The whole path here
    // is the bridge's two halves around the core's writer and reader.
    const gpa = testing.allocator;

    var original = module: {
        var b: itf.Builder = .init(gpa);
        errdefer b.deinit();
        try b.addOrder(0);
        const p = try b.addPattern(64);
        p.at(0, 0).* = .{ .note = 60, .ins = 1 };
        // Terminator-clean: bytes past a slot's NUL are nobody's, and the
        // text path drops them (the test above pins that); byte identity
        // is the claim for everything a tracker reads.
        try b.setMidiConfig(&cleanMacroBlock());
        break :module b.finish();
    };
    defer original.deinit();
    var file = try itf.write.write(gpa, &original, null, .{});
    defer file.deinit();

    // dump: the file read, then printed.
    var read = try itf.read.read(gpa, file.bytes);
    defer read.deinit();
    const text = try moduleToForms(gpa, &read.module, .{ .source_map = &read.source_map });
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "(it/midi") != null);

    // build: the text read, then written — with the file as its anchor,
    // as `pipeline.build` hands it over, and without, as a document
    // whose anchor is gone.
    const sentinel = try gpa.dupeZ(u8, text);
    defer gpa.free(sentinel);
    var p = try parse(gpa, sentinel);
    defer p.deinit();
    var back = try formsToModule(gpa, &p.tree, p.roots, file.bytes);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 0), back.diags.items().len);

    for ([_]?[]const u8{ file.bytes, null }) |anchor| {
        var built = try itf.write.write(gpa, &back.module, anchor, .{});
        defer built.deinit();
        try testing.expectEqualSlices(u8, file.bytes, built.bytes);
        var again = try itf.read.read(gpa, built.bytes);
        defer again.deinit();
        try testing.expectEqualSlices(u8, &cleanMacroBlock(), again.module.midi_config_bytes.?);
    }
}

test "bridge_it: --patterns=bin, --preserve-foreign and --preserve-history" {
    const gpa = testing.allocator;

    var module = module: {
        var b: itf.Builder = .init(gpa);
        errdefer b.deinit();
        const p = try b.addPattern(64);
        p.at(0, 0).* = .{ .note = 60, .ins = 1 };
        try b.addForeign("STPM".*, .{ .off = 0x1000, .len = 0x10 });
        break :module b.finish();
    };
    defer module.deinit();
    module.edit_history = .{ .off = 0x1010, .len = 0x20 };

    // Off by default: a strict-IT dump shows neither.
    const plain = try moduleToForms(gpa, &module, .{});
    defer gpa.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "foreign") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "edit-history") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "(row 0 (ev 1 \"C-5\" :ins 1))") != null);

    const kept = try moduleToForms(gpa, &module, .{
        .preserve_foreign = true,
        .preserve_history = true,
    });
    defer gpa.free(kept);
    try testing.expect(
        std.mem.indexOf(u8, kept, "(it/foreign :tag \"STPM\" (bin :at 0x1000 :len 0x10))") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, kept, "(it/edit-history (bin :at 0x1010 :len 0x20))") != null,
    );

    // `--patterns=bin` needs the reader's map to have somewhere to point;
    // without one the rows are dumped as usual.
    const no_map = try moduleToForms(gpa, &module, .{ .patterns_bin = true });
    defer gpa.free(no_map);
    try testing.expect(std.mem.indexOf(u8, no_map, "(row 0") != null);

    const map: itf.read.SourceMap = .{ .entries = &[_]itf.read.SourceMap.Entry{
        .{ .kind = .pattern, .index = 0, .region = .{ .off = 0x2000, .len = 0x40 } },
    } };
    const refs = try moduleToForms(gpa, &module, .{ .patterns_bin = true, .source_map = &map });
    defer gpa.free(refs);
    try testing.expect(
        std.mem.indexOf(u8, refs, "(it/pattern 0 :rows 64 (bin :at 0x2000 :len 0x40))") != null,
    );

    // A pattern a dump changed (plan 04, rule 2's consumption) is rows
    // even under `--patterns=bin`: the file's bytes are not it any more.
    const forced = try moduleToForms(gpa, &module, .{
        .patterns_bin = true,
        .source_map = &map,
        .rows_for = &.{0},
    });
    defer gpa.free(forced);
    try testing.expect(std.mem.indexOf(u8, forced, "(row 0 (ev 1 \"C-5\" :ins 1))") != null);
    try testing.expect(std.mem.indexOf(u8, forced, "(bin :at 0x2000") == null);
}

/// A module whose one pattern exercises the bound-lane rules: a note
/// with a volume, a note delayed by `SDx`, an `off`, a `cut`, and a
/// second channel carrying a pan code and a `Zxx` parameter.
fn boundFixture(gpa: Allocator) !itf.Module {
    var b: itf.Builder = .init(gpa);
    errdefer b.deinit();
    b.module.header.initial_speed = 6;
    b.module.header.initial_tempo = 125;

    const p = try b.addPattern(8);
    // Channel 1: C-5 at volume 32, then a delayed E-5, then `off`.
    p.at(0, 0).* = .{ .note = 60, .ins = 1, .vol = 32 };
    p.at(2, 0).* = .{ .note = 64, .ins = 1, .fx = 'S' - '@', .param = 0xD2 };
    p.at(4, 0).* = .{ .note = model.note_off };
    // …and one that never ends, so the walk's end closes it.
    p.at(6, 0).* = .{ .note = 67, .ins = 1 };
    // Channel 2: a set volume, a pan code and a Zxx macro parameter.
    p.at(0, 1).* = .{ .vol = 0 };
    p.at(1, 1).* = .{ .vol = 64 };
    p.at(2, 1).* = .{ .vol = 128 + 16 }; // `p16`
    p.at(3, 1).* = .{ .fx = 'X' - '@', .param = 255 };
    p.at(4, 1).* = .{ .fx = 'Z' - '@', .param = 128 };

    try b.addOrder(0);
    try b.addOrder(walk.order_end);
    return b.finish();
}

test "bridge_it.boundNotes: velocity, SDx, off and the walk's end" {
    const gpa = testing.allocator;
    var module = try boundFixture(gpa);
    defer module.deinit();

    var rowmap = try walk.derive(gpa, &module, .{});
    defer rowmap.deinit();

    const notes = try boundNotes(gpa, &module, &rowmap, 0);
    defer gpa.free(notes);

    // Speed 6, so a row is 6 IT ticks. `SD2` lands the second note two
    // ticks into its row (12 + 2); `off` at row 4 ends it; the note at
    // row 6 is still sounding when the song restarts, and the restart's
    // own note at tick 48 is what ends it.
    //
    // The walk plays the eight rows and then PART of a second pass: its
    // loop point is the first `(order, row)` revisited with an identical
    // timing state, and `SD2` left a `mem_special` behind, so the states
    // only line up again at row 3 — eleven rows, 66 ticks (plan 06, "The
    // timing walk"). One pattern played twice is two runs of one
    // content, which is exactly what a bound lane should show.
    try testing.expectEqualSlices(PairedNote, &[_]PairedNote{
        .{ .at = 0, .dur = 14, .key = 60, .vel = 64, .off_vel = null },
        .{ .at = 14, .dur = 10, .key = 64, .vel = 127, .off_vel = null },
        .{ .at = 36, .dur = 12, .key = 67, .vel = 127, .off_vel = null },
        .{ .at = 48, .dur = 14, .key = 60, .vel = 64, .off_vel = null },
        // …and the last one runs to the walk's end, tick 66.
        .{ .at = 62, .dur = 4, .key = 64, .vel = 127, .off_vel = null },
    }, notes);
    try testing.expectEqual(@as(i64, 66), rowmap.total_ticks);
}

test "bridge_it.boundNotes: a zero volume still sounds, at velocity 1" {
    const gpa = testing.allocator;

    var module = module: {
        var b: itf.Builder = .init(gpa);
        errdefer b.deinit();
        const p = try b.addPattern(4);
        p.at(0, 0).* = .{ .note = 60, .vol = 0 };
        try b.addOrder(0);
        try b.addOrder(walk.order_end);
        break :module b.finish();
    };
    defer module.deinit();

    var rowmap = try walk.derive(gpa, &module, .{});
    defer rowmap.deinit();
    const notes = try boundNotes(gpa, &module, &rowmap, 0);
    defer gpa.free(notes);

    try testing.expectEqual(@as(usize, 1), notes.len);
    try testing.expectEqual(@as(u7, 1), notes[0].vel);
}

test "bridge_it.curveSteps: the vol, pan and fx columns" {
    const gpa = testing.allocator;
    var module = try boundFixture(gpa);
    defer module.deinit();

    var rowmap = try walk.derive(gpa, &module, .{});
    defer rowmap.deinit();

    const vol = try curveSteps(gpa, &module, &rowmap, 1, .vol, null);
    defer gpa.free(vol);
    // Rows 0 and 1 of each pass the walk played (see `boundNotes`' note
    // on the partial second pass).
    try testing.expectEqualSlices(Step, &[_]Step{
        .{ .at = 0, .value = 0 },
        .{ .at = 6, .value = 1 },
        .{ .at = 48, .value = 0 },
        .{ .at = 54, .value = 1 },
    }, vol);

    // `p16` is a pan code in the volume column; `X FF` is the effect.
    const pan = try curveSteps(gpa, &module, &rowmap, 1, .pan, null);
    defer gpa.free(pan);
    try testing.expectEqual(@as(usize, 3), pan.len);
    try testing.expectEqual(@as(i64, 12), pan[0].at);
    try testing.expectApproxEqAbs(@as(f32, 0.25), pan[0].value, 1e-6);
    try testing.expectEqual(@as(i64, 18), pan[1].at);
    try testing.expectApproxEqAbs(@as(f32, 1), pan[1].value, 1e-6);
    try testing.expectEqual(@as(i64, 60), pan[2].at);

    const fx = try curveSteps(gpa, &module, &rowmap, 1, .fx, 'Z');
    defer gpa.free(fx);
    try testing.expectEqualSlices(Step, &[_]Step{
        .{ .at = 24, .value = 128.0 / 255.0 },
    }, fx);
}

test "bridge_it.orderCues: one cue per played order" {
    const gpa = testing.allocator;

    var module = module: {
        var b: itf.Builder = .init(gpa);
        errdefer b.deinit();
        _ = try b.addPattern(4);
        _ = try b.addPattern(4);
        try b.addOrder(0);
        try b.addOrder(1);
        try b.addOrder(0);
        try b.addOrder(walk.order_end);
        break :module b.finish();
    };
    defer module.deinit();

    var rowmap = try walk.derive(gpa, &module, .{});
    defer rowmap.deinit();

    var cues = try orderCues(gpa, &rowmap);
    defer cues.deinit();

    try testing.expectEqual(@as(usize, 3), cues.items.len);
    try testing.expectEqualStrings("order 0 — pattern 0", cues.items[0].name);
    try testing.expectEqual(@as(i64, 0), cues.items[0].at);
    try testing.expectEqualStrings("order 1 — pattern 1", cues.items[1].name);
    try testing.expectEqual(@as(i64, 24), cues.items[1].at);
    try testing.expectEqualStrings("order 2 — pattern 0", cues.items[2].name);
}

test "bridge_it: cut and fade end a note as off does, and spell back as themselves" {
    const gpa = testing.allocator;

    const source =
        \\(it/module
        \\  (it/orders 0 end)
        \\  (it/pattern 0 :rows 8
        \\    (row 0 (ev 1 "C-5"))
        \\    (row 2 (ev 1 cut))
        \\    (row 4 (ev 1 "E-5"))
        \\    (row 6 (ev 1 fade))))
        \\
    ;
    const text = try roundTrip(gpa, source);
    defer gpa.free(text);
    try testing.expectEqualStrings(source, text);
    try expectValidates(source);

    var p = try parse(gpa, source);
    defer p.deinit();
    var read = try formsToModule(gpa, &p.tree, p.roots, null);
    defer read.deinit();

    var rowmap = try walk.derive(gpa, &read.module, .{});
    defer rowmap.deinit();
    const notes = try boundNotes(gpa, &read.module, &rowmap, 0);
    defer gpa.free(notes);

    // Speed 6: `cut` at row 2 ends the first note, `fade` at row 6 the
    // second, and neither starts one of its own.
    try testing.expectEqualSlices(PairedNote, &[_]PairedNote{
        .{ .at = 0, .dur = 12, .key = 60, .vel = 127, .off_vel = null },
        .{ .at = 24, .dur = 12, .key = 64, .vel = 127, .off_vel = null },
    }, notes);
}

test "bridge_it: a record number no vocabulary admits is skipped, never trapped on" {
    const gpa = testing.allocator;
    // Numbers far outside the manifest's bounds, which only an
    // UNVALIDATED tree can carry: the walk is total and seats nothing.
    var p = try parse(gpa,
        \\(it/module
        \\  (it/instrument 1e18 :name "bass")
        \\  (it/sample -4 :name "kick")
        \\  (it/pattern 99999 :rows 64))
    );
    defer p.deinit();

    var read = try formsToModule(gpa, &p.tree, p.roots, null);
    defer read.deinit();
    try testing.expectEqual(@as(usize, 0), read.module.instruments.len);
    try testing.expectEqual(@as(usize, 0), read.module.samples.len);
    try testing.expectEqual(@as(usize, 0), read.module.patterns.len);
}

test "bridge_it: :qualify false spells the module's own children bare" {
    const gpa = testing.allocator;
    var b: itf.Builder = .init(gpa);
    errdefer b.deinit();
    b.setTitle("bare");
    try b.addOrder(0);
    try b.addOrder(walk.order_end);
    var module = b.finish();
    defer module.deinit();

    const text = try moduleToForms(gpa, &module, .{ .qualify = false });
    defer gpa.free(text);
    // `Builder.init` starts from the header tempura AUTHORS (plan 06),
    // which states its highlight and is not in instrument mode — so the
    // two sections that differ from IT's defaults are written, bare.
    try testing.expectEqualStrings(
        \\(module :title "bare"
        \\  (timing :speed 6 :tempo 125 :highlight [4 16])
        \\  (options :instruments false)
        \\  (orders 0 end))
        \\
    , text);
}

test "bridge_it: the OpenMPT extension read back is named at its own :vol node" {
    const gpa = testing.allocator;
    const source = "(it/module (it/pattern 0 :rows 4 (row 0 (ev 1 :vol \"o3\"))))";
    var p = try parse(gpa, source);
    defer p.deinit();

    var read = try formsToModule(gpa, &p.tree, p.roots, null);
    defer read.deinit();

    // The byte is read — the extension round-trips — and the complaint
    // points at the code that caused it, not at the whole document.
    try testing.expectEqual(@as(u8, 226), read.module.patterns[0].at(0, 0).vol);
    try testing.expectEqual(@as(usize, 1), read.diags.count(.it_command_unknown));
    const span = read.diags.items()[0].span;
    try testing.expectEqualStrings("\"o3\"", source[span.start..span.end]);
}
