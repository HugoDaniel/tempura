//! One document, three ways, for this part's tests.
//!
//! Every test here starts from the same three values: the SOURCE (the
//! bytes an edit splices into), the `Doc` (what an operation reads), and
//! the TREE (where the addresses come from). `Fixture` loads all three
//! from one string and frees them in the one order the schema's
//! borrow-whole rule allows.
//!
//! Test-only, and named so: it raises no diagnostic and nothing in the
//! library imports it.

const std = @import("std");
const sjon = @import("sjon");

const Schema = @import("../Schema.zig");
const doc = @import("../doc/doc.zig");

const Plan = @import("Plan.zig");
const apply = @import("apply.zig");

pub const Fixture = struct {
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    schema: Schema,
    loaded: doc.Result,
    tree: sjon.Ast.Tree,

    /// Load `source`. Asserts the document is clean: a fixture that does
    /// not validate is a defect in the TEST, and a test that plans over a
    /// broken document would be asserting about the recovery.
    pub fn init(gpa: std.mem.Allocator, source: [:0]const u8) !Fixture {
        var schema = try Schema.load(gpa);
        errdefer schema.deinit();

        var loaded = try doc.fromSource(gpa, &schema, source, null);
        errdefer loaded.deinit();
        if (loaded.diags.hasErrors()) {
            for (loaded.diags.items()) |d| {
                std.debug.print("fixture: {s}: {s}\n", .{ @tagName(d.code), d.message });
            }
            return error.FixtureDocumentHasErrors;
        }

        var tree = try sjon.parse(gpa, source);
        errdefer tree.deinit();
        if (tree.hasErrors()) return error.FixtureSourceHasErrors;

        return .{
            .gpa = gpa,
            .source = source,
            .schema = schema,
            .loaded = loaded,
            .tree = tree,
        };
    }

    /// Load `source` WITHOUT the clean-document assertion.
    ///
    /// For the two guards that only a defective document can reach: a
    /// lane that carries its own content BESIDE a `:from` is
    /// `bound_lane_has_content` at load, and `unbind` and `materialize`
    /// refuse it with `edit_would_duplicate` — a plan is total over
    /// whatever document a host hands it, including one it has already
    /// complained about.
    pub fn initUnchecked(gpa: std.mem.Allocator, source: [:0]const u8) !Fixture {
        var schema = try Schema.load(gpa);
        errdefer schema.deinit();

        var loaded = try doc.fromSource(gpa, &schema, source, null);
        errdefer loaded.deinit();

        var tree = try sjon.parse(gpa, source);
        errdefer tree.deinit();
        if (tree.hasErrors()) return error.FixtureSourceHasErrors;

        return .{
            .gpa = gpa,
            .source = source,
            .schema = schema,
            .loaded = loaded,
            .tree = tree,
        };
    }

    pub fn deinit(self: *Fixture) void {
        self.tree.deinit();
        self.loaded.deinit();
        self.schema.deinit();
        self.* = undefined;
    }

    pub fn doc_(self: *const Fixture) *const doc.Doc {
        return &self.loaded.doc;
    }
};

/// A plan applied to the source it was planned over, and the document
/// that came out loaded again — plan 07's contract as a test step. A
/// REFUSED plan is diagnostics and an ACCEPTED plan is applicable, so
/// the text an accepted plan produces has to load clean; a test that
/// pinned the actions alone would be asserting the planner's intent
/// and not the document it leaves behind.
///
/// `init` fails the test — printing the diagnostics — when the splice
/// is refused or the reload reports an error.
pub const Reloaded = struct {
    applied: apply.Applied,
    fixture: Fixture,

    pub fn init(gpa: std.mem.Allocator, source: [:0]const u8, p: *const Plan.Plan) !Reloaded {
        var applied = try apply.apply(gpa, source, p);
        errdefer applied.deinit();
        if (applied.diags.hasErrors()) {
            for (applied.diags.items()) |d| {
                std.debug.print("apply: {s}: {s}\n", .{ @tagName(d.code), d.message });
            }
            return error.ApplyRefused;
        }
        // `Fixture.init` is the clean-document assertion, and the text
        // it borrows lives in `applied`'s arena for as long as this does.
        const fixture = try Fixture.init(gpa, applied.text);
        return .{ .applied = applied, .fixture = fixture };
    }

    pub fn deinit(self: *Reloaded) void {
        self.fixture.deinit();
        self.applied.deinit();
        self.* = undefined;
    }

    pub fn doc_(self: *const Reloaded) *const doc.Doc {
        return self.fixture.doc_();
    }

    pub fn text(self: *const Reloaded) []const u8 {
        return self.applied.text;
    }
};

/// The native document every operation is exercised against: two native
/// lanes with the three child kinds, a bound lane, a phrase, the two
/// roots a `Select` reaches (a section and a cue), and comments in the
/// places an edit must not disturb.
pub const native: [:0]const u8 =
    \\; impulsos — the native fixture
    \\(timeline :title "impulsos" :length 8bar :end loop)
    \\
    \\(tempo-point :at 0q :qpm 120)
    \\(meter-point :at 0bar :sig [4 4])
    \\
    \\(anchor :id song :kind it :file "impulse-04.it")
    \\
    \\(section :name intro :at 0bar :dur 4bar)
    \\(cue :name "the drop" :at 4bar)
    \\
    \\(lane :name flash :target flash
    \\  ; the downbeat
    \\  (note :at 0q :dur 0.5q :key 36 :vel 110)
    \\  (note :at 1q :dur 0.5q :key 60 :vel 90)
    \\  (note :at 2q :dur 0.5q :key 36 :vel 80)
    \\  (clip :at 4q :phrase fill :repeat 2))
    \\(lane :name glow :kind curve :target glow
    \\  (keyframe :at 0q :value 0.2 :ease hold)
    \\  (keyframe :at 4q :value 0.9 :ease in-cubic))
    \\(lane :name kick :kind notes :from song :channel 3)
    \\
    \\(phrase :name fill :length 1bar
    \\  (lane :name flash
    \\    (note :at 0q :dur 0.25q :key 38 :vel 100)))
    \\
    \\(target :name glow :arity 1)
    \\
;

/// A second, smaller document: two adjacent clips of one phrase, and an
/// empty native lane. The shapes `merge` and `bind` need, which the
/// native fixture has no room for.
pub const clips: [:0]const u8 =
    \\(timeline :length 4bar)
    \\(tempo-point :at 0q :qpm 120)
    \\(meter-point :at 0bar :sig [4 4])
    \\(anchor :id song :kind it :file "impulse-04.it")
    \\
    \\(lane :name flash
    \\  (clip :at 0bar :phrase fill :length 1bar)
    \\  (clip :at 1bar :phrase fill :offset 1bar :length 1bar))
    \\(lane :name spare)
    \\
    \\(phrase :name fill :length 1bar
    \\  (lane :name flash
    \\    (note :at 0q :dur 0.25q :key 38 :vel 100)))
    \\
;

/// A document CONDUCTED by an inline SMF dump. The file says `[3 4]`, so
/// a `bar` here is three quarter notes and not four — which is how a test
/// tells the document's own map from the 120-qpm `[4 4]` placeholder a
/// conducted document would otherwise be spelled under.
pub const conducted: [:0]const u8 =
    \\(timeline :conductor song)
    \\(anchor :id song :kind smf :file "x.mid")
    \\(midi/smf :format 1 :division 480)
    \\(midi/mtrk
    \\  (time-signature :at 0 :num 3 :denom 4 :clocks 24 :thirty-seconds 8)
    \\  (set-tempo :at 0 :us 500000)
    \\  (end-of-track :at 1920))
    \\
    \\(cue :name "two" :at 1bar)
    \\(lane :name flash
    \\  (note :at 0q :dur 1q :key 36))
    \\
;

/// Four notes in one lane, evenly spaced: the shape a multi-target move
/// is asked about, where two of them cross the two that stay.
pub const four: [:0]const u8 =
    \\(timeline :length 1bar)
    \\(tempo-point :at 0q :qpm 120)
    \\(meter-point :at 0bar :sig [4 4])
    \\
    \\(lane :name flash
    \\  (note :at 0q :dur 0.25q :key 36)
    \\  (note :at 1q :dur 0.25q :key 38)
    \\  (note :at 2q :dur 0.25q :key 40)
    \\  (note :at 3q :dur 0.25q :key 41))
    \\
;

/// A lane the printer did not write: its notes are not sorted by `:at`.
/// Legal — the schema does not require the order and plan 07 says a plan
/// never reorders a document it did not write.
pub const unsorted: [:0]const u8 =
    \\(timeline :length 1bar)
    \\(tempo-point :at 0q :qpm 120)
    \\(meter-point :at 0bar :sig [4 4])
    \\
    \\(lane :name flash
    \\  (note :at 2q :dur 0.6q :key 36)
    \\  (note :at 0.4q :dur 0.6q :key 38))
    \\
;

/// A clip whose window does not fit an `i64`: a phrase two ticks under
/// the grid ceiling, placed with a `:repeat` the manifest puts no
/// maximum on. The phrase's lane is empty, so the document places
/// nothing and loads clean — the overflow was in the selection alone.
pub const wide_clip: [:0]const u8 =
    \\(timeline :length 1bar)
    \\(tempo-point :at 0q :qpm 120)
    \\(meter-point :at 0bar :sig [4 4])
    \\
    \\(lane :name flash
    \\  (clip :at 0q :phrase huge :repeat 2000))
    \\
    \\(phrase :name huge :length 9007199254740990t
    \\  (lane :name flash))
    \\
;

/// Two notes on ONE key that do not overlap where they are and would if
/// they were quantized onto the same line.
pub const crossing: [:0]const u8 =
    \\(timeline :length 1bar)
    \\(tempo-point :at 0q :qpm 120)
    \\(meter-point :at 0bar :sig [4 4])
    \\
    \\(lane :name flash
    \\  (note :at 0.4q :dur 0.1q :key 36)
    \\  (note :at 0.6q :dur 0.1q :key 36))
    \\
;

/// A document whose one anchor is an INLINE `.mid` — the shape every
/// bound SMF operation is exercised against (plan 07, "Bound content,
/// precisely").
///
/// One track at 480 PPQ with three notes on channel 1 and a controller
/// the `filter` lane reads: a note whose neighbours leave it room to
/// move in place, one that has to cross the controller and the third
/// note to reach its destination, and two `(control-change …)` events so
/// a curve lane has steps of its own. The comment above the downbeat is
/// there to be watched: a move that keeps the sorted order keeps it, and
/// one that does not takes it along (plan 07's risk note).
pub const bound_smf: [:0]const u8 =
    \\; bound — the SMF fixture
    \\(timeline :title "bound" :conductor song :length 2bar)
    \\
    \\(anchor :id song :kind smf :file "x.mid")
    \\(midi/smf :format 0 :division 480)
    \\(midi/mtrk
    \\  (set-tempo      :at 0    :us 500000)
    \\  (control-change :at 0    :ch 1 :num 74 :val 10)
    \\  ; the downbeat
    \\  (note-on        :at 0    :ch 1 :key 36 :vel 100)
    \\  (note-off       :at 240  :ch 1 :key 36 :vel 64)
    \\  (note-on        :at 480  :ch 1 :key 38 :vel 90)
    \\  (note-off       :at 720  :ch 1 :key 38 :vel 64)
    \\  (control-change :at 960  :ch 1 :num 74 :val 100)
    \\  (note-on        :at 960  :ch 1 :key 41 :vel 80)
    \\  (note-off       :at 1200 :ch 1 :key 41 :vel 64)
    \\  (end-of-track   :at 1920))
    \\
    \\(lane :name kick :kind notes :from song :track 1 :ch 1)
    \\(lane :name filter :kind curve :from song :track 1 :ch 1 :cc 74)
    \\(lane :name wide :kind curve :from song :track 1 :ch 1 :cc [98 30])
    \\(lane :name dynamics :kind curve :from song :track 1 :ch 1 :velocity true)
    \\
;

/// The SMF fixture with the binding and content plan 04 forbids on one
/// lane. It does not validate — `bound_lane_has_content` — and it is
/// loaded with `Fixture.initUnchecked`, because the two operations that
/// refuse `edit_would_duplicate` are exactly the ones a valid document
/// can never put the question to.
pub const bound_smf_two_homes: [:0]const u8 =
    \\(timeline :title "bound" :conductor song :length 2bar)
    \\
    \\(anchor :id song :kind smf :file "x.mid")
    \\(midi/smf :format 0 :division 480)
    \\(midi/mtrk
    \\  (note-on      :at 0   :ch 1 :key 36 :vel 100)
    \\  (note-off     :at 240 :ch 1 :key 36 :vel 64)
    \\  (end-of-track :at 1920))
    \\
    \\(lane :name kick :kind notes :from song :track 1 :ch 1
    \\  (note :at 0q :dur 0.5q :key 36 :vel 100))
    \\
;

/// A document whose one anchor is an INLINE `.it`, with a SHARED
/// pattern: the order list plays pattern 2 twice, so a cell moved into
/// it sounds at both places — plan 07's `edit_pattern_shared`.
///
/// Speed 24 makes a row one quarter note exactly (24 IT ticks · 1 921 920
/// = TPQ), so every position a test asks for is a round musical number.
/// The first cell carries an effect, the second carries none: one has no
/// room for the `SDx` a sub-row move needs and the other does.
pub const bound_it: [:0]const u8 =
    \\; bound — the IT fixture
    \\(timeline :title "bound" :conductor mod :length 4bar)
    \\
    \\(anchor :id mod :kind it :file "x.it")
    \\(it/module :title "bound"
    \\  (it/timing :speed 24 :tempo 125)
    \\  (it/orders 0 1 2 2 end)
    \\  (it/pattern 0 :rows 4
    \\    (row 0 (ev 1 "C-5" :ins 1 :vol 64 :fx "G01"))
    \\    (row 2 (ev 1 "E-5" :ins 1)))
    \\  (it/pattern 1 :rows 4
    \\    (row 0 (ev 1 "G-5" :ins 1)))
    \\  (it/pattern 2 :rows 4))
    \\
    \\(lane :name lead :kind notes :from mod :channel 1)
    \\(lane :name loud :kind curve :from mod :channel 1 :column vol)
    \\
;

/// An inline `.mid` whose division does NOT divide the grid (500; plan
/// 03, "The grid"), so its ticks land on their nearest one and an
/// operation that reads them says `edit_inexact` with the count.
///
/// The note sits at SMF tick 1, which is the smallest position 500 PPQ
/// cannot spell exactly, and lasts 250 pulses — half a quarter note on
/// the nose, so only the ENDS round and the duration does not.
pub const bound_smf_offgrid: [:0]const u8 =
    \\(timeline :title "off-grid" :conductor song :length 1bar)
    \\
    \\(anchor :id song :kind smf :file "x.mid")
    \\(midi/smf :format 0 :division 500)
    \\(midi/mtrk
    \\  (set-tempo    :at 0   :us 500000)
    \\  (note-on      :at 1   :ch 1 :key 36 :vel 100)
    \\  (note-off     :at 251 :ch 1 :key 36 :vel 64)
    \\  (end-of-track :at 2000))
    \\
    \\(lane :name kick :kind notes :from song :track 1 :ch 1)
    \\
;

/// An inline `.it` whose rows are spread out, for the one question a
/// single-row pattern cannot ask: what a cell's row slot IS once the
/// same plan has removed the rows below it.
///
/// Channel 1 carries two cells (rows 0 and 1) and row 4 carries a cell
/// on channel 2 alone — so a move onto row 4 lands in a row that
/// SURVIVES, after one or two rows beneath it have gone.
pub const bound_it_rows: [:0]const u8 =
    \\(timeline :title "rows" :conductor mod :length 2bar)
    \\
    \\(anchor :id mod :kind it :file "y.it")
    \\(it/module :title "rows"
    \\  (it/timing :speed 24 :tempo 125)
    \\  (it/orders 0 end)
    \\  (it/pattern 0 :rows 8
    \\    (row 0 (ev 1 "C-5" :ins 1))
    \\    (row 1 (ev 1 "E-5" :ins 1))
    \\    (row 4 (ev 2 "C-6" :ins 1))))
    \\
    \\(lane :name lead :kind notes :from mod :channel 1)
    \\
;

/// An inline `.it` whose one pattern is played TWICE, with a cell in it:
/// every edit to that cell changes both occurrences, which is plan 07's
/// `edit_pattern_shared` whatever the operation.
pub const bound_it_shared: [:0]const u8 =
    \\(timeline :title "shared" :conductor mod :length 2bar)
    \\
    \\(anchor :id mod :kind it :file "y.it")
    \\(it/module :title "shared"
    \\  (it/timing :speed 24 :tempo 125)
    \\  (it/orders 0 0 end)
    \\  (it/pattern 0 :rows 4
    \\    (row 0 (ev 1 "C-5" :ins 1))))
    \\
    \\(lane :name lead :kind notes :from mod :channel 1)
    \\
;
