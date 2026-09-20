const std = @import("std");
const builtin = @import("builtin");

comptime {
    // `.minimum_zig_version` only gates package-manager consumers; this
    // gives a direct `zig build` on an older toolchain a clear message.
    const required = std.SemanticVersion.parse("0.16.0") catch unreachable;
    if (builtin.zig_version.order(required) == .lt)
        @compileError("tempura requires zig >= 0.16.0 (build.zig.zon minimum_zig_version)");
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

pub fn build(b: *std.Build) void {
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
    // and the project-file test will (pacer's `Schema.zig` does).
    const build_options = b.addOptions();
    build_options.addOptionPath("repo_root", b.path("."));
    const build_options_mod = build_options.createModule();

    // `zig build test` — `src/root.zig` forces discovery of every
    // submodule's inline tests via its `test { _ = X; }` block (the SJON
    // discipline), and every part directory aggregates its own files the
    // same way in `src/<part>/<part>.zig`.
    //
    // `-Dtest-root=time/time.zig` swaps the ROOT of that walk, so one
    // subtree's tests run without editing `src/root.zig`. The module is
    // wired identically either way — sjon, build_options, every schema —
    // so a subtree sees exactly what the root sees and a passing subtree
    // run means the same thing as a passing whole run.
    //
    // The option value is a path RELATIVE TO `src/` (`time/time.zig`,
    // `smf/smf.zig`, `Diag.zig`) and the root is a GENERATED file inside a
    // copy of `src/`, not the aggregator itself. Rooting the module at
    // `src/time/time.zig` would make `src/time/` the module path, and
    // `Pos.zig`'s `@import("../Diag.zig")` is then "outside module path".
    // Keeping the module root one level above every aggregator is what
    // makes a subtree see exactly what the root sees. (`@import` needs a
    // string LITERAL, so the aggregator's name cannot be a build option
    // read at comptime; a comptime switch over an enum does not help
    // either — Zig resolves imports in dead branches too.)
    const test_root = b.option(
        []const u8,
        "test-root",
        "Test root, relative to src/ (e.g. time/time.zig) — run one subtree's tests",
    );
    const test_root_file: std.Build.LazyPath = if (test_root) |p| blk: {
        const wf = b.addWriteFiles();
        _ = wf.addCopyDirectory(b.path("src"), ".", .{});
        break :blk wf.add("_test_root.zig", b.fmt("test {{ _ = @import(\"{s}\"); }}\n", .{p}));
    } else b.path("src/root.zig");
    const test_mod = b.createModule(.{
        .root_source_file = test_root_file,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    addSchemas(b, test_mod);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests (-Dtest-root=<path-relative-to-src> for one subtree)");
    test_step.dependOn(&run_tests.step);

    // `zig build wasm` — tempura.wasm, the browser / studio artifact. The
    // SJON dependency is resolved a second time for wasm32 (modules carry
    // their resolved target). Same flags as SJON's and pacer's own
    // artifacts: freestanding, no entry, rdynamic, ReleaseSmall.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
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
        .imports = &.{
            .{ .name = "sjon", .module = sjon_wasm_dep.module("sjon") },
        },
    });
    addSchemas(b, wasm_mod);
    const wasm = b.addExecutable(.{
        .name = "tempura",
        .root_module = wasm_mod,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const install_wasm = b.addInstallArtifact(wasm, .{});
    const wasm_step = b.step("wasm", "Build tempura.wasm (freestanding, ReleaseSmall)");
    wasm_step.dependOn(&install_wasm.step);

    // `zig build corpus` — the native golden gate. `-- --update`
    // regenerates and the diff is reviewed; a golden is never hand-edited.
    const corpus_mod = b.createModule(.{
        .root_source_file = b.path("src/corpus_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_mod },
        },
    });
    addSchemas(b, corpus_mod);
    const corpus_runner = b.addExecutable(.{
        .name = "corpus-runner",
        .root_module = corpus_mod,
    });
    const run_corpus = b.addRunArtifact(corpus_runner);
    run_corpus.addDirectoryArg(b.path("corpus"));
    if (b.args) |args| run_corpus.addArgs(args);
    run_corpus.has_side_effects = true;
    const corpus_step = b.step("corpus", "Verify the golden corpus (native); `-- --update` regenerates");
    corpus_step.dependOn(&run_corpus.step);

    // `zig build fixtures` — re-derive the corpus's binary fixtures from
    // the format cores' `Builder`s. The bytes are COMMITTED: this verb
    // only regenerates them, and a `git diff` afterwards is the drift
    // showing (the goldens hash every fixture, so drift fails `corpus`
    // too). Takes the corpus directory the same way the corpus verb
    // does, and goes through the PUBLIC module like the CLI — a fixture
    // that needs a surface `src/root.zig` does not export fails here.
    //
    // Its own tests run first: the generator is rooted in `tools/`, so
    // it rides neither `src/root.zig`'s discovery nor `-Dtest-root`, and
    // the verb carries its gate rather than leaving it unreachable.
    const fixtures_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_fixtures.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tempura", .module = tempura_mod }},
    });
    const fixtures_exe = b.addExecutable(.{ .name = "gen-fixtures", .root_module = fixtures_mod });
    const fixtures_tests = b.addTest(.{ .root_module = fixtures_mod });
    const run_fixtures = b.addRunArtifact(fixtures_exe);
    run_fixtures.addDirectoryArg(b.path("corpus"));
    run_fixtures.has_side_effects = true;
    run_fixtures.step.dependOn(&b.addRunArtifact(fixtures_tests).step);
    const fixtures_step = b.step("fixtures", "Regenerate the corpus's committed binary fixtures");
    fixtures_step.dependOn(&run_fixtures.step);

    // `zig build landing` — the pacer landing proof's fixtures.
    //
    // Rooted the way `-Dtest-root` is, and for the same reason: the
    // generator needs `src/export/`, whose files `@import("../time/…")`,
    // so the module root has to sit one level ABOVE the aggregator. A
    // module rooted at `src/export/export.zig` would make `src/export/`
    // the module path and every `..` import "outside module path".
    //
    // The fixtures are WRITTEN into `npm/tempura/test/fixtures` and the
    // node suite reads them there; `-- --full` writes the exhaustive
    // two-bar sweep instead of the sampled one.
    const landing_root = blk: {
        const wf = b.addWriteFiles();
        _ = wf.addCopyDirectory(b.path("src"), ".", .{});
        break :blk wf.add(
            "_export_root.zig",
            "pub const exporter = @import(\"export/export.zig\");\n",
        );
    };
    const landing_src_mod = b.createModule(.{
        .root_source_file = landing_root,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sjon", .module = sjon_mod }},
    });
    addSchemas(b, landing_src_mod);
    const landing_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_landing.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tempura_export", .module = landing_src_mod }},
    });
    const landing_exe = b.addExecutable(.{ .name = "gen-landing", .root_module = landing_mod });
    const run_landing = b.addRunArtifact(landing_exe);
    run_landing.addDirectoryArg(b.path("npm/tempura/test/fixtures"));
    if (b.args) |args| run_landing.addArgs(args);
    run_landing.has_side_effects = true;
    const landing_step = b.step("landing", "Regenerate npm/tempura/test/fixtures for the pacer landing proof");
    landing_step.dependOn(&run_landing.step);

    // `zig build cli` — the native `tempura` multi-tool. Built against the
    // PUBLIC `tempura` module rather than the sources, deliberately: the
    // CLI is a CONSUMER, so going through `@import("tempura")` makes
    // `src/root.zig`'s export list load-bearing — a surface a host needs
    // and the module does not export fails here.
    //
    // Installed through its OWN step, not `b.installArtifact`: nothing
    // attaches to the default install step, so a bare `zig build` is a
    // no-op and should stay one. Same shape as the wasm.
    const cli_imports = [_]std.Build.Module.Import{
        .{ .name = "tempura", .module = tempura_mod },
        .{ .name = "sjon", .module = sjon_mod },
    };
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &cli_imports,
    });
    const cli_exe = b.addExecutable(.{ .name = "tempura", .root_module = cli_mod });
    const install_cli = b.addInstallArtifact(cli_exe, .{});
    const cli_step = b.step("cli", "Build the tempura CLI (native)");
    cli_step.dependOn(&install_cli.step);

    // `zig build run -- dump song.mid` — the CLI without the install path.
    //
    // The CLI's exit code is a VERDICT ON THE DOCUMENT, not on the CLI:
    // `1` means it has diagnostics, `2` that the invocation was wrong.
    // Ideally the build runner would forward both without calling the
    // build failed, and Zig 0.16 has no way to say that: `expectExitCode`
    // takes ONE `u8`, and `.check` — the only `stdio` mode that tolerates
    // a non-zero exit with no `expect_term` — sends stdout to `.ignore`
    // (`std/Build/Step/Run.zig`), which would throw the artifact away.
    // So this stays `inherit`: every byte the CLI writes reaches the
    // terminal, and after it the runner adds its own "exited with error
    // code N" line. `has_side_effects` is explicit because it is
    // load-bearing — it is what makes the streams inherit rather than be
    // ignored, and what stops the step being cached away.
    const run_cli = b.addRunArtifact(cli_exe);
    run_cli.has_side_effects = true;
    if (b.args) |args| run_cli.addArgs(args);
    const run_step = b.step("run", "Run the tempura CLI (args after `--`)");
    run_step.dependOn(&run_cli.step);

    // The CLI's tests are their OWN root. `src/root.zig`'s `test {}` block
    // cannot reach them: these files import the `tempura` MODULE, which
    // inside the core test binary would resolve to a second, distinct
    // instance. `src/cli/Cli.zig` plays root.zig's role one level down,
    // and `zig build test` runs both roots.
    const cli_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/Cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &cli_imports,
    });
    // The CLI tests read repo fixtures (`corpus/…`, `src/cli/testdata/…`)
    // through the same absolute repo root the core tests use, so they do
    // not depend on where `zig build` was invoked from.
    cli_test_mod.addImport("build_options", build_options_mod);
    const cli_tests = b.addTest(.{ .root_module = cli_test_mod });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_step.dependOn(&run_cli_tests.step);

    // The binary-level golden: run the freshly built CLI over pinned
    // corpus fixtures and diff the committed output. The in-process tests
    // check shape and rules one assertion at a time; this checks the WHOLE
    // output — exit code, stdout and stderr — in one reviewable diff, and
    // catches a reshuffle nothing happened to assert. Same
    // check-by-default / `--update`-to-write shape as the other scripts,
    // so the gate compares what the verb produces.
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

    // `zig build fuzz` — never-panic harnesses over the byte-eating and
    // arbitrary-input entrypoints. A SEPARATE target so `verify` stays
    // fast (the SJON precedent); wired like the test root so a harness
    // reaches the same imports.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    addSchemas(b, fuzz_mod);
    const fuzz_test = b.addTest(.{ .root_module = fuzz_mod });
    const run_fuzz = b.addRunArtifact(fuzz_test);
    const fuzz_step = b.step("fuzz", "Run never-panic fuzz harnesses");
    fuzz_step.dependOn(&run_fuzz.step);

    // `schema/pacer.sjon` is a VERBATIM copy of the sibling's manifest.
    // The script diffs it against `../pacer` when that checkout exists and
    // passes with a note when it does not (the copy is then trusted, and
    // its provenance is in CLAUDE.md and the script's header).
    const pacer_drift = b.addSystemCommand(&.{"tools/pacer_schema_drift.sh"});
    // A Run step with no cwd inherits the build runner's — pin it so the
    // relative argv[0] survives `--build-file` from elsewhere.
    pacer_drift.setCwd(b.path("."));

    // `zig build verify` — the whole gate in one verb. The corpus runs
    // through its OWN run step, without `b.args`: `zig build verify --
    // --update` must never regenerate goldens behind the gate's back
    // (regen is the `corpus` verb's business alone).
    const run_corpus_verify = b.addRunArtifact(corpus_runner);
    run_corpus_verify.addDirectoryArg(b.path("corpus"));
    run_corpus_verify.has_side_effects = true;
    const verify_step = b.step("verify", "test + the CLI goldens + native corpus + the pacer-schema drift check + the generated-docs drift check");
    verify_step.dependOn(&run_tests.step);
    verify_step.dependOn(&run_cli_tests.step);
    verify_step.dependOn(&cli_golden_check.step);
    verify_step.dependOn(&run_corpus_verify.step);
    verify_step.dependOn(&pacer_drift.step);

    // …and the landing proof, through the REAL `pacer.wasm` (pacer's
    // `node_test` shape). tempura's own tests cannot catch its model of
    // pacer's `mul + floor` drifting from pacer's own, so this leg is
    // where a printed position is actually read back by the driver. Skip
    // with a printed reason when `node` is not on PATH: a Zig-only
    // checkout still gets the rest of the gate.
    if (b.findProgram(&.{"node"}, &.{})) |_| {
        // The fixtures are DERIVED, so the gate regenerates them first
        // and reads what this tree produces rather than what someone
        // left behind (pacer wires `node_test` to `install_wasm` the
        // same way). `npm/tempura` still needs its one `file:` dev
        // dependency installed and `pacer.wasm` copied beside it —
        // `npm install && npm run build:wasm && npm run build:wasm-copy`
        // there, once.
        const node_test = b.addSystemCommand(&.{ "node", "--test" });
        node_test.setCwd(b.path("npm/tempura"));
        node_test.has_side_effects = true;
        node_test.step.dependOn(&run_landing.step);
        verify_step.dependOn(&node_test.step);
    } else |_| {
        std.debug.print(
            "verify: `node` is not on PATH — skipping the npm/tempura pacer landing test\n",
            .{},
        );
    }

    // `zig build audit-diagnostics` — assert every `Diag.Code` variant is
    // exercised by name in some `test {}` body (corpus goldens carry
    // numeric codes, so they cannot satisfy the check). Keeps a new code
    // from landing without a test.
    const audit_diagnostics = b.addSystemCommand(&.{"tools/audit_diagnostic_coverage.sh"});
    audit_diagnostics.setCwd(b.path("."));
    const audit_diagnostics_step = b.step("audit-diagnostics", "Audit Diag.Code test coverage");
    audit_diagnostics_step.dependOn(&audit_diagnostics.step);

    // `zig build docs` — render `docs/timeline-language.md` from the
    // manifest's own `:description`s, so the timeline language's prose has
    // one source rather than two. SJON's CLI is not exposed as a
    // dependency artifact (its build wires `sjon` to its own `cli` step,
    // not to the install step), so tempura builds it from the
    // dependency's source with the same recipe SJON uses — one module,
    // one import. `plugin-exec = false` is what keeps it from wanting
    // libwasmtime, exactly as the library module does.
    const sjon_cli = b.addExecutable(.{
        .name = "sjon",
        .root_module = b.createModule(.{
            .root_source_file = sjon_dep.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sjon", .module = sjon_mod }},
        }),
    });
    const timeline_docs = b.addSystemCommand(&.{"tools/timeline_docs.sh"});
    timeline_docs.setCwd(b.path("."));
    timeline_docs.addArtifactArg(sjon_cli);
    timeline_docs.addArg("--update");
    timeline_docs.has_side_effects = true;
    const docs_step = b.step("docs", "Regenerate docs/timeline-language.md from schema/tempura.sjon");
    docs_step.dependOn(&timeline_docs.step);

    // …and the CHECK leg of the same script, folded into `verify`: a
    // manifest edit that never reached the page fails the gate. Both legs
    // go through one render, so the gate compares what the verb produces.
    const timeline_docs_check = b.addSystemCommand(&.{"tools/timeline_docs.sh"});
    timeline_docs_check.setCwd(b.path("."));
    timeline_docs_check.addArtifactArg(sjon_cli);
    verify_step.dependOn(&timeline_docs_check.step);
}
