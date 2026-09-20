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
