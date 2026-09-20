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
/// `corpus` adds the harness vocabulary, which is NEVER composed with the
/// timeline one — two preloaded bundles, never a shared schema. Only the
/// corpus runner and the test roots carry it.
fn addSchemas(b: *std.Build, mod: *std.Build.Module, corpus: bool) void {
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
    if (corpus) mod.addAnonymousImport("corpus_schema", .{
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
    addSchemas(b, tempura_mod, false);

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
    // `-Dtest-root=src/time/time.zig` swaps the ROOT of that walk, so one
    // subtree's tests run without editing `src/root.zig`. The module is
    // wired identically either way — sjon, build_options, every schema —
    // so a subtree sees exactly what the root sees and a passing subtree
    // run means the same thing as a passing whole run.
    const test_root = b.option(
        []const u8,
        "test-root",
        "Test root source file (default src/root.zig) — run one subtree's tests",
    ) orelse "src/root.zig";
    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_root),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    addSchemas(b, test_mod, true);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests (-Dtest-root=<path> for one subtree)");
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
    addSchemas(b, wasm_mod, false);
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
    addSchemas(b, corpus_mod, true);
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
    const run_cli = b.addRunArtifact(cli_exe);
    if (b.args) |args| run_cli.addArgs(args);
    const run_step = b.step("run", "Run the tempura CLI (args after `--`)");
    run_step.dependOn(&run_cli.step);

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
    addSchemas(b, fuzz_mod, true);
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
    const verify_step = b.step("verify", "test + native corpus + the pacer-schema drift check");
    verify_step.dependOn(&run_tests.step);
    verify_step.dependOn(&run_corpus_verify.step);
    verify_step.dependOn(&pacer_drift.step);

    // `zig build audit-diagnostics` — assert every `Diag.Code` variant is
    // exercised by name in some `test {}` body (corpus goldens carry
    // numeric codes, so they cannot satisfy the check). Keeps a new code
    // from landing without a test.
    const audit_diagnostics = b.addSystemCommand(&.{"tools/audit_diagnostic_coverage.sh"});
    audit_diagnostics.setCwd(b.path("."));
    const audit_diagnostics_step = b.step("audit-diagnostics", "Audit Diag.Code test coverage");
    audit_diagnostics_step.dependOn(&audit_diagnostics.step);

    // TODO(P99/Task 6): `zig build docs` — regenerate
    // `docs/timeline-language.md` from `schema/tempura.sjon`'s own
    // `:description`s (pacer's `score-docs` verb: build SJON's CLI from
    // the path dependency's source, render, and fold the drift leg into
    // `verify` so a manifest edit that never reached the page fails).
}
