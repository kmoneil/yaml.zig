const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("yaml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run tests, zigvet and gnarl");
    const harness = addTests(b, test_step, target, optimize, mod);

    // The same tests with yaml built ReleaseSafe and ReleaseFast. A
    // consumer builds this library in the mode it ships; in ReleaseFast
    // `unreachable`, overflow and a cast out of range are undefined, not
    // a panic, and ReleaseSafe is where they still panic. `zig build test
    // test-release` runs all three.
    const release_step = b.step("test-release", "Run the unit tests, examples and suite with yaml built ReleaseSafe and ReleaseFast");
    for ([_]std.builtin.Optimize{ .safe, .fast }) |mode| {
        const release_mod = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = mode });
        _ = addTests(b, release_step, target, mode, release_mod);
    }

    // tools/doc_examples.zig fails when the README's copy of an example
    // differs from its file in examples/. `zig build doc-examples --
    // --fix` rewrites the README's copies from the files.
    const doc_examples = b.addExecutable(.{ .name = "doc-examples", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/doc_examples.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    }) });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = doc_examples.root_module })).step);
    // It reads files the build does not track: always run it (it takes
    // milliseconds).
    const check_docs = b.addRunArtifact(doc_examples);
    check_docs.setCwd(b.path("."));
    check_docs.has_side_effects = true;
    test_step.dependOn(&check_docs.step);
    const fix_docs = b.addRunArtifact(doc_examples);
    fix_docs.setCwd(b.path("."));
    fix_docs.has_side_effects = true;
    fix_docs.addPassthruArgs();
    b.step("doc-examples", "Check the examples in README.md against examples/ (-- --fix: rewrite them)").dependOn(&fix_docs.step);

    // The API reference, from the doc comments: zig-out/docs/index.html.
    const lib = b.addLibrary(.{ .name = "yaml", .root_module = mod });
    const docs = b.addInstallDirectory(.{ .source_dir = lib.getEmittedDocs(), .install_dir = .prefix, .install_subdir = "docs" });
    b.step("docs", "Build the API reference into zig-out/docs").dependOn(&docs.step);

    // The fuzz targets alone (src/fuzz_test.zig): `zig build fuzz` replays
    // their seeded draws, `zig build fuzz --fuzz` fuzzes them. Only the
    // LLVM backend emits the fuzzer's instrumentation.
    const fuzz_filter = b.option([]const u8, "fuzz-filter", "Fuzz only the targets whose names hold this") orelse "fuzz:";
    const fuzz_tests = b.addTest(.{ .root_module = mod, .filters = &.{fuzz_filter}, .use_llvm = true });
    b.step("fuzz", "Replay the fuzz targets' seeded draws (--fuzz to fuzz)").dependOn(&b.addRunArtifact(fuzz_tests).step);

    // `zig build suite` prints the yaml-test-suite's counts (addTests).
    const suite_step = b.step("suite", "Run the yaml-test-suite, print the counts (-- list [--all], -- show <case>)");
    if (harness) |h| {
        const verbose = suiteRun(b, h, suiteData(b).?);
        verbose.addPassthruArgs();
        suite_step.dependOn(&verbose.step);
    }

    // zigvet (github.com/kmoneil/zigvet) reports code the compiler accepts
    // that is almost certainly wrong. A program on the PATH, not a package.
    // `zig build test` runs it too, so no change is tested without it.
    // zigvet skips zig-pkg and hidden directories by itself.
    const lint = b.addSystemCommand(&.{ "zigvet", "build.zig", "src", "test", "tools", "examples" });
    lint.setCwd(b.path("."));
    b.step("lint", "Report code that compiles but is wrong (zigvet, from the PATH)").dependOn(&lint.step);
    test_step.dependOn(&lint.step);

    // gnarl (github.com/kmoneil/gnarl) holds each function to the
    // complexity limits of its class in complexity.zon, which also names
    // the gnarl release the code is judged by; complexity.baseline holds
    // today's debt, so `--check` fails only what is new or worse. A pass
    // prints nothing. Always run: the build does not know what gnarl
    // reads, and a cached step would pass a regression unseen.
    const complexity = b.addSystemCommand(&.{ "gnarl", "--check", "." });
    complexity.setCwd(b.path("."));
    complexity.has_side_effects = true;
    b.step("complexity", "Fail a function newly over its complexity limit (gnarl, from the PATH)").dependOn(&complexity.step);
    test_step.dependOn(&complexity.step);

    const fmt = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src"), b.path("test"), b.path("tools"), b.path("examples") } });
    b.step("fmt", "Format the Zig in build.zig, src/, test/, tools/ and examples/").dependOn(&fmt.step);
}

/// The tests of yaml built in `optimize`, as `yaml` is, as steps `step`
/// depends on: its unit tests; the examples README.md shows, each a test
/// in examples/; and the yaml-test-suite harness (test/main.zig), its
/// own tests and its check over the suite's data held to
/// test/suite-skip.txt, failing on a regression or a listed check that
/// now passes. Returns the harness, null when the data is not fetched.
fn addTests(b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, yaml: *std.Build.Module) ?*std.Build.Step.Compile {
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = yaml })).step);
    const examples_mod = b.createModule(.{
        .root_source_file = b.path("examples/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "yaml", .module = yaml }},
    });
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = examples_mod })).step);
    const suite_mod = b.createModule(.{
        .root_source_file = b.path("test/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "yaml", .module = yaml }},
    });
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = suite_mod })).step);
    const suite_data = suiteData(b) orelse return null;
    const harness = b.addExecutable(.{ .name = "suite", .root_module = suite_mod });
    const quiet = suiteRun(b, harness, suite_data);
    quiet.addArgs(&.{ "check", "--quiet" });
    step.dependOn(&quiet.step);
    return harness;
}

/// The yaml-test-suite's data tree (build.zig.zon's yaml_test_suite, a
/// lazy dependency), or null until it is fetched. Only this repo's own
/// build asks for it, so a package that depends on this one never
/// fetches it.
fn suiteData(b: *std.Build) ?*std.Build.Dependency {
    if (!b.isRoot()) return null;
    return b.lazyDependency("yaml_test_suite", .{});
}

/// A run of the suite harness over the suite's data, held to the skip list.
fn suiteRun(b: *std.Build, harness: *std.Build.Step.Compile, suite_data: *std.Build.Dependency) *std.Build.Step.Run {
    const run = b.addRunArtifact(harness);
    run.addDirectoryArg(suite_data.path("."));
    run.addArg("--skip");
    run.addFileArg(b.path("test/suite-skip.txt"));
    // Its suite table is held to the counts, and `-- readme` writes it.
    run.addArg("--readme");
    run.addFileArg(b.path("README.md"));
    // It reads the suite's files as it runs, which the build does not
    // see, so a cached pass could stand for a run that would now fail.
    run.has_side_effects = true;
    return run;
}
