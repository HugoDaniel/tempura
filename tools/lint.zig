//! `tools/zt lint` — plan 12's rules as a gate rather than a review.
//!
//! The Zig mastery wave (plan 12) brought the tree to its rules by hand,
//! and by the next morning two production functions had grown back past
//! seventy lines and a filesystem reader was still sitting in `doc/`. A
//! rule a reviewer has to remember is a rule that drifts, so this tool
//! reads every `.zig` file under `src/` and `tools/`, and `build.zig`,
//! and fails `verify` on any of these:
//!
//!   * `header` — the file opens with a `//!` module header;
//!   * `fn_length` — a function is at most 70 lines, first line to
//!     closing brace. A `test` body is not a function in this sense;
//!     a fixture builder beside the tests is;
//!   * `columns` — a line is at most 100 columns (codepoints), except a
//!     `test "…"` name line and a raw `\\` line, whose bytes ARE the test;
//!   * `allocator_name` — an allocator is bound as `gpa` or `arena` (or a
//!     name ending `_gpa` / `_arena`), outside test bodies;
//!   * `unreachable_proof` — a `catch unreachable` outside test code has
//!     its proof in a comment: trailing, inside its statement, or on the
//!     line right above the statement; test code uses `try` instead;
//!   * `loop_bound` — a `while (true)` outside test code has a comment
//!     naming its bound (the word "bound"): trailing, in the comment block
//!     right above it, or in the comments that open its body;
//!   * `recursion` — a function that calls itself by name, outside test
//!     code, says in its doc comment that SJON's `MAX_PARSE_DEPTH` bounds
//!     it: the one recursion plan 12 accepts is a walk over SJON's tree;
//!   * `core_io` — nothing in the core (`smf/`, `itf/`, `doc/`, `time/`,
//!     `edit/`, `export/`, `residue/`) outside test code names the
//!     filesystem, the clock, a process, a thread, `std.debug.print`,
//!     `std.log` or a process-wide allocator;
//!   * `core_global` — no container-level `var` in the core outside test
//!     code: a pure function keeps no state between calls;
//!   * `managed_container` — the unmanaged container forms only
//!     (`std.AutoHashMapUnmanaged`, not `std.AutoHashMap`), anywhere;
//!   * `pub_doc` — every `pub fn` (and `export fn`) outside test code
//!     carries a `///`: the ownership and lifetime note CLAUDE.md asks for.
//!
//! "Test code" is a `test` body, a whole `test_support.zig` /
//! `fuzz.zig` / `schema_tests.zig`, or a declaration that ONLY test code
//! reaches — a helper beside the tests that prints a report on a RED run,
//! or reads a fixture from disk. That last set is found by reference: a
//! private declaration whose every use (by name, in its own file) lies in
//! test code is test code too, taken to a fixed point. Name matching is
//! conservative — a helper that shares a name with production code counts
//! as production — so the analysis can only under-exempt, never hide a
//! production line.
//!
//! The analysis is a pure function, `lintSource`: a path and a source in,
//! findings out, every allocation in the caller's arena. `main` is the
//! border — it walks the directories, reads the files, prints the
//! findings sorted by path and line, and exits 1 when there are any.

const std = @import("std");
const Ast = std.zig.Ast;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Rule = enum {
    parse,
    header,
    fn_length,
    columns,
    allocator_name,
    unreachable_proof,
    loop_bound,
    recursion,
    core_io,
    core_global,
    managed_container,
    pub_doc,
};

/// One violation: a 1-based line in the file being linted, the rule, and
/// what was found there. `detail` lives in the arena `lintSource` was
/// handed.
pub const Finding = struct {
    line: u32,
    rule: Rule,
    detail: []const u8,
};

pub const Error = Allocator.Error;

pub const max_fn_lines = 70;
pub const max_columns = 100;

/// The parts that are pure functions of their inputs (CLAUDE.md, "IO at
/// the borders"). A path under `src/` starting with one of these is core.
const core_dirs = [_][]const u8{
    "src/smf/", "src/itf/", "src/doc/", "src/time/", "src/edit/", "src/export/", "src/residue/",
};

/// Files that are test code from the first line to the last.
const test_files = [_][]const u8{ "test_support.zig", "fuzz.zig", "schema_tests.zig" };

/// Lint one file. `path` is relative to the repo root with `/`
/// separators (it decides which rules apply); `source` is the file's
/// text. Pure: the findings, in line order, and every byte they point at,
/// live in `arena`.
pub fn lintSource(arena: Allocator, path: []const u8, source: [:0]const u8) Error![]Finding {
    var tree = try Ast.parse(arena, source, .zig);
    var findings: std.ArrayList(Finding) = .empty;
    if (tree.errors.len > 0) {
        const where = tree.tokenLocation(0, tree.errors[0].token).line;
        try findings.append(arena, .{
            .line = @intCast(where + 1),
            .rule = .parse,
            .detail = "the file does not parse; nothing else was checked",
        });
        return findings.items;
    }
    const ctx = try Context.init(arena, path, source, &tree, &findings);
    try checkHeader(&ctx);
    try checkColumns(&ctx);
    try checkFunctions(&ctx);
    try checkTokens(&ctx);
    if (ctx.core) try checkGlobals(&ctx);
    std.mem.sort(Finding, findings.items, {}, lessByLine);
    return findings.items;
}

fn lessByLine(_: void, x: Finding, y: Finding) bool {
    if (x.line != y.line) return x.line < y.line;
    return @intFromEnum(x.rule) < @intFromEnum(y.rule);
}

// ---------------------------------------------------------------------
// The file as the rules see it
// ---------------------------------------------------------------------

/// A token range `[first, last]`, both inclusive.
const Range = struct {
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,

    fn contains(r: Range, tok: Ast.TokenIndex) bool {
        return r.first <= tok and tok <= r.last;
    }

    fn of(tree: *const Ast, node: Ast.Node.Index) Range {
        return .{ .first = tree.firstToken(node), .last = tree.lastToken(node) };
    }
};

/// A declaration the test-only analysis weighs: a function, or a
/// container-level `const`/`var`, with the token that names it.
const Decl = struct {
    name_token: Ast.TokenIndex,
    range: Range,
    is_pub: bool,
    test_only: bool = false,
};

/// Every identifier token, by its text: the uses a declaration's name
/// has in its own file. Only ever looked up, never iterated, so the
/// map's order cannot reach a report.
const Uses = std.StringHashMapUnmanaged(std.ArrayList(Ast.TokenIndex));

const Context = struct {
    arena: Allocator,
    path: []const u8,
    source: [:0]const u8,
    tree: *const Ast,
    findings: *std.ArrayList(Finding),
    /// Byte offset of each line's first byte; `line_starts[0] == 0`.
    line_starts: []const u32,
    /// Per token: inside a `test` body.
    test_body: []const bool,
    /// Per token: inside a function or a `test` body — not at container
    /// level.
    in_body: []const bool,
    /// Per token: test code — a `test` body, a test-only file, or a
    /// declaration only test code reaches.
    test_code: []const bool,
    core: bool,

    fn init(
        arena: Allocator,
        path: []const u8,
        source: [:0]const u8,
        tree: *const Ast,
        findings: *std.ArrayList(Finding),
    ) Error!Context {
        const token_count = tree.tokens.len;
        const test_body = try paint(arena, token_count, try nodeRanges(arena, tree, .tests));
        const in_body = try paint(arena, token_count, try nodeRanges(arena, tree, .bodies));
        const decls = try declarations(arena, tree, in_body);
        const whole_file = isTestFile(path);
        try markTestOnly(arena, tree, test_body, decls, whole_file);
        const test_code = try arena.dupe(bool, test_body);
        for (decls) |d| {
            if (d.test_only) @memset(test_code[d.range.first .. d.range.last + 1], true);
        }
        if (whole_file) @memset(test_code, true);
        return .{
            .arena = arena,
            .path = path,
            .source = source,
            .tree = tree,
            .findings = findings,
            .line_starts = try lineStarts(arena, source),
            .test_body = test_body,
            .in_body = in_body,
            .test_code = test_code,
            .core = isCore(path),
        };
    }

    fn report(
        ctx: *const Context,
        line: u32,
        rule: Rule,
        comptime fmt: []const u8,
        args: anytype,
    ) Error!void {
        const detail = try std.fmt.allocPrint(ctx.arena, fmt, args);
        try ctx.findings.append(ctx.arena, .{ .line = line + 1, .rule = rule, .detail = detail });
    }

    /// The 0-based line holding `tok`.
    fn lineOf(ctx: *const Context, tok: Ast.TokenIndex) u32 {
        const offset = ctx.tree.tokenStart(tok);
        // The last line start at or before `offset`: `line_starts` is
        // ascending and begins at 0, so the answer always exists.
        const after = std.sort.upperBound(u32, ctx.line_starts, offset, orderU32);
        return @intCast(after - 1);
    }

    /// The text of the 0-based `line`, without its newline.
    fn lineText(ctx: *const Context, line: u32) []const u8 {
        const start = ctx.line_starts[line];
        const end = if (line + 1 < ctx.line_starts.len)
            ctx.line_starts[line + 1]
        else
            @as(u32, @intCast(ctx.source.len));
        return std.mem.trimEnd(u8, ctx.source[start..end], "\r\n");
    }

    fn lineCount(ctx: *const Context) u32 {
        return @intCast(ctx.line_starts.len);
    }

    fn tokenText(ctx: *const Context, tok: Ast.TokenIndex) []const u8 {
        return ctx.tree.tokenSlice(tok);
    }

    fn isIdent(ctx: *const Context, tok: Ast.TokenIndex, text: []const u8) bool {
        if (ctx.tagAt(tok) != .identifier) return false;
        return std.mem.eql(u8, ctx.tokenText(tok), text);
    }

    fn tagAt(ctx: *const Context, tok: Ast.TokenIndex) std.zig.Token.Tag {
        if (tok >= ctx.tree.tokens.len) return .eof;
        return ctx.tree.tokenTag(tok);
    }
};

fn orderU32(key: u32, item: u32) std.math.Order {
    return std.math.order(key, item);
}

fn isCore(path: []const u8) bool {
    for (core_dirs) |dir| {
        if (std.mem.startsWith(u8, path, dir)) return true;
    }
    return false;
}

fn isTestFile(path: []const u8) bool {
    const base = std.fs.path.basenamePosix(path);
    for (test_files) |name| {
        if (std.mem.eql(u8, base, name)) return true;
    }
    return false;
}

fn lineStarts(arena: Allocator, source: []const u8) Error![]const u32 {
    var starts: std.ArrayList(u32) = .empty;
    try starts.append(arena, 0);
    for (source, 0..) |c, i| {
        if (c == '\n' and i + 1 < source.len) try starts.append(arena, @intCast(i + 1));
    }
    return starts.items;
}

/// The token ranges of every `test` declaration, or of every function
/// and `test` declaration.
fn nodeRanges(arena: Allocator, tree: *const Ast, which: enum { tests, bodies }) Error![]Range {
    var ranges: std.ArrayList(Range) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        const keep = switch (tree.nodeTag(node)) {
            .test_decl => true,
            .fn_decl => which == .bodies,
            else => false,
        };
        if (keep) try ranges.append(arena, .of(tree, node));
    }
    return ranges.items;
}

/// A per-token mask, true inside any of `ranges`.
fn paint(arena: Allocator, token_count: usize, ranges: []const Range) Error![]bool {
    const mask = try arena.alloc(bool, token_count);
    @memset(mask, false);
    for (ranges) |r| @memset(mask[r.first .. r.last + 1], true);
    return mask;
}

/// Every named function, and every `const`/`var` at container level.
fn declarations(arena: Allocator, tree: *const Ast, in_body: []const bool) Error![]Decl {
    var decls: std.ArrayList(Decl) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        if (tree.nodeTag(node) == .fn_decl) {
            var buf: [1]Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&buf, node).?;
            const name = proto.name_token orelse continue;
            try decls.append(arena, .{
                .name_token = name,
                .range = .of(tree, node),
                .is_pub = proto.visib_token != null,
            });
        } else if (tree.fullVarDecl(node)) |var_decl| {
            if (in_body[var_decl.ast.mut_token]) continue;
            try decls.append(arena, .{
                .name_token = var_decl.ast.mut_token + 1,
                .range = .of(tree, node),
                .is_pub = var_decl.visib_token != null,
            });
        }
    }
    return decls.items;
}

/// Mark every declaration only test code reaches. Each pass either marks
/// one more declaration or stops, so `decls.len + 1` passes bound it.
fn markTestOnly(
    arena: Allocator,
    tree: *const Ast,
    test_body: []const bool,
    decls: []Decl,
    whole_file: bool,
) Error!void {
    if (whole_file) return;
    const uses = try usesOf(arena, tree);
    for (0..decls.len + 1) |_| {
        var changed = false;
        for (decls) |*d| {
            if (d.test_only or d.is_pub) continue;
            const refs = uses.get(tree.tokenSlice(d.name_token)) orelse continue;
            if (!reachedOnlyByTests(test_body, decls, d.*, refs.items)) continue;
            d.test_only = true;
            changed = true;
        }
        if (!changed) break;
    } else unreachable;
}

fn usesOf(arena: Allocator, tree: *const Ast) Error!Uses {
    var uses: Uses = .empty;
    for (0..tree.tokens.len) |i| {
        const tok: Ast.TokenIndex = @intCast(i);
        if (tree.tokenTag(tok) != .identifier) continue;
        const entry = try uses.getOrPut(arena, tree.tokenSlice(tok));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(arena, tok);
    }
    return uses;
}

/// Every use of `d`'s name outside `d` itself lies in test code, and
/// there is at least one.
fn reachedOnlyByTests(
    test_body: []const bool,
    decls: []const Decl,
    d: Decl,
    refs: []const Ast.TokenIndex,
) bool {
    var outside: u32 = 0;
    for (refs) |tok| {
        if (d.range.contains(tok)) continue;
        if (!inTestCode(test_body, decls, tok)) return false;
        outside += 1;
    }
    return outside > 0;
}

fn inTestCode(test_body: []const bool, decls: []const Decl, tok: Ast.TokenIndex) bool {
    if (test_body[tok]) return true;
    for (decls) |d| {
        if (d.test_only and d.range.contains(tok)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------
// The rules
// ---------------------------------------------------------------------

fn checkHeader(ctx: *const Context) Error!void {
    if (std.mem.startsWith(u8, ctx.source, "//!")) return;
    try ctx.report(0, .header, "the file does not open with a `//!` module header", .{});
}

fn checkColumns(ctx: *const Context) Error!void {
    for (0..ctx.lineCount()) |i| {
        const line: u32 = @intCast(i);
        const text = ctx.lineText(line);
        const width = std.unicode.utf8CountCodepoints(text) catch text.len;
        if (width <= max_columns) continue;
        const trimmed = std.mem.trimStart(u8, text, " ");
        if (std.mem.startsWith(u8, trimmed, "\\\\")) continue;
        if (std.mem.startsWith(u8, trimmed, "test \"")) continue;
        try ctx.report(line, .columns, "{d} columns", .{width});
    }
}

/// Length, doc comment and recursion: the rules that look at a function
/// as a whole.
fn checkFunctions(ctx: *const Context) Error!void {
    const tree = ctx.tree;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        if (tree.nodeTag(node) != .fn_decl) continue;
        const first = tree.firstToken(node);
        if (ctx.test_body[first]) continue;
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, node).?;
        const name = if (proto.name_token) |t| ctx.tokenText(t) else "(anonymous)";
        const lines = ctx.lineOf(tree.lastToken(node)) - ctx.lineOf(first) + 1;
        if (lines > max_fn_lines) {
            try ctx.report(ctx.lineOf(first), .fn_length, "fn {s} is {d} lines", .{ name, lines });
        }
        const documented = first > 0 and ctx.tagAt(first - 1) == .doc_comment;
        if (isPublic(ctx, proto) and !documented and !ctx.test_code[first]) {
            try ctx.report(ctx.lineOf(first), .pub_doc, "pub fn {s} has no `///`", .{name});
        }
        if (proto.name_token != null and !ctx.test_code[first]) {
            try checkRecursion(ctx, node, first, name);
        }
    }
}

fn checkRecursion(
    ctx: *const Context,
    node: Ast.Node.Index,
    first: Ast.TokenIndex,
    name: []const u8,
) Error!void {
    const body = ctx.tree.nodeData(node).node_and_node[1];
    const from = ctx.tree.firstToken(body);
    const to = ctx.tree.lastToken(body);
    var tok = from;
    const calls_itself = while (tok < to) : (tok += 1) {
        if (!ctx.isIdent(tok, name)) continue;
        if (ctx.tagAt(tok + 1) != .l_paren) continue;
        if (ctx.tagAt(tok - 1) == .period) continue;
        break true;
    } else false;
    if (!calls_itself) return;
    if (docMentions(ctx, first, "MAX_PARSE_DEPTH")) return;
    try ctx.report(
        ctx.lineOf(tok),
        .recursion,
        "fn {s} calls itself and its doc comment names no MAX_PARSE_DEPTH bound",
        .{name},
    );
}

/// Whether the `///` block right above `first` contains `needle`.
fn docMentions(ctx: *const Context, first: Ast.TokenIndex, needle: []const u8) bool {
    var tok = first;
    while (tok > 0 and ctx.tagAt(tok - 1) == .doc_comment) {
        tok -= 1;
        if (std.mem.indexOf(u8, ctx.tokenText(tok), needle) != null) return true;
    }
    return false;
}

/// `pub fn`, or an `export fn` — a host's entry point is public too.
fn isPublic(ctx: *const Context, proto: Ast.full.FnProto) bool {
    if (proto.visib_token != null) return true;
    const tok = proto.extern_export_inline_token orelse return false;
    return ctx.tagAt(tok) == .keyword_export;
}

/// The rules that are patterns of a few tokens.
fn checkTokens(ctx: *const Context) Error!void {
    const count: Ast.TokenIndex = @intCast(ctx.tree.tokens.len);
    var tok: Ast.TokenIndex = 0;
    while (tok < count) : (tok += 1) {
        switch (ctx.tagAt(tok)) {
            .keyword_catch => try checkCatchUnreachable(ctx, tok),
            .keyword_while => try checkLoopBound(ctx, tok),
            .keyword_const, .keyword_var => try checkAllocatorBinding(ctx, tok),
            .identifier => try checkIdentifier(ctx, tok),
            else => {},
        }
    }
}

fn checkCatchUnreachable(ctx: *const Context, tok: Ast.TokenIndex) Error!void {
    if (ctx.tagAt(tok + 1) != .keyword_unreachable) return;
    const line = ctx.lineOf(tok);
    if (ctx.test_code[tok]) {
        const why = "`catch unreachable` in test code; use `try`";
        try ctx.report(line, .unreachable_proof, why, .{});
        return;
    }
    if (proofAbove(ctx, line)) return;
    try ctx.report(line, .unreachable_proof, "`catch unreachable` with no proof above it", .{});
}

/// Whether the statement holding `line` carries a `//` comment: trailing
/// on that line, on a line of the same statement above it, or on the
/// line right above the statement's first. A statement ends a line with
/// `;`, `{` or `}`, so the walk up stops at the previous one; eight lines
/// is past any statement `zig fmt` leaves in this tree.
fn proofAbove(ctx: *const Context, line: u32) bool {
    if (std.mem.indexOf(u8, ctx.lineText(line), "//") != null) return true;
    var at = line;
    for (0..8) |_| {
        if (at == 0) return false;
        at -= 1;
        const text = std.mem.trim(u8, ctx.lineText(at), " ");
        if (std.mem.startsWith(u8, text, "//")) return !std.mem.startsWith(u8, text, "//!");
        if (text.len == 0) return false;
        switch (text[text.len - 1]) {
            ';', '{', '}' => return false,
            else => {},
        }
    }
    return false;
}

fn checkLoopBound(ctx: *const Context, tok: Ast.TokenIndex) Error!void {
    if (ctx.tagAt(tok + 1) != .l_paren) return;
    if (!ctx.isIdent(tok + 2, "true")) return;
    if (ctx.tagAt(tok + 3) != .r_paren) return;
    if (ctx.test_code[tok]) return;
    const line = ctx.lineOf(tok);
    if (boundNamed(ctx, line)) return;
    try ctx.report(line, .loop_bound, "`while (true)` with no comment naming its bound", .{});
}

/// Whether a comment saying "bound" (any case) is trailing on `line`, in
/// the comment block right above it, or in the comment lines that open
/// the loop's body below it. Eight lines either way is past any comment
/// block in this tree.
fn boundNamed(ctx: *const Context, line: u32) bool {
    if (commentSays(ctx.lineText(line), "bound")) return true;
    var up = line;
    for (0..8) |_| {
        if (up == 0) break;
        up -= 1;
        const text = std.mem.trim(u8, ctx.lineText(up), " ");
        if (!std.mem.startsWith(u8, text, "//")) break;
        if (commentSays(text, "bound")) return true;
    }
    var down = line;
    for (0..8) |_| {
        down += 1;
        if (down >= ctx.lineCount()) break;
        const text = std.mem.trim(u8, ctx.lineText(down), " ");
        if (!std.mem.startsWith(u8, text, "//")) break;
        if (commentSays(text, "bound")) return true;
    }
    return false;
}

/// Whether `text` has a `//` comment containing `needle`, in any case.
fn commentSays(text: []const u8, needle: []const u8) bool {
    const at = std.mem.indexOf(u8, text, "//") orelse return false;
    return std.ascii.findIgnoreCase(text[at..], needle) != null;
}

/// `const x = y.allocator();` (or `= y.allocator;`): the binding's name
/// says what the code may assume.
fn checkAllocatorBinding(ctx: *const Context, tok: Ast.TokenIndex) Error!void {
    const name = tok + 1;
    if (ctx.tagAt(name) != .identifier or ctx.tagAt(name + 1) != .equal) return;
    if (ctx.test_body[tok]) return;
    // A declaration's initializer ends at its `;`; sixty-four tokens is
    // far past any `a.b.c.allocator()` spelling, and a longer expression
    // is not a binding of an allocator.
    var end = name + 2;
    const semi = for (0..64) |_| {
        switch (ctx.tagAt(end)) {
            .semicolon => break end,
            // A block or a container is not an allocator's spelling.
            .l_brace, .eof => return,
            else => end += 1,
        }
    } else return;
    const call = ctx.tagAt(semi - 1) == .r_paren and ctx.tagAt(semi - 2) == .l_paren;
    const field = if (call) semi - 3 else semi - 1;
    if (!ctx.isIdent(field, "allocator") or ctx.tagAt(field - 1) != .period) return;
    try reportAllocatorName(ctx, name);
}

fn reportAllocatorName(ctx: *const Context, name: Ast.TokenIndex) Error!void {
    const text = ctx.tokenText(name);
    if (allocatorNameOk(text)) return;
    const why = "allocator named `{s}`; say `gpa` or `arena`";
    try ctx.report(ctx.lineOf(name), .allocator_name, why, .{text});
}

fn allocatorNameOk(name: []const u8) bool {
    if (std.mem.eql(u8, name, "gpa") or std.mem.eql(u8, name, "arena")) return true;
    return std.mem.endsWith(u8, name, "_gpa") or std.mem.endsWith(u8, name, "_arena");
}

/// The identifier-led patterns: `name: …Allocator`, and the `std.X`
/// namespaces the core and the container rule care about.
fn checkIdentifier(ctx: *const Context, tok: Ast.TokenIndex) Error!void {
    if (ctx.tagAt(tok + 1) == .colon and allocatorTypeAt(ctx, tok + 2)) {
        if (!ctx.test_body[tok]) try reportAllocatorName(ctx, tok);
        return;
    }
    if (!ctx.isIdent(tok, "std") or ctx.tagAt(tok + 1) != .period) return;
    if (tok > 0 and ctx.tagAt(tok - 1) == .period) return;
    const member = ctx.tokenText(tok + 2);
    if (managedContainer(member)) {
        const why = "std.{s}: use the Unmanaged form";
        try ctx.report(ctx.lineOf(tok), .managed_container, why, .{member});
    }
    if (ctx.core and !ctx.test_code[tok]) {
        if (ioReach(ctx, tok)) |what| {
            try ctx.report(ctx.lineOf(tok), .core_io, "std.{s} in the core", .{what});
        }
    }
}

/// `Allocator`, `mem.Allocator` or `std.mem.Allocator`, ending the type.
fn allocatorTypeAt(ctx: *const Context, tok: Ast.TokenIndex) bool {
    var at = tok;
    if (ctx.isIdent(at, "std") and ctx.tagAt(at + 1) == .period) at += 2;
    if (ctx.isIdent(at, "mem") and ctx.tagAt(at + 1) == .period) at += 2;
    if (!ctx.isIdent(at, "Allocator")) return false;
    return switch (ctx.tagAt(at + 1)) {
        .comma, .r_paren, .equal, .semicolon, .r_brace => true,
        else => false,
    };
}

fn managedContainer(member: []const u8) bool {
    const managed = [_][]const u8{
        "AutoHashMap",      "StringHashMap",      "HashMap",            "ArrayHashMap",
        "AutoArrayHashMap", "StringArrayHashMap", "ArrayListUnmanaged", "GeneralPurposeAllocator",
    };
    for (managed) |m| {
        if (std.mem.eql(u8, member, m)) return true;
    }
    return false;
}

/// What `std.<member>[.<next>]` at `tok` reaches outside a pure function,
/// or null. `std.time`'s unit constants are arithmetic, not a clock.
fn ioReach(ctx: *const Context, tok: Ast.TokenIndex) ?[]const u8 {
    const member = ctx.tokenText(tok + 2);
    const next = if (ctx.tagAt(tok + 3) == .period) ctx.tokenText(tok + 4) else "";
    const whole = [_][]const u8{ "fs", "process", "Thread", "posix", "os", "log" };
    for (whole) |w| {
        if (std.mem.eql(u8, member, w)) return w;
    }
    if (std.mem.eql(u8, member, "time")) {
        return if (std.mem.indexOf(u8, next, "_per_") != null) null else "time";
    }
    const pairs = [_][3][]const u8{
        .{ "Io", "Dir", "Io.Dir" },
        .{ "Io", "File", "Io.File" },
        .{ "Io", "Threaded", "Io.Threaded" },
        .{ "debug", "print", "debug.print" },
        .{ "heap", "page_allocator", "heap.page_allocator" },
        .{ "heap", "c_allocator", "heap.c_allocator" },
        .{ "heap", "smp_allocator", "heap.smp_allocator" },
        .{ "heap", "DebugAllocator", "heap.DebugAllocator" },
        .{ "testing", "io", "testing.io" },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, member, p[0]) and std.mem.eql(u8, next, p[1])) return p[2];
    }
    return null;
}

/// A container-level `var` in the core is state a pure function would
/// carry from one call to the next.
fn checkGlobals(ctx: *const Context) Error!void {
    const tree = ctx.tree;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        const var_decl = tree.fullVarDecl(node) orelse continue;
        const mut = var_decl.ast.mut_token;
        if (tree.tokenTag(mut) != .keyword_var or ctx.test_code[mut]) continue;
        if (ctx.in_body[mut]) continue;
        try ctx.report(ctx.lineOf(mut), .core_global, "`var {s}` at container level", .{
            ctx.tokenText(mut + 1),
        });
    }
}

// ---------------------------------------------------------------------
// The border: walk, read, print
// ---------------------------------------------------------------------

/// `lint <repo-root>`: every `.zig` file under `src/` and `tools/`, and
/// `build.zig`. Exit 0 when clean, 1 on any finding, 2 on a usage error.
pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var out_buf: [4096]u8 = undefined;
    var out_file = Io.File.stderr();
    var out_writer = out_file.writer(io, &out_buf);
    const out = &out_writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        try out.print("usage: lint <repo-root>\n", .{});
        return 2;
    }
    var root = try Io.Dir.cwd().openDir(io, args[1], .{});
    defer root.close(io);

    const paths = try zigFiles(arena, io, root);
    var counts: [std.enums.values(Rule).len]u32 = @splat(0);
    for (paths) |path| {
        try lintFile(init.gpa, io, root, path, out, &counts);
    }
    return summarize(out, paths.len, &counts);
}

fn lintFile(
    gpa: Allocator,
    io: Io,
    root: Io.Dir,
    path: []const u8,
    out: *Io.Writer,
    counts: []u32,
) !void {
    var file_arena: std.heap.ArenaAllocator = .init(gpa);
    defer file_arena.deinit();
    const arena = file_arena.allocator();
    const source = try root.readFileAllocOptions(io, path, arena, .limited(16 << 20), .of(u8), 0);
    for (try lintSource(arena, path, source)) |f| {
        counts[@intFromEnum(f.rule)] += 1;
        try out.print("{s}:{d}: {t}: {s}\n", .{ path, f.line, f.rule, f.detail });
    }
}

fn summarize(out: *Io.Writer, files: usize, counts: []const u32) !u8 {
    var total: u32 = 0;
    for (counts) |c| total += c;
    if (total == 0) {
        try out.print("lint: {d} files, clean\n", .{files});
        return 0;
    }
    try out.print("lint: {d} files, {d} findings:", .{ files, total });
    for (counts, 0..) |c, i| {
        if (c > 0) try out.print(" {t} {d}", .{ @as(Rule, @enumFromInt(i)), c });
    }
    try out.print("\n", .{});
    return 1;
}

/// The files to lint, relative to `root` with `/` separators, sorted so
/// the report's order does not depend on the directory walk's.
fn zigFiles(arena: Allocator, io: Io, root: Io.Dir) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.append(arena, "build.zig");
    for ([_][]const u8{ "src", "tools" }) |sub| {
        var dir = try root.openDir(io, sub, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        // Bounded by the directory tree, which the walk visits once.
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const joined = try std.fs.path.join(arena, &.{ sub, entry.path });
            std.mem.replaceScalar(u8, joined, std.fs.path.sep, '/');
            try paths.append(arena, joined);
        }
    }
    std.mem.sort([]const u8, paths.items, {}, lessPath);
    return paths.items;
}

fn lessPath(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

/// Lint `source` as `path` and return the rules it broke, in line order.
fn rulesOf(path: []const u8, source: [:0]const u8) ![]const Rule {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const found = try lintSource(arena_state.allocator(), path, source);
    const rules = try testing.allocator.alloc(Rule, found.len);
    for (found, rules) |f, *r| r.* = f.rule;
    return rules;
}

fn expectRules(path: []const u8, source: [:0]const u8, want: []const Rule) !void {
    const got = try rulesOf(path, source);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(Rule, want, got);
}

test "lint: a clean file is clean" {
    try expectRules("src/time/x.zig",
        \\//! A module.
        \\const std = @import("std");
        \\
        \\/// Doubles.
        \\pub fn double(gpa: std.mem.Allocator, x: u32) u32 {
        \\    _ = gpa;
        \\    return x * 2;
        \\}
        \\
    , &.{});
}

test "lint: the header, the doc comment and the allocator's name" {
    try expectRules("tools/x.zig",
        \\const std = @import("std");
        \\pub fn f(a: std.mem.Allocator) void {
        \\    _ = a;
        \\}
        \\
    , &.{ .header, .allocator_name, .pub_doc });
}

test "lint: a bound allocator binding is named for what it is" {
    try expectRules("tools/x.zig",
        \\//! A module.
        \\fn f(state: *std.heap.ArenaAllocator) void {
        \\    const scratch = state.allocator();
        \\    const arena = state.allocator();
        \\    const input_arena = state.allocator();
        \\    _ = .{ scratch, arena, input_arena };
        \\}
        \\
    , &.{.allocator_name});
}

test "lint: a test body may say `a`; a helper beside it may not" {
    try expectRules("tools/x.zig",
        \\//! A module.
        \\fn helper(allocator: std.mem.Allocator) void {
        \\    _ = allocator;
        \\}
        \\test "t" {
        \\    const a = std.testing.allocator;
        \\    helper(a);
        \\}
        \\
    , &.{.allocator_name});
}

test "lint: seventy lines is the ceiling, and a test body is exempt" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "//! A module.\nfn long() void {\n");
    for (0..69) |_| try source.appendSlice(testing.allocator, "    _ = 0;\n");
    try source.appendSlice(testing.allocator, "}\ntest \"t\" {\n");
    for (0..80) |_| try source.appendSlice(testing.allocator, "    _ = 0;\n");
    try source.appendSlice(testing.allocator, "}\n");
    const text = try source.toOwnedSliceSentinel(testing.allocator, 0);
    defer testing.allocator.free(text);
    // 71 lines: the signature, sixty-nine statements and the brace.
    try expectRules("tools/x.zig", text, &.{.fn_length});
}

test "lint: a hundred columns, bar a test's name and a raw line" {
    try expectRules("tools/x.zig",
        \\//! A module.
        \\const x = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        \\const y =
        \\    \\bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        \\;
        \\test "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" {}
        \\
    , &.{.columns});
}

test "lint: a codepoint is one column" {
    // Ninety-nine arrows are 297 bytes and 99 columns.
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "//! A module.\n// ");
    for (0..97) |_| try source.appendSlice(testing.allocator, "→");
    try source.appendSlice(testing.allocator, "\n");
    const text = try source.toOwnedSliceSentinel(testing.allocator, 0);
    defer testing.allocator.free(text);
    try expectRules("tools/x.zig", text, &.{});
}

test "lint: catch unreachable states its proof, and test code uses try" {
    try expectRules("tools/x.zig",
        \\//! A module.
        \\fn proven(buf: []u8) []u8 {
        \\    // Eleven digits fit a sixteen-byte buffer.
        \\    return std.fmt.bufPrint(buf, "{d}", .{1}) catch unreachable;
        \\}
        \\fn unproven(buf: []u8) []u8 {
        \\    return std.fmt.bufPrint(buf, "{d}", .{1}) catch unreachable;
        \\}
        \\test "t" {
        \\    _ = f() catch unreachable;
        \\}
        \\
    , &.{ .unreachable_proof, .unreachable_proof });
}

test "lint: while (true) names its bound" {
    try expectRules("tools/x.zig",
        \\//! A module.
        \\fn bounded() void {
        \\    // Bounded by the input's length: each pass eats a byte.
        \\    while (true) {}
        \\}
        \\fn unbounded() void {
        \\    while (true) {}
        \\}
        \\
    , &.{.loop_bound});
}

test "lint: recursion names SJON's depth bound or is refused" {
    try expectRules("tools/x.zig",
        \\//! A module.
        \\/// Walks the tree; SJON's `MAX_PARSE_DEPTH` bounds the depth.
        \\fn walk(n: u32) void {
        \\    if (n > 0) walk(n - 1);
        \\}
        \\fn spin(n: u32) void {
        \\    if (n > 0) spin(n - 1);
        \\}
        \\fn method(self: *S) void {
        \\    self.other.method();
        \\}
        \\
    , &.{.recursion});
}

test "lint: the core reaches no filesystem, and a test-only helper may" {
    const source =
        \\//! A module.
        \\fn load(io: std.Io) void {
        \\    _ = std.Io.Dir.cwd();
        \\    _ = io;
        \\}
        \\fn report(x: u32) void {
        \\    std.debug.print("{d}\n", .{x});
        \\}
        \\const ns = std.time.ns_per_s;
        \\pub fn run() void {
        \\    load(undefined);
        \\}
        \\test "t" {
        \\    report(1);
        \\}
        \\
    ;
    // `load` is reached from production (`run`); `report` only from a
    // test, so its print is test code.
    try expectRules("src/doc/x.zig", source, &.{ .core_io, .pub_doc });
    // Outside the core the same text has nothing to say about IO.
    try expectRules("src/cli/x.zig", source, &.{.pub_doc});
}

test "lint: a helper reached only through another test-only helper is test code" {
    try expectRules("src/time/x.zig",
        \\//! A module.
        \\fn inner() void {
        \\    std.debug.print("x\n", .{});
        \\}
        \\fn outer() void {
        \\    inner();
        \\}
        \\test "t" {
        \\    outer();
        \\}
        \\
    , &.{});
}

test "lint: a core file keeps no state between calls" {
    try expectRules("src/export/x.zig",
        \\//! A module.
        \\var calls: u32 = 0;
        \\const limit: u32 = 4;
        \\fn f() void {
        \\    var local: u32 = limit;
        \\    local += 1;
        \\}
        \\
    , &.{.core_global});
}

test "lint: managed containers are named, anywhere" {
    try expectRules("tools/x.zig",
        \\//! A module.
        \\const Map = std.AutoHashMap(u32, u32);
        \\const Fine = std.AutoHashMapUnmanaged(u32, u32);
        \\
    , &.{.managed_container});
}

test "lint: a file that does not parse says so and nothing else" {
    try expectRules("tools/x.zig", "fn (", &.{.parse});
}
