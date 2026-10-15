//! The vocabulary's tests: what the four manifests accept and refuse.
//!
//! `src/Schema.zig` owns the LOADER and tests the bundle (it preloads
//! clean, it composes, it matches the project file). This file owns the
//! VOCABULARY: every plan-02 form validates a minimal instance and
//! rejects one malformed key, the `(variant :when …)` gates on
//! `lane :kind`, the exclusive groups, the cross-refs, the hosted `midi/`
//! and `it/` tiers against their own sets' examples, the catalog's
//! both-ways coverage, and the shipped example document.
//!
//! Every assertion goes through SJON's own diagnostics. tempura adds no
//! `Diag.Code` for anything a manifest can say — that is the point of
//! writing the rule as a manifest rule.

const std = @import("std");
const sjon = @import("sjon");
const Schema = @import("Schema.zig");

const t_ = std.testing;
const Code = sjon.Ast.Diagnostic.Code;

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

/// Validate `source` against the bundle and require SILENCE — no errors,
/// no warnings. A valid document must not make the vocabulary talk.
fn expectClean(schema: *const Schema, source: [:0]const u8) !void {
    var res = try Schema.validate(t_.allocator, schema, source);
    defer res.deinit();
    if (res.diagnostics.len != 0) {
        std.debug.print(
            "\nexpected a clean document, got {d} diagnostic(s):\n",
            .{res.diagnostics.len},
        );
        for (res.diagnostics) |d| {
            std.debug.print("  {s}: {s}\n", .{ @tagName(d.code), d.message });
        }
        std.debug.print("source:\n{s}\n", .{source});
        return error.UnexpectedDiagnostics;
    }
}

/// Validate `source` and require that `want` is among the diagnostics.
fn expectCode(schema: *const Schema, source: [:0]const u8, want: Code) !void {
    var res = try Schema.validate(t_.allocator, schema, source);
    defer res.deinit();
    for (res.diagnostics) |d| if (d.code == want) return;

    std.debug.print(
        "\nexpected {s}, got {d} diagnostic(s):\n",
        .{ @tagName(want), res.diagnostics.len },
    );
    for (res.diagnostics) |d| {
        std.debug.print("  {s}: {s}\n", .{ @tagName(d.code), d.message });
    }
    std.debug.print("source:\n{s}\n", .{source});
    return error.ExpectedDiagnosticMissing;
}

/// Read a repo file as a NUL-terminated document source. Caller frees.
fn readRepoFile(gpa: std.mem.Allocator, rel: []const u8) ![:0]u8 {
    const repo_root = @import("build_options").repo_root;
    const path = try std.fs.path.join(gpa, &.{ repo_root, rel });
    defer gpa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(t_.io, path, gpa, .limited(4 * 1024 * 1024));
    defer gpa.free(bytes);
    return gpa.dupeZ(u8, bytes);
}

/// A sibling checkout's file, when the checkout exists. `null` otherwise —
/// the sibling-heads test skips rather than fails on a machine that holds
/// only this repo.
fn readSiblingFile(gpa: std.mem.Allocator, rel: []const u8) !?[:0]u8 {
    const repo_root = @import("build_options").repo_root;
    const path = try std.fs.path.join(gpa, &.{ repo_root, "..", rel });
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        t_.io,
        path,
        gpa,
        .limited(8 * 1024 * 1024),
    ) catch return null;
    defer gpa.free(bytes);
    return try gpa.dupeZ(u8, bytes);
}

// ---------------------------------------------------------------------
// The eight global heads: a minimal instance, and one malformed key
// ---------------------------------------------------------------------

test "tempura: (timeline …) takes its five keys, :fps among them, and refuses a foreign :end" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    // Every key is optional: a bare (timeline) is the smallest legal
    // document, and the rest is the plan's own header line.
    try expectClean(&schema, "(timeline)");
    try expectClean(&schema, "(timeline :title \"impulsos\" :length 128bar :end loop)");

    // The frame rate, for the `f` position unit (plan 03): an integer or
    // an exact [num den] rational — never a bare decimal, which would
    // bake 2997/100 into every NTSC document.
    try expectClean(&schema, "(timeline :fps 25)");
    try expectClean(&schema, "(timeline :fps [30000 1001])");
    try expectCode(&schema, "(timeline :fps 29.97)", .number_not_integer);
    try expectCode(&schema, "(timeline :fps [30000 1001 1])", .vector_length_mismatch);

    // `:end` is pacer's `end-behavior` set, spelled here as its own kind.
    try expectCode(&schema, "(timeline :end stop)", .not_member);
    // A position without a unit is never guessed at (plan 03).
    try expectCode(&schema, "(timeline :length 128)", .unit_required);
}

test "tempura: (anchor …) names a file of a known kind" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema, "(anchor :id song :kind it :file \"impulse-04.it\")");
    try expectClean(&schema,
        \\(anchor :id song :kind it :file "impulse-04.it" :size 1284403 :sha256 "9f2a…")
    );

    try expectCode(&schema, "(anchor :id song :kind mod :file \"x.mod\")", .not_member);
    try expectCode(&schema, "(anchor :kind it :file \"x.it\")", .missing_required_key);
}

test "tempura: (tempo-point …) takes exactly one of :us | :qpm, never a seconds :at" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema, "(tempo-point :at 0q :qpm 125)");
    try expectClean(&schema, "(tempo-point :at 64bar :us 400000)");

    // The exclusive group, both ways.
    try expectCode(
        &schema,
        "(tempo-point :at 0q :qpm 125 :us 400000)",
        .mutually_exclusive_keys_present,
    );
    try expectCode(&schema, "(tempo-point :at 0q)", .required_one_of_missing);
    // Seconds are circular on the map that defines them (plan 03).
    try expectCode(&schema, "(tempo-point :at 0s :qpm 125)", .unit_not_allowed);
    // The SMF `set-tempo` range.
    try expectCode(&schema, "(tempo-point :at 0q :us 0)", .number_below_min);
}

test "tempura: (meter-point …) takes a two-component signature" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema, "(meter-point :at 0bar :sig [4 4])");
    try expectClean(&schema, "(meter-point :at 32bar :sig [3 4])");

    try expectCode(&schema, "(meter-point :at 0bar :sig [4 4 4])", .vector_length_mismatch);
    try expectCode(&schema, "(meter-point :at 0s :sig [4 4])", .unit_not_allowed);
    try expectCode(&schema, "(meter-point :at 0bar :sig [0 4])", .number_below_min);
}

test "tempura: (section …) is a window and (cue …) is a point" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema, "(section :name intro :at 0bar :dur 16bar)");
    try expectClean(&schema, "(cue :name \"bar 41\" :at 40bar)");

    try expectCode(&schema, "(section :name intro :at 0 :dur 16bar)", .unit_required);
    // A cue has no window — `:dur` is not one of its keys.
    try expectCode(&schema, "(cue :name \"bar 41\" :at 40bar :dur 4bar)", .unknown_key);
    // A cue's name is prose, not an identifier.
    try expectCode(&schema, "(cue :name bar-41 :at 40bar)", .wrong_underlying);
}

test "tempura: (lane …) names a kind, and the kind is closed" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema, "(lane :name kick :kind notes :target kick)");
    // `:target` defaults to `:name` — the plan's rule, so it is optional.
    try expectClean(&schema, "(lane :name kick :kind notes)");

    try expectCode(&schema, "(lane :name kick :kind chorus)", .not_member);
    try expectCode(&schema, "(lane :kind notes)", .missing_required_key);
}

test "tempura: (phrase …) holds lanes and nothing else" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema,
        \\(phrase :name fill :length 1bar
        \\  (lane :name flash :kind notes
        \\    (note :at 0q :dur 0.25q :key 38 :vel 100)))
    );

    try expectCode(
        &schema,
        "(phrase :length 1bar (lane :name flash :kind notes))",
        .missing_required_key,
    );
    // The positional head-set: a phrase's children are lanes.
    try expectCode(&schema,
        \\(phrase :name fill :length 1bar (cue :name "x" :at 0q))
    , .not_head_member);
    // …and a phrase with no lane at all is an empty phrase (the head's
    // `:min 1` count).
    try expectCode(&schema, "(phrase :name fill :length 1bar)", .positional_missing);
}

// ---------------------------------------------------------------------
// The three slot-locals under `lane`
// ---------------------------------------------------------------------

test "tempura: (note …) is slot-local to a lane and bounded like MIDI" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema,
        \\(lane :name flash :kind notes :target flash
        \\  (note :at 0q :dur 0.5q :key 36 :vel 110)
        \\  (note :at 1q :dur 0.5q :key "C4" :vel 90 :ch 3 :off-vel 64))
    );

    // A velocity outside 1..127 is not a MIDI velocity.
    try expectCode(&schema,
        \\(lane :name flash :kind notes (note :at 0q :dur 0.5q :key 36 :vel 200))
    , .number_above_max);
    // …and `note` exists nowhere but inside a lane.
    try expectCode(&schema, "(note :at 0q :dur 0.5q :key 36)", .unknown_form);
}

test "tempura: (keyframe …) carries a value and an easing typed by pacer's own kind" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema,
        \\(lane :name glow :kind curve :target glow
        \\  (keyframe :at 0q :value 0.2 :ease hold)
        \\  (keyframe :at 4q :value 0.9 :ease in-cubic)
        \\  (keyframe :at 8q :value [0.1 0.2 0.3] :ease (spring :damping 0.5)))
    );

    // The cross-plugin kind reference is what makes this fail: `wobble`
    // is not in pacer's `ease-name` member set, and tempura cannot drift
    // from that set because it does not own a copy of it.
    try expectCode(&schema,
        \\(lane :name glow :kind curve (keyframe :at 0q :value 0.2 :ease wobble))
    , .not_member);
    // A keyframe value is a scalar or a 1..4 vector (pacer's `key-value`).
    try expectCode(&schema,
        \\(lane :name glow :kind curve (keyframe :at 0q :value [1 2 3 4 5]))
    , .vector_too_long);
}

test "tempura: (clip …) cross-refs a phrase by name" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema,
        \\(phrase :name fill :length 1bar (lane :name flash :kind notes))
        \\(lane :name flash :kind notes :target flash
        \\  (clip :at 8bar :phrase fill :repeat 2 :offset 0q :transpose 12))
    );

    // The cross-ref, failing: no `(phrase :name chorus …)` is declared.
    try expectCode(&schema,
        \\(phrase :name fill :length 1bar (lane :name flash :kind notes))
        \\(lane :name flash :kind notes (clip :at 8bar :phrase chorus))
    , .not_cross_ref);
    // `:repeat` is a count.
    try expectCode(&schema,
        \\(phrase :name fill :length 1bar (lane :name flash :kind notes))
        \\(lane :name flash :kind notes (clip :at 8bar :phrase fill :repeat 0))
    , .number_below_min);
}

// ---------------------------------------------------------------------
// `(variant :when …)` on `lane :kind`
// ---------------------------------------------------------------------

test "tempura: the lane variants gate which keys exist" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    // Each kind's own key, on its own kind.
    try expectClean(&schema, "(lane :name hats :kind query :target hats :query (euclid 3 8 1))");
    try expectClean(
        &schema,
        "(lane :name pulse :kind formula :target pulse :expr (sin (* beat 6.2832)))",
    );
    try expectClean(&schema,
        \\(anchor :id song :kind it :file "x.it")
        \\(lane :name bass-vol :kind curve :from song :channel 5 :column vol :range [0 1])
    );
    try expectClean(&schema,
        \\(anchor :id song :kind smf :file "x.mid")
        \\(lane :name kick :kind notes :from song :track 2 :ch 10 :key 36)
    );

    // …and on any other kind it does not exist at all.
    try expectCode(&schema, "(lane :name hats :kind notes :query (euclid 3 8 1))", .unknown_key);
    try expectCode(&schema, "(lane :name pulse :kind curve :expr (sin beat))", .unknown_key);
    try expectCode(&schema, "(lane :name x :kind notes :column vol)", .unknown_key);
    try expectCode(&schema, "(lane :name x :kind curve :key 36)", .unknown_key);
    try expectCode(&schema, "(lane :name x :kind notes :range [0 1])", .unknown_key);
}

test "tempura: a bound curve lane addresses exactly one MIDI controller surface" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema,
        \\(anchor :id song :kind smf :file "x.mid")
        \\(lane :name cutoff :kind curve :from song :track 1 :ch 1 :cc 74 :range [0 1])
    );
    try expectClean(&schema,
        \\(anchor :id song :kind smf :file "x.mid")
        \\(lane :name morph :kind curve :from song :track 1 :ch 1 :cc [1 33])
    );
    try expectClean(&schema,
        \\(anchor :id song :kind smf :file "x.mid")
        \\(lane :name wobble :kind curve :from song :track 1 :ch 1 :bend true)
    );

    // Two surfaces at once is the group's whole job.
    try expectCode(&schema,
        \\(anchor :id song :kind smf :file "x.mid")
        \\(lane :name x :kind curve :from song :cc 74 :bend true)
    , .mutually_exclusive_keys_present);
    // …and an unbound curve lane needs none of them (at-most-one).
    try expectClean(
        &schema,
        "(lane :name glow :kind curve :target glow (keyframe :at 0q :value 1))",
    );
}

test "tempura: an IT curve lane's :fx is inert without the column that gives it meaning" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema,
        \\(anchor :id song :kind it :file "x.it")
        \\(lane :name sweep :kind curve :from song :channel 5 :column fx :fx "M")
    );

    // `:requires [column]` — "then also", one way.
    try expectCode(&schema,
        \\(anchor :id song :kind it :file "x.it")
        \\(lane :name sweep :kind curve :from song :channel 5 :fx "M")
    , .dependent_key_missing);
    // The column set is closed.
    try expectCode(&schema,
        \\(anchor :id song :kind it :file "x.it")
        \\(lane :name sweep :kind curve :from song :channel 5 :column pitch)
    , .not_member);
}

// ---------------------------------------------------------------------
// Cross-refs to `(anchor :id …)`
// ---------------------------------------------------------------------

test "tempura: :conductor and :from resolve against an anchor's id" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema,
        \\(timeline :conductor song)
        \\(anchor :id song :kind it :file "impulse-04.it")
        \\(lane :name kick :kind notes :from song :channel 3 :target kick)
    );

    try expectCode(&schema, "(timeline :conductor song)", .not_cross_ref);
    try expectCode(&schema,
        \\(anchor :id song :kind it :file "x.it")
        \\(lane :name kick :kind notes :from other)
    , .not_cross_ref);
}

// ---------------------------------------------------------------------
// The catalog covers the manifest, and the manifest covers the catalog
// ---------------------------------------------------------------------

/// Every form name the tempura plugin declares, globals first then the
/// slot-locals each carries, in declaration order.
fn tempuraFormNames(
    gpa: std.mem.Allocator,
    plugin: sjon.Plugin.Plugin,
) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    for (plugin.forms) |form| {
        try names.append(gpa, form.name);
        for (form.local_forms) |local| try names.append(gpa, local.name);
        for (form.keys) |key| {
            for (key.local_forms) |local| try names.append(gpa, local.name);
        }
    }
    return names;
}

test "tempura: the catalog and the manifest cover each other both ways" {
    const gpa = t_.allocator;

    var schema = try Schema.load(gpa);
    defer schema.deinit();

    const catalog_src = try readRepoFile(gpa, "schema/tempura-catalog.sjon");
    defer gpa.free(catalog_src);

    // The catalog is self-describing: it carries its own one-form
    // vocabulary, so `sjon check` reads it with no project wiring and
    // this test needs no sixth build import.
    var res = try sjon.validateDocument(gpa, catalog_src, .{});
    defer res.deinit();
    for (res.diagnostics) |d| {
        std.debug.print("catalog: {s}: {s}\n", .{ @tagName(d.code), d.message });
    }
    try t_.expectEqual(@as(usize, 0), res.diagnostics.len);

    var cataloged: std.ArrayList([]const u8) = .empty;
    defer cataloged.deinit(gpa);
    for (res.data_forest) |root| {
        const header = res.tree.formHeader(root);
        if (!std.mem.eql(u8, header.head, "entry")) continue;
        for (header.children) |child| {
            if (res.tree.tagOf(child) != .kvpair) continue;
            const kv = res.tree.kvpairHeader(child);
            if (!std.mem.eql(u8, kv.key, "form")) continue;
            try cataloged.append(gpa, res.tree.symbolText(kv.value));
        }
    }
    try t_.expect(cataloged.items.len > 0);

    var declared = try tempuraFormNames(gpa, schema.preloaded.plugins[0]);
    defer declared.deinit(gpa);

    // Manifest → catalog: every form has provenance.
    for (declared.items) |name| {
        var found = false;
        for (cataloged.items) |c| {
            if (std.mem.eql(u8, c, name)) found = true;
        }
        if (!found) {
            std.debug.print("form `{s}` has no catalog entry\n", .{name});
            return error.FormWithoutProvenance;
        }
    }
    // Catalog → manifest: no entry names a form that does not exist.
    for (cataloged.items) |name| {
        var found = false;
        for (declared.items) |d| {
            if (std.mem.eql(u8, d, name)) found = true;
        }
        if (!found) {
            std.debug.print("catalog entry `{s}` names no form\n", .{name});
            return error.CatalogEntryWithoutForm;
        }
    }
    try t_.expectEqual(declared.items.len, cataloged.items.len);
}

// ---------------------------------------------------------------------
// The hosted tiers
// ---------------------------------------------------------------------

/// The midi set's own two-track example (its 02, "The file document,
/// core tier"), heads bare.
const midi_example_bare =
    \\(smf :format 1 :division 480)
    \\
    \\(mtrk
    \\  (sequence-name  :at 0 :text "conductor")
    \\  (time-signature :at 0 :num 4 :denom 4 :clocks 24 :thirty-seconds 8)
    \\  (set-tempo      :at 0    :us 500000)
    \\  (set-tempo      :at 7680 :us 400000)
    \\  (marker         :at 7680 :text "drop")
    \\  (end-of-track   :at 15360))
    \\
    \\(mtrk
    \\  (sequence-name  :at 0 :text "drums")
    \\  (program-change :at 0 :ch 10 :num 0)
    \\  (note-on        :at 0    :ch 10 :key 36 :vel 110)
    \\  (note-off       :at 120  :ch 10 :key 36 :vel 0)
    \\  (control-change :at 0    :ch 10 :num 7 :val 100)
    \\  (pitch-bend     :at 240  :ch 10 :val 8192)
    \\  (sysex          :at 480  :data "F0 7E 7F 09 01 F7")
    \\  (end-of-track   :at 15360))
;

/// The same, with the two ROOT heads qualified — how a dumped `.mid`
/// rides inside a timeline document. The event heads stay bare: they are
/// slot-local to `mtrk`, and a qualified head bypasses locals.
const midi_example_qualified =
    \\(midi/smf :format 1 :division 480)
    \\
    \\(midi/mtrk
    \\  (sequence-name  :at 0 :text "conductor")
    \\  (time-signature :at 0 :num 4 :denom 4 :clocks 24 :thirty-seconds 8)
    \\  (set-tempo      :at 0    :us 500000)
    \\  (set-tempo      :at 7680 :us 400000)
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

test "midi: the set's two-track example validates bare and midi/-qualified" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema, midi_example_bare);
    try expectClean(&schema, midi_example_qualified);
}

test "midi: the core tier bounds its 7-bit fields and closes its channel range" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectCode(&schema, "(mtrk (note-on :at 0 :ch 17 :key 36 :vel 110))", .number_above_max);
    try expectCode(&schema, "(mtrk (note-on :at 0 :ch 1 :key 128 :vel 110))", .number_above_max);
    try expectCode(&schema, "(mtrk (pitch-bend :at 0 :ch 1 :val 16384))", .number_above_max);
    try expectCode(&schema, "(mtrk (set-tempo :at 0 :us 16777216))", .number_above_max);
    // `:at` is an absolute tick, never negative.
    try expectCode(&schema, "(mtrk (note-on :at -1 :ch 1 :key 36 :vel 1))", .number_below_min);
}

test "midi: ease-hint is typed against pacer's own easing names" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema, "(mtrk (ease-hint :at 0 :ch 1 :lane cc :num 74 :ease in-cubic))");
    try expectClean(
        &schema,
        "(mtrk (ease-hint :at 0 :ch 1 :lane bend :ease (spring :damping 0.5 :periods 3)))",
    );

    try expectCode(
        &schema,
        "(mtrk (ease-hint :at 0 :ch 1 :lane cc :num 74 :ease wobble))",
        .not_member,
    );
    try expectCode(
        &schema,
        "(mtrk (ease-hint :at 0 :ch 1 :lane pan :num 10 :ease linear))",
        .not_member,
    );
}

test "midi: the live tier is not hosted — note, midi-input, midi-output, midi-clock" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    // The `note` verb is midivia's live-tier sugar and is deliberately
    // absent from the hosted copy (plan 02, "The note collision") — the
    // head that DOES resolve is tempura's own, slot-local to a lane, so
    // at a root it is unknown.
    try expectCode(&schema, "(note :at 0 :ch 10 :key 36 :vel 110 :dur 120)", .unknown_form);
    try expectCode(&schema, "(midi-input :msg cc :ch 1 :num 74 :name cutoff)", .unknown_form);
    try expectCode(&schema, "(midi-output :msg cc :name lfo :ch 1 :num 74)", .unknown_form);
    try expectCode(&schema, "(midi-clock :out true :in false)", .unknown_form);
}

/// The it set's own module example (its 02, "Root and song-level forms"),
/// minus the prose ellipses.
const it_example_module =
    \\(module :title "acid groove"
    \\  (source :file "acid.it" :size 1284403 :sha256 "9f2a…")
    \\  (timing :speed 6 :tempo 125 :highlight [4 16])
    \\  (options :stereo true :instruments true :linear-slides true
    \\           :old-effects false :compat-gxx false
    \\           :global-vol 128 :mix-vol 48 :pan-separation 128
    \\           :pitch-wheel-depth 0)
    \\  (channels
    \\    (ch 1 :pan 32 :vol 64)
    \\    (ch 2 :pan 16)
    \\    (ch 3 :pan 48 :muted true)
    \\    (ch 4 :surround true))
    \\  (orders 0 1 2 1 skip 3 end)
    \\  (message """a groove"""))
;

const it_example_instrument =
    \\(instrument 1 :name "poly bass"
    \\  :nna continue :dct instrument :dca fade
    \\  :fadeout 96
    \\  :global-vol 128 :pan 32
    \\  :pitch-pan [0 60]
    \\  :swing [12 0]
    \\  :filter [74 nil]
    \\  :midi (midi-out :channel 1 :program 33 :bank nil)
    \\  (notemap :sample 2)
    \\  (vol-env :sustain [2 2]
    \\    (node 0 64) (node 12 48) (node 40 0))
    \\  (pan-env :off true)
    \\  (pitch-env :filter true))
;

const it_example_sample =
    \\(sample 2 :name "bass loop" :c5 44100
    \\  :vol 64 :global-vol 64 :pan nil
    \\  :loop [0 35000] :loop-mode pingpong
    \\  :sustain-loop [1000 2000] :sustain-mode forward
    \\  :vibrato (vibrato :speed 4 :depth 2 :rate 16 :wave sine)
    \\  (data :bits 16 :enc it214 (bin :at 34600 :len 12842)))
;

const it_example_pattern =
    \\(pattern 0 :rows 64
    \\  (row 0  (ev 1 "C-5" :ins 2 :vol 64 :fx "SD1")
    \\          (ev 2 "G-5" :ins 2 :vol 40))
    \\  (row 4  (ev 1 off))
    \\  (row 8  (ev 1 "C-5" :ins 2 :fx "GFF")
    \\          (ev 4 :fx "T80")))
;

test "it: the set's own examples validate" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema, it_example_module);
    try expectClean(&schema, it_example_instrument);
    try expectClean(&schema, it_example_sample);
    try expectClean(&schema, it_example_pattern);
    // The notemap's range shorthand, and the skeleton-dump pattern.
    try expectClean(&schema,
        \\(instrument 1 :name "split"
        \\  (notemap (range "C-0" "B-4" :sample 1)
        \\           (range "C-5" "B-9" :sample 2 :transpose 12)))
    );
    try expectClean(&schema, "(pattern 3 :rows 64 (bin :at 0x8728 :len 0x322A))");
}

test "it: the module tier rides inside a timeline document, it/-qualified" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    // Plan 02's own example document: the anchor, then the dump. The
    // children of `it/module` are qualified in the plan's spelling; the
    // leaf forms (`row`, `ev`, `data`, `bin`) stay bare, being slot-local.
    try expectClean(&schema,
        \\(timeline :title "impulsos" :length 128bar :end loop :conductor song)
        \\(anchor :id song :kind it :file "impulse-04.it" :size 1284403 :sha256 "9f2a…")
        \\(it/module :title "impulse 04"
        \\  (it/timing :speed 6 :tempo 125 :highlight [4 16])
        \\  (it/orders 0 1 2 1 skip 3 end)
        \\  (it/pattern 0 :rows 64 (row 0 (ev 3 "C-5" :ins 2 :vol 64)))
        \\  (it/sample 2 :name "bass loop" (data :bits 16 :enc it214 (bin :at 34600 :len 12842))))
    );
}

test "it: tempura's :raw opaque-body key rides on instrument and sample" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    // Plan 06, "The binary model": tempura keeps instruments and samples
    // opaque, so the hosted manifest gains one key the it set's does not.
    try expectClean(&schema,
        \\(it/instrument 1 :name "poly bass" :raw (bin :at 0x8728 :len 554))
    );
    try expectClean(&schema,
        \\(it/sample 2 :name "bass loop" :raw (bin :at 0x8A00 :len 80)
        \\  (data :bits 16 :enc it214 (bin :at 0x8A50 :len 12842)))
    );
}

test "it: the value kinds refuse what IT cannot hold" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectCode(&schema, "(pattern 0 :rows 64 (row 0 (ev 65 \"C-5\")))", .number_above_max);
    // The volume column is a union, and its arms are disjoint by node
    // shape — so a number out of range reports the BOUND it broke rather
    // than collapsing into "no alternative matched" (the it set's
    // amendment 7 is exactly about this report).
    try expectCode(
        &schema,
        "(pattern 0 :rows 64 (row 0 (ev 1 \"C-5\" :ins 2 :vol 100)))",
        .number_above_max,
    );
    // …and a shape neither arm reaches keeps the collapsed code.
    try expectCode(
        &schema,
        "(pattern 0 :rows 64 (row 0 (ev 1 \"C-5\" :vol [0 1])))",
        .union_no_branch_matched,
    );
    try expectCode(&schema, "(instrument 1 :nna bounce)", .not_member);
    try expectCode(&schema, "(sample 2 :loop-mode pingpong)", .dependent_key_missing);
    // A bare count never carries a unit (amendment 6).
    try expectCode(&schema, "(instrument 1 :global-vol 64hz)", .unit_forbidden);
}

test "it: (bin …) takes an offset or a file, never both" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    try expectClean(&schema, "(pattern 3 :rows 64 (bin :file \"pat3.bin\"))");
    try expectCode(
        &schema,
        "(pattern 3 :rows 64 (bin :at 0x10 :len 4 :file \"x\"))",
        .mutually_exclusive_keys_present,
    );
    try expectCode(&schema, "(pattern 3 :rows 64 (bin :len 4))", .dependent_key_missing);
}

// ---------------------------------------------------------------------
// The shipped example, and the sibling heads
// ---------------------------------------------------------------------

test "tempura: examples/native.sjon validates clean" {
    const gpa = t_.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    const src = try readRepoFile(gpa, "examples/native.sjon");
    defer gpa.free(src);

    try expectClean(&schema, src);
}

test "tempura: no head this set declares collides with a sibling vocabulary" {
    const gpa = t_.allocator;

    // Every sibling manifest that exists on this machine. Absent ones are
    // skipped by name so the reason is readable rather than silent.
    const candidates = [_][]const u8{
        "pngine/schema/pngine.sjon",
        "animader/animader/docs/data/schema.sjon",
        "batida/schema/it.sjon",
        "midivia/schema/midi.sjon",
        "midivia/schema/midi-map.sjon",
    };

    // Two lists: `owned` holds what was read off disk (freed here), while
    // `sources` interleaves those with the embedded manifests (freed by
    // nobody — they are `@embedFile` constants).
    var owned: std.ArrayList([:0]u8) = .empty;
    defer {
        for (owned.items) |s| gpa.free(s);
        owned.deinit(gpa);
    }
    var sources: std.ArrayList([:0]const u8) = .empty;
    defer sources.deinit(gpa);
    for (Schema.timeline_manifest_srcs) |s| try sources.append(gpa, s);

    var absent: usize = 0;
    for (candidates) |rel| {
        if (try readSiblingFile(gpa, rel)) |src| {
            try owned.append(gpa, src);
            try sources.append(gpa, src);
        } else absent += 1;
    }
    // Silence is the normal path — a machine that holds only some of the
    // constellation still cross-checks against the ones it has. A machine
    // that holds none has nothing to say about collisions, and says so
    // once rather than staying quiet about a check that did not run.
    if (owned.items.len == 0) {
        std.debug.print(
            "sibling-heads: none of the {d} sibling manifests is checked out beside this repo — " ++
                "nothing to cross-check\n",
            .{absent},
        );
        return error.SkipZigTest;
    }

    var composed = try Schema.loadSourcesUnchecked(gpa, sources.items);
    defer composed.deinit();

    // Not "nothing in this aggregate is ambiguous" — the siblings collide
    // with each other in ways that are theirs to resolve (pngine and pacer
    // both declared `target` until pngine's 2026-09-04 rename to
    // `color-target`; the one same-name pair that remains, `stage`, is
    // slot-local on both sides and plan 02's table classifies it as
    // non-colliding). The claim is about THIS set: every head tempura,
    // midi and it declare still resolves to exactly one form when every
    // sibling is in the room.
    var schema = try Schema.load(gpa);
    defer schema.deinit();
    for (schema.preloaded.plugins) |plugin| {
        if (std.mem.eql(u8, plugin.name, "pacer")) continue; // not ours to defend
        for (plugin.forms) |form| {
            switch (composed.preloaded.schema.lookupForm(form.name, null)) {
                .found => {},
                .not_found => {
                    std.debug.print(
                        "{s}/{s} vanished from the composed schema\n",
                        .{ plugin.name, form.name },
                    );
                    return error.HeadNotFound;
                },
                .ambiguous => {
                    std.debug.print(
                        "{s}/{s} is ambiguous against a sibling vocabulary\n",
                        .{ plugin.name, form.name },
                    );
                    return error.SiblingHeadCollision;
                },
            }
        }
    }
}

// ---------------------------------------------------------------------
// The animader composition: the sibling's live manifests in the same
// aggregate (the 2026-10-15 `frame-rate` collision's regression)
// ---------------------------------------------------------------------

/// animader's `schema/*.sjon` manifests, read and sorted by name, when
/// a checkout is discoverable; `null` when absent — announced by ONE
/// printed line naming the override and the candidate, so absence is a
/// fact and never silence. `override_root` is `TEMPURA_ANIMADER`'s
/// value as `build.zig` read it (`null` when unset); a relative
/// override resolves against the repo root, an absolute one is taken as
/// is, and one that points nowhere is an ABSENCE — no fallback to the
/// workspace default, so a typo'd override cannot quietly compose the
/// default checkout instead. The caller frees the slice and each source.
fn animaderManifests(
    gpa: std.mem.Allocator,
    override_root: ?[]const u8,
) !?[][:0]u8 {
    const repo_root = @import("build_options").repo_root;

    var root: []u8 = undefined;
    if (override_root) |over| {
        root = if (std.fs.path.isAbsolute(over))
            try gpa.dupe(u8, over)
        else
            try std.fs.path.join(gpa, &.{ repo_root, over });
    } else {
        root = try std.fs.path.join(gpa, &.{ repo_root, "..", "animader", "animader" });
    }
    defer gpa.free(root);
    const schema_dir = try std.fs.path.join(gpa, &.{ root, "schema" });
    defer gpa.free(schema_dir);

    var dir = std.Io.Dir.cwd().openDir(t_.io, schema_dir, .{ .iterate = true }) catch {
        std.debug.print(
            "sibling-compose: no animader checkout — TEMPURA_ANIMADER={s}, " ++
                "candidate `{s}` not found; point the override at a checkout " ++
                "(or check the sibling out) — SKIPPING, nothing composed, nothing claimed\n",
            .{ override_root orelse "(unset)", schema_dir },
        );
        return null;
    };
    defer dir.close(t_.io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    // Bounded by the directory's own entries, walked once.
    while (try it.next(t_.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sjon")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    // A checkout whose schema/ holds no manifest is broken, not absent —
    // composing zero manifests would claim cleanliness vacuously.
    if (names.items.len == 0) return error.EmptySiblingSchemaDir;
    std.mem.sort([]u8, names.items, {}, nameBefore);

    const sources = try gpa.alloc([:0]u8, names.items.len);
    errdefer {
        for (sources) |s| gpa.free(s);
        gpa.free(sources);
    }
    for (names.items, sources) |name, *src| {
        const path = try std.fs.path.join(gpa, &.{ schema_dir, name });
        defer gpa.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            t_.io,
            path,
            gpa,
            .limited(8 * 1024 * 1024),
        );
        defer gpa.free(bytes);
        src.* = try gpa.dupeZ(u8, bytes);
    }
    return sources;
}

fn nameBefore(_: void, x: []u8, y: []u8) bool {
    return std.mem.lessThan(u8, x, y);
}

test "tempura: the animader composition preloads with zero diagnostics" {
    // tempura's bundle and animader's vocabulary load in ONE aggregate
    // inside animader's piece loader, and a kind name claimed by both
    // plugins is `ambiguous_element_kind` on every reference to it — the
    // T2 `frame-rate` collision landed with every tempura gate green
    // precisely because nothing here composed the two sets. This leg
    // does, through the same preload walk the runtime runs
    // (`preloadSchema`'s aggregate validators), and claims ZERO
    // diagnostics — the strength of animader's own preload test, from
    // the declaring side. The sibling's manifests are DISCOVERED, not
    // pinned: every `schema/*.sjon` joins, so a manifest added there
    // composes here the day it lands.
    const gpa = t_.allocator;

    const sources = (try animaderManifests(
        gpa,
        @import("build_options").animader_root,
    )) orelse return error.SkipZigTest; // the loud line above said why
    defer {
        for (sources) |s| gpa.free(s);
        gpa.free(sources);
    }

    var all: std.ArrayList([:0]const u8) = .empty;
    defer all.deinit(gpa);
    for (Schema.timeline_manifest_srcs) |s| try all.append(gpa, s);
    for (sources) |s| try all.append(gpa, s);

    var composed = try Schema.loadSourcesUnchecked(gpa, all.items);
    defer composed.deinit();

    for (composed.preloaded.diagnostics) |d| {
        std.debug.print("animader composition: {s} {s}: {s}\n", .{
            @tagName(d.phase), @tagName(d.code), d.message,
        });
    }
    try t_.expectEqual(@as(usize, 0), composed.preloaded.diagnostics.len);

    // The composition actually composed: the sibling's five manifests
    // beside tempura's four (nine plugins), one of animader's own heads
    // resolvable bare, and every head tempura declares still resolving
    // qualified with the sibling in the room.
    try t_.expectEqual(
        @as(usize, Schema.timeline_manifest_srcs.len + sources.len),
        composed.preloaded.plugins.len,
    );
    try t_.expect(
        composed.preloaded.schema.lookupForm("frame-clock", null) == .found,
    );
    var own = try Schema.load(gpa);
    defer own.deinit();
    for (own.preloaded.plugins) |plugin| {
        for (plugin.forms) |form| {
            try t_.expect(
                composed.preloaded.schema.lookupForm(form.name, plugin.name) == .found,
            );
        }
    }
}

test "tempura: an absent animader checkout is a loud skip, not a pass" {
    // The other half of the leg's contract: a machine without the
    // sibling (a fresh clone, CI, or a `TEMPURA_ANIMADER` that points
    // nowhere — the forced case here) must answer ABSENT, and the
    // composition test then skips rather than claims anything. A
    // present-but-wrong override never falls back to the default
    // candidate, and a checkout is never "present but empty".
    const gpa = t_.allocator;
    const sources = try animaderManifests(gpa, "no-such-animader-checkout");
    try t_.expect(sources == null);
}

// ---------------------------------------------------------------------
// The collision table, and the prose that renders the docs page
// ---------------------------------------------------------------------

test "tempura: the four composed manifests share no head" {
    // Plan 02's collision table as a check rather than a claim. A
    // duplicate head is not a LOAD failure — the aggregate is happy to
    // hold two forms called `track` — so `Schema.load`'s clean-preload
    // assert would not catch it. It shows up only at lookup, as
    // `ambiguous_form` on a document that spells the head bare, which is
    // every document.
    const gpa = t_.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    var seen: usize = 0;
    for (schema.preloaded.plugins) |plugin| {
        for (plugin.forms) |form| {
            seen += 1;
            switch (schema.preloaded.schema.lookupForm(form.name, null)) {
                .found => {},
                .not_found => {
                    std.debug.print("{s}/{s} does not resolve bare\n", .{ plugin.name, form.name });
                    return error.HeadNotFound;
                },
                .ambiguous => {
                    std.debug.print(
                        "{s}/{s} is declared twice across the four manifests\n",
                        .{ plugin.name, form.name },
                    );
                    return error.HeadCollision;
                },
            }
        }
    }
    // tempura's eight, midi's two, it's fourteen, pacer's twelve.
    try t_.expectEqual(@as(usize, 36), seen);
}

test "tempura: every form, key, kind and member carries the prose the docs page renders" {
    // `docs/timeline-language.md` IS these `:description`s — the page has
    // no other source. A key added without one renders as a blank cell,
    // and `zig build docs` would happily regenerate the blank. So the
    // manifest's own completeness is the check, not the page's.
    //
    // Every manifest tempura OWNS is held to it, members included: the
    // timeline tier, the two hosted tiers, the harness and the catalog.
    // `schema/pacer.sjon` is exempt because it is a VERBATIM copy —
    // holding a drift-gated file to this repo's prose standard would mean
    // editing it, which is the one thing that file forbids.
    const gpa = t_.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    for (schema.preloaded.plugins) |plugin| {
        if (std.mem.eql(u8, plugin.name, "pacer")) continue;
        try expectPluginDescribed(plugin);
    }

    var corpus = try Schema.loadCorpus(gpa);
    defer corpus.deinit();
    try expectPluginDescribed(corpus.preloaded.plugins[0]);

    // The catalog carries its vocabulary inline rather than as a preload,
    // so it arrives through the document pipeline.
    const catalog_src = try readRepoFile(gpa, "schema/tempura-catalog.sjon");
    defer gpa.free(catalog_src);
    var res = try sjon.validateDocument(gpa, catalog_src, .{});
    defer res.deinit();
    try t_.expectEqual(@as(usize, 1), res.plugins.len);
    try expectPluginDescribed(res.plugins[0]);
}

fn expectPluginDescribed(plugin: sjon.Plugin.Plugin) DescribeError!void {
    for (plugin.value_kinds) |kind| {
        if (kind.description.len == 0) {
            std.debug.print(
                "value-kind `{s}` of `{s}` has no :description\n",
                .{ kind.name, plugin.name },
            );
            return error.MissingDescription;
        }
        // A member set is a closed vocabulary the page prints one line
        // per entry of, so an undescribed member is a blank line there.
        if (kind.members) |set| {
            for (set.members) |member| {
                if (member.description.len == 0) {
                    std.debug.print(
                        "member `{s}` of value-kind `{s}` of `{s}` has no :description\n",
                        .{ member.name, kind.name, plugin.name },
                    );
                    return error.MissingDescription;
                }
            }
        }
    }
    for (plugin.forms) |form| try expectFormDescribed(form);
}

const DescribeError = error{MissingDescription};

fn expectFormDescribed(form: sjon.Plugin.FormSpec) DescribeError!void {
    if (form.description.len == 0) {
        std.debug.print("form `{s}` has no :description\n", .{form.name});
        return error.MissingDescription;
    }
    for (form.keys) |key| try expectKeyDescribed(form, key);
    if (form.variants) |variants| {
        for (variants) |variant| {
            for (variant.keys) |key| try expectKeyDescribed(form, key);
        }
    }
    for (form.local_forms) |local| try expectFormDescribed(local);
}

fn expectKeyDescribed(form: sjon.Plugin.FormSpec, key: sjon.Plugin.KeySpec) DescribeError!void {
    if (key.description.len == 0) {
        std.debug.print("key `{s}` of form `{s}` has no :description\n", .{ key.name, form.name });
        return error.MissingDescription;
    }
    for (key.local_forms) |local| try expectFormDescribed(local);
}

// ---------------------------------------------------------------------
// The it tier's positional slots: an id AND a child set, both narrowed
// ---------------------------------------------------------------------

test "it: a form's leading id is bounded even though child forms share the slot" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    // The slot is a union over [<id kind> <head-set kind>], whose arms are
    // disjoint by node shape — so a number reaches only the id arm and
    // fails with the id's own bound (manifest spec §4.9), while a form
    // still resolves its slot-local body.
    try expectCode(&schema, "(pattern 500 :rows 64)", .number_above_max);
    try expectCode(&schema, "(instrument 999 :name \"over\")", .number_above_max);
    try expectCode(&schema, "(sample 0 :name \"under\")", .number_below_min);

    // …and the ids that are in range still validate.
    try expectClean(&schema, "(pattern 199 :rows 64)");
    try expectClean(&schema, "(instrument 99 :name \"last\")");
    try expectClean(&schema, "(sample 1 :name \"first\")");
}

test "it: a foreign head or a foreign shape in a positional slot is refused" {
    var schema = try Schema.load(t_.allocator);
    defer schema.deinit();

    // A form reaches only the head-set arm, so an out-of-set head is that
    // arm's own not_head_member; a string reaches neither arm and keeps
    // the collapsed code.
    try expectCode(&schema, "(pattern 0 (timing :speed 6) \"junk\" 12345)", .not_head_member);
    try expectCode(
        &schema,
        "(pattern 0 (timing :speed 6) \"junk\" 12345)",
        .union_no_branch_matched,
    );
    try expectCode(&schema, "(pattern 0 (timing :speed 6) \"junk\" 12345)", .number_above_max);
    try expectCode(
        &schema,
        "(pattern 0 (row 0 (ev 1 \"C-5\") \"junk\"))",
        .union_no_branch_matched,
    );
    // A head outside the set that IS a form somewhere reports the
    // narrowing's code; one that is nowhere in scope at this slot reports
    // the descent's. Both refuse it, which is the point — `:positional
    // any` refused neither.
    try expectCode(&schema, "(instrument 1 (pattern 0))", .not_head_member);
    // The two KEY-local slots — `:vibrato` and `:midi` — are `:type form`
    // rather than a head-set kind, because a key carrying inline locals
    // must be form-typed. The local is the narrowing all the same: the
    // right head resolves the body, and a foreign one is refused with a
    // message that names the set it had to be in.
    try expectClean(&schema, "(sample 1 :vibrato (vibrato :speed 4 :wave sine))");
    try expectCode(&schema, "(sample 1 :vibrato (data :bits 8))", .unknown_local_form);
    try expectCode(&schema, "(instrument 1 :midi (vibrato :speed 4))", .unknown_local_form);
    try expectCode(&schema, "(instrument 1 (data :bits 16))", .unknown_local_form);
    try expectCode(&schema, "(sample 1 (row 0))", .unknown_local_form);
}

test "it: a notemap takes the raw 120-pair table as well as ranges" {
    const gpa = t_.allocator;
    var schema = try Schema.load(gpa);
    defer schema.deinit();

    // it 02's escape hatch: 120 [note sample] pairs written out flat.
    // Built here rather than pasted so the two documents differ in
    // exactly the one element the test is about.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "(instrument 1 (notemap [");
    for (0..120) |i| {
        try buf.print(gpa, "{d} 2 ", .{i});
    }
    const short_at = buf.items.len - 2; // drop the trailing "2 " for 239
    try buf.appendSlice(gpa, "]))");
    const full = try gpa.dupeZ(u8, buf.items);
    defer gpa.free(full);
    try expectClean(&schema, full);

    var short: std.ArrayList(u8) = .empty;
    defer short.deinit(gpa);
    try short.appendSlice(gpa, buf.items[0..short_at]);
    try short.appendSlice(gpa, "]))");
    const short_z = try gpa.dupeZ(u8, short.items);
    defer gpa.free(short_z);
    try expectCode(&schema, short_z, .vector_length_mismatch);
}
