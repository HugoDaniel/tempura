//! tempura's build graph: the public `tempura` module, the two test
//! roots, `tempura.wasm`, the native CLI, the corpus runner, the tools
//! under `tools/`, and `verify`, the one gate every change goes through.
//!
//! Every compile on this machine goes through `tools/zt <verb>` (CLAUDE.md,
//! "Every build goes through `tools/zt`"); the verbs are the steps below.
//! `build` keeps the wiring — which step depends on which — and one
//! helper per verb builds that verb's artifacts, so each reads on its own
//! screen with the reason it exists beside it.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    // `.minimum_zig_version` only gates package-manager consumers; this
    // gives a direct `zig build` on an older toolchain a clear message.
    // The literal is a well-formed version, so `parse` cannot fail.
    const required = std.SemanticVersion.parse("0.16.0") catch unreachable;
    if (builtin.zig_version.order(required) == .lt)
        @compileError("tempura requires zig >= 0.16.0 (build.zig.zon minimum_zig_version)");
}

/// What every verb's helper needs: the build, the native target and mode,
/// SJON, and the two modules most artifacts import.
const Ctx = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sjon_dep: *std.Build.Dependency,
    sjon: *std.Build.Module,
    /// The PUBLIC module (`src/root.zig`), what a host imports.
    tempura: *std.Build.Module,
    /// `repo_root`, for the tests that read repo files.
    build_options: *std.Build.Module,
};

/// The graph: every verb, and what `verify` runs.
pub fn build(b: *std.Build) void {
    const ctx = context(b);
    const tests = addTests(ctx);
    const wasm = addWasm(ctx);
    const sjon_wasm = addSjonWasm(ctx);
    const corpus_verify = addCorpus(ctx);
    addFixtures(ctx);
    const landing_check = addLanding(ctx);
    const cli = addCli(ctx);
    addFuzz(ctx);
    addConform(ctx);
    addAuditDiagnostics(ctx);
    const docs_check = addDocs(ctx);
    const lint = addLint(ctx);

    // `zig build verify` — the whole gate in one verb. The corpus runs
    // through its OWN run step, without `b.args`: `zig build verify --
    // --update` must never regenerate goldens behind the gate's back
    // (regen is the `corpus` verb's business alone).
    const verify = b.step("verify", "test + lint + the CLI goldens + native corpus + node " ++
        "--test + the wasm size budget + the pacer-schema drift check + the generated-docs " ++
        "drift check");
    verify.dependOn(tests.core);
    verify.dependOn(tests.cli);
    verify.dependOn(lint);
    verify.dependOn(cli.golden_check);
    verify.dependOn(corpus_verify);
    verify.dependOn(addPacerDrift(ctx));
    // The wasm's size budget. Unconditional — it needs no `node`, no
    // sibling checkout and no `npm install`, only the artifact, which it
    // takes as a build-graph dependency so the gate measures what this
    // tree produces rather than whatever `zig-out` happens to hold.
    verify.dependOn(wasm.budget);
    verify.dependOn(docs_check);
    addNodeLeg(ctx, verify, landing_check, wasm.copy, cli.install, sjon_wasm);
}

fn context(b: *std.Build) Ctx {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SJON without the executable-plugin runtime: tempura needs the
    // parser / validator / Expr / Pattern / Edit surface, never
    // libwasmtime. pacer consumes it the same way.
    const sjon_dep = b.dependency("sjon", .{
        .target = target,
        .optimize = optimize,
        .@"plugin-exec" = false,
    });
    const sjon_mod = sjon_dep.module("sjon");

    const tempura_mod = b.addModule("tempura", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tempura_mod.addImport("sjon", sjon_mod);
    addSchemas(b, tempura_mod);

    // The repo root, handed to test binaries as an absolute path: a
    // cwd-relative one would depend on where `zig build` was invoked
    // from. The version-lockstep test reads `build.zig.zon` through it,
    // and the project-file test does (pacer's `Schema.zig` does too).
    const build_options = b.addOptions();
    build_options.addOptionPath("repo_root", b.path("."));

    // `TEMPURA_ANIMADER`: where the sibling-composition test looks for
    // animader's checkout, overriding the workspace default
    // `../animader/animader` (the consumer of that leg is
    // `src/schema_tests.zig`). Read here, at the build border, so the
    // test binary holds no process state of its own — a changed value
    // re-hashes the options module and the leg rebuilds rather than
    // runs stale. An empty value counts as unset.
    const animader_env = b.graph.environ_map.get("TEMPURA_ANIMADER");
    build_options.addOption(
        ?[]const u8,
        "animader_root",
        if (animader_env != null and animader_env.?.len > 0) animader_env else null,
    );

    return .{
        .b = b,
        .target = target,
        .optimize = optimize,
        .sjon_dep = sjon_dep,
        .sjon = sjon_mod,
        .tempura = tempura_mod,
        .build_options = build_options.createModule(),
    };
}

/// The manifests every document-validating module embeds, wired as
/// anonymous imports so `@embedFile`-style access works on
/// wasm32-freestanding with no filesystem (pacer's `pacer_schema`
/// precedent, one import per vocabulary).
///
/// All five reach every module, the harness vocabulary included:
/// `src/Schema.zig` owns BOTH preloads (`load` composes the four timeline
/// manifests, `loadCorpus` takes the harness one alone), and that module
/// is part of the public `tempura` module as well as of the test root and
/// the corpus runner. The rule the harness vocabulary actually carries is
/// about COMPOSITION, not embedding — it is never aggregated with the
/// timeline one, because both would declare heads the other has (pacer's
/// `pacer-corpus.sjon` reasoning); two preloaded bundles, never a shared
/// schema. Embedding it costs the wasm a couple of kilobytes and keeps
/// `Schema.zig` compiling the same way from every root.
fn addSchemas(b: *std.Build, mod: *std.Build.Module) void {
    mod.addAnonymousImport("tempura_schema", .{
        .root_source_file = b.path("schema/tempura.sjon"),
    });
    mod.addAnonymousImport("midi_schema", .{
        .root_source_file = b.path("schema/midi.sjon"),
    });
    mod.addAnonymousImport("it_schema", .{
        .root_source_file = b.path("schema/it.sjon"),
    });
    mod.addAnonymousImport("pacer_schema", .{
        .root_source_file = b.path("schema/pacer.sjon"),
    });
    mod.addAnonymousImport("corpus_schema", .{
        .root_source_file = b.path("schema/tempura-corpus.sjon"),
    });
}

/// A copy of `src/` with one generated root file beside the aggregators.
///
/// Rooting a module at `src/time/time.zig` would make `src/time/` the
/// module path, and `Pos.zig`'s `@import("../Diag.zig")` is then "outside
/// module path". Keeping the module root one level above every aggregator
/// is what makes a subtree see exactly what the root sees. (`@import`
/// needs a string LITERAL, so the aggregator's name cannot be a build
/// option read at comptime; a comptime switch over an enum does not help
/// either — Zig resolves imports in dead branches too.)
fn srcCopyWithRoot(b: *std.Build, name: []const u8, text: []const u8) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    _ = wf.addCopyDirectory(b.path("src"), ".", .{});
    return wf.add(name, text);
}

const Tests = struct {
    /// The core root's run.
    core: *std.Build.Step,
    /// The CLI root's run.
    cli: *std.Build.Step,
};

/// `zig build test` — `src/root.zig` forces discovery of every
/// submodule's inline tests via its `test { _ = X; }` block (the SJON
/// discipline), and every part directory aggregates its own files the
/// same way in `src/<part>/<part>.zig`.
///
/// `-Dtest-root=time/time.zig` swaps the ROOT of that walk, so one
/// subtree's tests run without editing `src/root.zig`. The module is
/// wired identically either way — sjon, build_options, every schema — so
/// a subtree sees exactly what the root sees and a passing subtree run
/// means the same thing as a passing whole run. The option value is a
/// path RELATIVE TO `src/` (`time/time.zig`, `smf/smf.zig`, `Diag.zig`),
/// and the root is a GENERATED file inside a copy of `src/`
/// (`srcCopyWithRoot`), not the aggregator itself.
fn addTests(ctx: Ctx) Tests {
    const b = ctx.b;
    const test_root = b.option(
        []const u8,
        "test-root",
        "Test root, relative to src/ (e.g. time/time.zig) — run one subtree's tests",
    );
    const test_root_file: std.Build.LazyPath = if (test_root) |p|
        srcCopyWithRoot(b, "_test_root.zig", b.fmt("test {{ _ = @import(\"{s}\"); }}\n", .{p}))
    else
        b.path("src/root.zig");
    const test_mod = b.createModule(.{
        .root_source_file = test_root_file,
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = &.{
            .{ .name = "sjon", .module = ctx.sjon },
            .{ .name = "build_options", .module = ctx.build_options },
        },
    });
    addSchemas(b, test_mod);
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_mod }));
    const test_step = b.step(
        "test",
        "Run unit tests (-Dtest-root=<path-relative-to-src> for one subtree)",
    );
    test_step.dependOn(&run_tests.step);
    const run_cli_tests = addCliTests(ctx);
    test_step.dependOn(run_cli_tests);
    return .{ .core = &run_tests.step, .cli = run_cli_tests };
}

/// The CLI's tests are their OWN root. `src/root.zig`'s `test {}` block
/// cannot reach them: these files import the `tempura` MODULE, which
/// inside the core test binary would resolve to a second, distinct
/// instance. `src/cli/Cli.zig` plays root.zig's role one level down, and
/// `zig build test` runs both roots (`addTests`).
fn addCliTests(ctx: Ctx) *std.Build.Step {
    const cli_test_mod = ctx.b.createModule(.{
        .root_source_file = ctx.b.path("src/cli/Cli.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = &cliImports(ctx),
    });
    // The CLI tests read repo fixtures (`corpus/…`, `src/cli/testdata/…`)
    // through the same absolute repo root the core tests use, so they do
    // not depend on where `zig build` was invoked from.
    cli_test_mod.addImport("build_options", ctx.build_options);
    const cli_tests = ctx.b.addTest(.{ .root_module = cli_test_mod });
    return &ctx.b.addRunArtifact(cli_tests).step;
}

fn cliImports(ctx: Ctx) [2]std.Build.Module.Import {
    return .{
        .{ .name = "tempura", .module = ctx.tempura },
        .{ .name = "sjon", .module = ctx.sjon },
    };
}

const Wasm = struct {
    /// The copy into `npm/tempura/`, which the node leg reads.
    copy: *std.Build.Step,
    /// The size budget's check.
    budget: *std.Build.Step,
};

/// `zig build wasm` — tempura.wasm, the browser / studio artifact. The
/// SJON dependency is resolved a second time for wasm32 (modules carry
/// their resolved target). Same flags as SJON's and pacer's own
/// artifacts: freestanding, no entry, rdynamic, ReleaseSmall.
fn addWasm(ctx: Ctx) Wasm {
    const b = ctx.b;
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const sjon_wasm_dep = b.dependency("sjon", .{
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .@"plugin-exec" = false,
    });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm_entry.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
        .imports = &.{.{ .name = "sjon", .module = sjon_wasm_dep.module("sjon") }},
    });
    addSchemas(b, wasm_mod);
    const wasm = b.addExecutable(.{ .name = "tempura", .root_module = wasm_mod });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const install_wasm = b.addInstallArtifact(wasm, .{});

    // …and a second copy INTO `npm/tempura/`, beside the glue that loads
    // it. pacer does this from an npm script; here it rides the build
    // verb, because `node --test` is part of `verify` and a gate that
    // compared the glue against a stale artifact would pass on anything.
    // `.custom = "../npm/tempura"` is relative to the install prefix, so
    // the file lands in the source tree (it is gitignored, regenerated,
    // and never committed).
    const copy_wasm = b.addInstallFileWithDir(
        wasm.getEmittedBin(),
        .{ .custom = "../npm/tempura" },
        "tempura.wasm",
    );
    const wasm_step = b.step("wasm", "Build tempura.wasm (freestanding, ReleaseSmall)");
    wasm_step.dependOn(&install_wasm.step);
    wasm_step.dependOn(&copy_wasm.step);

    // The size budget (plan 10: "the E3 gate pins the size at what it
    // measures and `verify` fails on growth past it"). The ceiling is
    // frozen inside the script, which is also where the reason for every
    // change to it lives. It MEASURES and never builds, so it is wired
    // onto the installed artifact and joined to `verify`.
    const wasm_budget = b.addSystemCommand(&.{"tools/wasm_budget.sh"});
    wasm_budget.setCwd(b.path("."));
    wasm_budget.addFileArg(wasm.getEmittedBin());
    const budget_step = b.step("wasm-budget", "Check tempura.wasm against its frozen size ceiling");
    budget_step.dependOn(&wasm_budget.step);
    return .{ .copy = &copy_wasm.step, .budget = &wasm_budget.step };
}

/// `zig build sjon-wasm` — SJON's own `sjon.wasm`, built from the same
/// PINNED dependency Tempura compiles against and installed under
/// `zig-out/sjon-wasm`. The map proof asks SJON to answer both ends of
/// every span, so it must run SJON's artifact and not whatever a sibling
/// checkout happens to hold: the release archive has source, not a wasm,
/// and a stale `../SJON/zig-out` would silently test a different SJON.
/// SJON's own recipe is one module rooted at `src/wasm.zig`, its
/// `build_options` (plugin dispatch is a host import on wasm), disabled
/// entry and `rdynamic`; `ReleaseSmall` matches its published artifact.
fn addSjonWasm(ctx: Ctx) *std.Build.Step {
    const b = ctx.b;
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const sjon_options = b.addOptions();
    sjon_options.addOption(bool, "plugin_exec", false);
    sjon_options.addOption(bool, "wasm_plugin_host", true);
    const sjon_wasm_mod = b.createModule(.{
        .root_source_file = ctx.sjon_dep.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
        .imports = &.{.{ .name = "build_options", .module = sjon_options.createModule() }},
    });
    const sjon_wasm = b.addExecutable(.{ .name = "sjon", .root_module = sjon_wasm_mod });
    sjon_wasm.entry = .disabled;
    sjon_wasm.rdynamic = true;
    // The artifact lands under the install prefix (`zig-out/sjon-wasm`),
    // outside the package's tracked tree: it is generated, pinned and
    // read only by the node leg.
    const copy = b.addInstallFileWithDir(
        sjon_wasm.getEmittedBin(),
        .{ .custom = "sjon-wasm" },
        "sjon.wasm",
    );
    const step = b.step(
        "sjon-wasm",
        "Build SJON's wasm from the pinned dependency for the map proof",
    );
    step.dependOn(&copy.step);
    return &copy.step;
}

/// `zig build corpus` — the native golden gate. `-- --update`
/// regenerates and the diff is reviewed; a golden is never hand-edited.
/// Returns the run `verify` depends on, which takes no `b.args`.
fn addCorpus(ctx: Ctx) *std.Build.Step {
    const b = ctx.b;
    const corpus_mod = b.createModule(.{
        .root_source_file = b.path("src/corpus_runner.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = &.{.{ .name = "sjon", .module = ctx.sjon }},
    });
    addSchemas(b, corpus_mod);
    const corpus_runner = b.addExecutable(.{ .name = "corpus-runner", .root_module = corpus_mod });
    const run_corpus = b.addRunArtifact(corpus_runner);
    run_corpus.addDirectoryArg(b.path("corpus"));
    if (b.args) |args| run_corpus.addArgs(args);
    run_corpus.has_side_effects = true;
    const corpus_step = b.step(
        "corpus",
        "Verify the golden corpus (native); `-- --update` regenerates",
    );
    corpus_step.dependOn(&run_corpus.step);

    const run_corpus_verify = b.addRunArtifact(corpus_runner);
    run_corpus_verify.addDirectoryArg(b.path("corpus"));
    run_corpus_verify.has_side_effects = true;
    return &run_corpus_verify.step;
}

/// `zig build fixtures` — re-derive the corpus's binary fixtures from the
/// format cores' `Builder`s. The bytes are COMMITTED: this verb only
/// regenerates them, and a `git diff` afterwards is the drift showing
/// (the goldens hash every fixture, so drift fails `corpus` too). Takes
/// the corpus directory the same way the corpus verb does, and goes
/// through the PUBLIC module like the CLI — a fixture that needs a
/// surface `src/root.zig` does not export fails here.
///
/// Its own tests run first: the generator is rooted in `tools/`, so it
/// rides neither `src/root.zig`'s discovery nor `-Dtest-root`, and the
/// verb carries its gate rather than leaving it unreachable.
fn addFixtures(ctx: Ctx) void {
    const b = ctx.b;
    const fixtures_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_fixtures.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = &.{.{ .name = "tempura", .module = ctx.tempura }},
    });
    const fixtures_exe = b.addExecutable(.{ .name = "gen-fixtures", .root_module = fixtures_mod });
    const fixtures_tests = b.addTest(.{ .root_module = fixtures_mod });
    const run_fixtures = b.addRunArtifact(fixtures_exe);
    run_fixtures.addDirectoryArg(b.path("corpus"));
    run_fixtures.has_side_effects = true;
    run_fixtures.step.dependOn(&b.addRunArtifact(fixtures_tests).step);
    const fixtures_step = b.step("fixtures", "Regenerate the corpus's committed binary fixtures");
    fixtures_step.dependOn(&run_fixtures.step);
}

/// `zig build landing` — the pacer landing proof's fixtures.
///
/// Rooted the way `-Dtest-root` is (`srcCopyWithRoot`), and for the same
/// reason: the generator needs `src/export/`, whose files
/// `@import("../time/…")`, so the module root has to sit one level ABOVE
/// the aggregator.
///
/// `landing` REGENERATES `npm/tempura/test/fixtures` (`-- --full` for the
/// exhaustive two-bar sweep instead of the sampled one) and `verify` runs
/// the same tool with `--check`, which renders the same bytes and
/// compares them without writing: a gate that rewrote the fixtures it is
/// about to read would pass on anything (the two legs of
/// `tools/timeline_docs.sh` over one render, same shape). Returns the
/// `--check` run.
fn addLanding(ctx: Ctx) *std.Build.Step {
    const b = ctx.b;
    // The exporter, and the three surfaces a document has to pass through
    // to reach it: the landing tool renders one golden score from
    // `examples/native.sjon`, which is SOURCE and not a hand-built `Doc`,
    // so it needs the schema, the document layer and the time model
    // beside the exporter.
    const landing_root = srcCopyWithRoot(b, "_export_root.zig",
        \\pub const exporter = @import("export/export.zig");
        \\pub const Schema = @import("Schema.zig");
        \\pub const doc = @import("doc/doc.zig");
        \\pub const time = @import("time/time.zig");
        \\
    );
    const landing_src_mod = b.createModule(.{
        .root_source_file = landing_root,
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = &.{.{ .name = "sjon", .module = ctx.sjon }},
    });
    addSchemas(b, landing_src_mod);
    const landing_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_landing.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = &.{.{ .name = "tempura_export", .module = landing_src_mod }},
    });
    // `examples/native.sjon` as bytes, so the landing proof can compile
    // the SHIPPED example through the real `pacer.wasm` rather than a
    // copy of it that could drift (the schemas arrive the same way, and
    // for the same reason).
    landing_mod.addAnonymousImport("example_native", .{
        .root_source_file = b.path("examples/native.sjon"),
    });
    const landing_exe = b.addExecutable(.{ .name = "gen-landing", .root_module = landing_mod });
    const run_landing = b.addRunArtifact(landing_exe);
    run_landing.addDirectoryArg(b.path("npm/tempura/test/fixtures"));
    if (b.args) |args| run_landing.addArgs(args);
    run_landing.has_side_effects = true;
    const landing_step = b.step(
        "landing",
        "Regenerate npm/tempura/test/fixtures for the pacer landing proof",
    );
    landing_step.dependOn(&run_landing.step);

    const check_landing = b.addRunArtifact(landing_exe);
    check_landing.addDirectoryArg(b.path("npm/tempura/test/fixtures"));
    check_landing.addArg("--check");
    return &check_landing.step;
}

const Cli = struct {
    /// The install of the binary, which the node leg's round trip reads.
    install: *std.Build.Step,
    /// The goldens' check leg.
    golden_check: *std.Build.Step,
};

/// `zig build cli` — the native `tempura` multi-tool. Built against the
/// PUBLIC `tempura` module rather than the sources, deliberately: the CLI
/// is a CONSUMER, so going through `@import("tempura")` makes
/// `src/root.zig`'s export list load-bearing — a surface a host needs and
/// the module does not export fails here.
///
/// Installed through its OWN step, not `b.installArtifact`: nothing
/// attaches to the default install step, so a bare `zig build` is a no-op
/// and should stay one. Same shape as the wasm.
fn addCli(ctx: Ctx) Cli {
    const b = ctx.b;
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = &cliImports(ctx),
    });
    const cli_exe = b.addExecutable(.{ .name = "tempura", .root_module = cli_mod });
    const install_cli = b.addInstallArtifact(cli_exe, .{});
    const cli_step = b.step("cli", "Build the tempura CLI (native)");
    cli_step.dependOn(&install_cli.step);
    addRun(b, cli_exe);
    return .{ .install = &install_cli.step, .golden_check = addCliGolden(b, cli_exe) };
}

/// `zig build run -- dump song.mid` — the CLI without the install path.
///
/// The CLI's exit code is a VERDICT ON THE DOCUMENT, not on the CLI: `1`
/// means it has diagnostics, `2` that the invocation was wrong. Ideally
/// the build runner would forward both without calling the build failed,
/// and Zig 0.16 has no way to say that: `expectExitCode` takes ONE `u8`,
/// and `.check` — the only `stdio` mode that tolerates a non-zero exit
/// with no `expect_term` — sends stdout to `.ignore`
/// (`std/Build/Step/Run.zig`), which would throw the artifact away. So
/// this stays `inherit`: every byte the CLI writes reaches the terminal,
/// and after it the runner adds its own "exited with error code N" line.
/// `has_side_effects` is explicit because it is load-bearing — it is what
/// makes the streams inherit rather than be ignored, and what stops the
/// step being cached away.
fn addRun(b: *std.Build, cli_exe: *std.Build.Step.Compile) void {
    const run_cli = b.addRunArtifact(cli_exe);
    run_cli.has_side_effects = true;
    if (b.args) |args| run_cli.addArgs(args);
    const run_step = b.step("run", "Run the tempura CLI (args after `--`)");
    run_step.dependOn(&run_cli.step);
}

/// The binary-level golden: run the freshly built CLI over pinned corpus
/// fixtures and diff the committed output. The in-process tests check
/// shape and rules one assertion at a time; this checks the WHOLE output
/// — exit code, stdout and stderr — in one reviewable diff, and catches a
/// reshuffle nothing happened to assert. Same check-by-default /
/// `--update`-to-write shape as the other scripts, so the gate compares
/// what the verb produces. Returns the check leg.
fn addCliGolden(b: *std.Build, cli_exe: *std.Build.Step.Compile) *std.Build.Step {
    const cli_golden_check = b.addSystemCommand(&.{"tools/cli_golden.sh"});
    cli_golden_check.setCwd(b.path("."));
    cli_golden_check.addArtifactArg(cli_exe);

    const cli_golden_update = b.addSystemCommand(&.{"tools/cli_golden.sh"});
    cli_golden_update.setCwd(b.path("."));
    cli_golden_update.addArtifactArg(cli_exe);
    cli_golden_update.addArg("--update");
    cli_golden_update.has_side_effects = true;
    const cli_golden_step = b.step("cli-golden", "Regenerate the CLI goldens (review the diff)");
    cli_golden_step.dependOn(&cli_golden_update.step);
    return &cli_golden_check.step;
}

/// `zig build fuzz` — never-panic harnesses over the byte-eating and
/// arbitrary-input entrypoints. A SEPARATE target so `verify` stays fast
/// (the SJON precedent); wired like the test root so a harness reaches
/// the same imports.
fn addFuzz(ctx: Ctx) void {
    const b = ctx.b;
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = &.{
            .{ .name = "sjon", .module = ctx.sjon },
            .{ .name = "build_options", .module = ctx.build_options },
        },
    });
    addSchemas(b, fuzz_mod);
    const run_fuzz = b.addRunArtifact(b.addTest(.{ .root_module = fuzz_mod }));
    const fuzz_step = b.step("fuzz", "Run never-panic fuzz harnesses");
    fuzz_step.dependOn(&run_fuzz.step);
}

/// `zig build conform` — the oracle matrix: tempura's readers against
/// libopenmpt and midicsv over every committed fixture, plus the fetched
/// OpenMPT wiki cases.
///
/// NOT joined to `verify`, deliberately (plan 09, "CI shape": brew deps
/// and pinned downloads, "a nightly job, not per commit"). The script
/// installs nothing and vendors nothing: an absent oracle prints
/// `skipped: <tool> not installed` and the run still exits 0, so a
/// machine without the brew packages is not a failing machine. `--
/// --quiet` drops the per-fixture rows.
fn addConform(ctx: Ctx) void {
    const b = ctx.b;
    const conform = b.addSystemCommand(&.{"conformance/conform.sh"});
    conform.setCwd(b.path("."));
    if (b.args) |args| conform.addArgs(args);
    conform.has_side_effects = true;
    const conform_step = b.step("conform", "Run the oracle matrix (libopenmpt, midicsv, the " ++
        "wiki cases); skips with a reason when a tool is absent");
    conform_step.dependOn(&conform.step);
}

/// `schema/pacer.sjon` is a VERBATIM copy of the sibling's manifest. The
/// script diffs it against `../pacer` when that checkout exists and
/// passes with a note when it does not (the copy is then trusted, and its
/// provenance is in CLAUDE.md and the script's header).
fn addPacerDrift(ctx: Ctx) *std.Build.Step {
    const pacer_drift = ctx.b.addSystemCommand(&.{"tools/pacer_schema_drift.sh"});
    // A Run step with no cwd inherits the build runner's — pin it so the
    // relative argv[0] survives `--build-file` from elsewhere.
    pacer_drift.setCwd(ctx.b.path("."));
    return &pacer_drift.step;
}

/// `zig build audit-diagnostics` — assert every `Diag.Code` variant is
/// exercised by name in some `test {}` body (corpus goldens carry numeric
/// codes, so they cannot satisfy the check). Keeps a new code from
/// landing without a test.
fn addAuditDiagnostics(ctx: Ctx) void {
    const b = ctx.b;
    const audit_diagnostics = b.addSystemCommand(&.{"tools/audit_diagnostic_coverage.sh"});
    audit_diagnostics.setCwd(b.path("."));
    const audit_step = b.step("audit-diagnostics", "Audit Diag.Code test coverage");
    audit_step.dependOn(&audit_diagnostics.step);
}

/// `zig build docs` — render `docs/timeline-language.md` from the
/// manifest's own `:description`s, so the timeline language's prose has
/// one source rather than two. SJON's CLI is not exposed as a dependency
/// artifact (its build wires `sjon` to its own `cli` step, not to the
/// install step), so tempura builds it from the dependency's source with
/// the same recipe SJON uses — one module, one import. `plugin-exec =
/// false` is what keeps it from wanting libwasmtime, exactly as the
/// library module does.
///
/// Returns the CHECK leg of the same script, which `verify` runs: a
/// manifest edit that never reached the page fails the gate. Both legs go
/// through one render, so the gate compares what the verb produces.
fn addDocs(ctx: Ctx) *std.Build.Step {
    const b = ctx.b;
    const sjon_cli = b.addExecutable(.{
        .name = "sjon",
        .root_module = b.createModule(.{
            .root_source_file = ctx.sjon_dep.path("src/cli/main.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .imports = &.{.{ .name = "sjon", .module = ctx.sjon }},
        }),
    });
    const timeline_docs = b.addSystemCommand(&.{"tools/timeline_docs.sh"});
    timeline_docs.setCwd(b.path("."));
    timeline_docs.addArtifactArg(sjon_cli);
    timeline_docs.addArg("--update");
    timeline_docs.has_side_effects = true;
    const docs_step = b.step(
        "docs",
        "Regenerate docs/timeline-language.md from schema/tempura.sjon",
    );
    docs_step.dependOn(&timeline_docs.step);

    const timeline_docs_check = b.addSystemCommand(&.{"tools/timeline_docs.sh"});
    timeline_docs_check.setCwd(b.path("."));
    timeline_docs_check.addArtifactArg(sjon_cli);
    return &timeline_docs_check.step;
}

/// `zig build lint` — plan 12's rules as a gate (`tools/lint.zig`'s
/// header lists them). Its own tests run first, as the fixture
/// generator's do: the tool is rooted in `tools/`, so no other root
/// reaches them. `has_side_effects` because the input is the source tree
/// itself, which the build graph does not track as a file dependency.
fn addLint(ctx: Ctx) *std.Build.Step {
    const b = ctx.b;
    const lint_mod = b.createModule(.{
        .root_source_file = b.path("tools/lint.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    const lint_exe = b.addExecutable(.{ .name = "lint", .root_module = lint_mod });
    const run_lint = b.addRunArtifact(lint_exe);
    run_lint.addDirectoryArg(b.path("."));
    run_lint.has_side_effects = true;
    run_lint.step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lint_mod })).step);
    const lint_step = b.step("lint", "Check plan 12's rules: function length, columns, " ++
        "allocator names, proofs, bounds, IO in the core, docs");
    lint_step.dependOn(&run_lint.step);
    return &run_lint.step;
}

/// The landing proof, through the REAL `pacer.wasm` (pacer's
/// `node_test` shape). tempura's own tests cannot catch its model of
/// pacer's `mul + floor` drifting from pacer's own, so this leg is where
/// a printed position is actually read back by the driver.
///
/// `node` is REQUIRED, and the leg must not be gated on
/// `Build.findProgram`: on OpenBSD in Zig 0.16 that call cannot answer
/// (`Io.Dir.realPathFileAlloc` reaches `realPathPosix`, whose OpenBSD
/// case is `error.OperationUnsupported`), so a probe would skip this leg
/// on a host where node runs perfectly well. The Run step resolves
/// `node` through PATH at spawn, so the leg runs; a host with no node
/// fails the gate instead of passing it by omission.
///
/// The fixtures the suite reads are DERIVED, so the gate proves they
/// match this tree (`--check`) rather than rewriting them. That
/// dependency is wired FIRST, before any early return below: a reduced
/// node leg must never drop fixture freshness, which is the half of T1
/// the fixtures carry.
fn addNodeLeg(
    ctx: Ctx,
    verify: *std.Build.Step,
    landing_check: *std.Build.Step,
    copy_wasm: *std.Build.Step,
    install_cli: *std.Build.Step,
    sjon_wasm: *std.Build.Step,
) void {
    const b = ctx.b;
    // Unconditional, with or without node: the fixtures are what the map
    // records are pinned to, so the gate checks them on every run.
    verify.dependOn(landing_check);

    // `npm/tempura` needs its one `file:` dev dependency installed before
    // `node --test` can import the pacer package. A fresh clone has not
    // run `npm install` yet, and failing the whole gate on that would say
    // nothing about the code, so the leg announces itself missing
    // instead. This is a REDUCED gate and the announcement says what it
    // does not prove: the node suite, the wasm map blob and the SJON map
    // proof all live only in the run being skipped.
    //
    // The check is INSIDE the run step, not at graph construction: every
    // command builds this graph, so a graph-time probe printed a
    // `verify: … skipping` line for `zig build cli`, for `wasm`, and for
    // any consumer of the Zig package. The fixture check stays
    // unconditional; only the node run is conditional.
    const node_test = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\if [ -d node_modules/pacer ]; then exec node --test; fi
        \\printf '%s\n' 'verify: npm/tempura/node_modules/pacer is missing; skipping the node suite, the wasm map blob and the SJON map proof (run npm install in npm/tempura, then build pacer wasm in ../pacer)' >&2
        \\exit 0
        ,
    });
    node_test.setCwd(b.path("npm/tempura"));
    node_test.has_side_effects = true;
    // The suite drives `npm/tempura/tempura.wasm` — the exports test, the
    // blob decoders, the corpus parity walk and the fresh-instance round
    // trip all instantiate it — so the copy runs FIRST. A gate that read a
    // stale artifact would pass on anything, which is the same rule the
    // landing fixtures' `--check` leg is written to.
    node_test.step.dependOn(copy_wasm);
    // …and the map proof asks SJON's OWN wasm to answer both ends of every
    // fixture span, so it is built from the same pinned dependency rather
    // than read from a sibling checkout.
    node_test.step.dependOn(sjon_wasm);
    // …and the round trip's native leg compares the wasm's bytes against
    // the CLI's, so the binary it looks for is built too (it degrades to a
    // printed skip without one, and a gate that skips silently is not a
    // gate).
    node_test.step.dependOn(install_cli);
    verify.dependOn(&node_test.step);
}
