const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("yaml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run tests, zigvet and gnarl");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The fuzz targets alone (src/fuzz_test.zig): `zig build fuzz` replays
    // their seeded draws, `zig build fuzz --fuzz` fuzzes them. Only the
    // LLVM backend emits the fuzzer's instrumentation.
    const fuzz_filter = b.option([]const u8, "fuzz-filter", "Fuzz only the targets whose names hold this") orelse "fuzz:";
    const fuzz_tests = b.addTest(.{ .root_module = mod, .filters = &.{fuzz_filter}, .use_llvm = true });
    b.step("fuzz", "Replay the fuzz targets' seeded draws (--fuzz to fuzz)").dependOn(&b.addRunArtifact(fuzz_tests).step);

    // The yaml-test-suite harness (test/main.zig) over the suite's data
    // tree (build.zig.zon's yaml_test_suite, a lazy dependency), held to
    // test/suite-skip.txt. `zig build test` fails on a regression or a
    // listed check that now passes; `zig build suite` prints the counts.
    // Only this repo's own build asks for the data, so a package that
    // depends on this one never fetches it.
    const suite_mod = b.createModule(.{
        .root_source_file = b.path("test/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "yaml", .module = mod }},
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = suite_mod })).step);
    const suite_step = b.step("suite", "Run the yaml-test-suite, print the counts (-- list [--all], -- show <case>)");
    if (b.isRoot()) {
        if (b.lazyDependency("yaml_test_suite", .{})) |suite_data| {
            const harness = b.addExecutable(.{ .name = "suite", .root_module = suite_mod });
            const verbose = suiteRun(b, harness, suite_data);
            verbose.addPassthruArgs();
            suite_step.dependOn(&verbose.step);
            const quiet = suiteRun(b, harness, suite_data);
            quiet.addArgs(&.{ "check", "--quiet" });
            test_step.dependOn(&quiet.step);
        }
    }

    // zigvet (github.com/kmoneil/zigvet) reports code the compiler accepts
    // that is almost certainly wrong. A program on the PATH, not a package.
    // `zig build test` runs it too, so no change is tested without it.
    // zigvet skips zig-pkg and hidden directories by itself.
    const lint = b.addSystemCommand(&.{ "zigvet", "build.zig", "src", "test" });
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

    const fmt = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src"), b.path("test") } });
    b.step("fmt", "Format build.zig, src/ and test/").dependOn(&fmt.step);
}

/// A run of the suite harness over the suite's data, held to the skip list.
fn suiteRun(b: *std.Build, harness: *std.Build.Step.Compile, suite_data: *std.Build.Dependency) *std.Build.Step.Run {
    const run = b.addRunArtifact(harness);
    run.addDirectoryArg(suite_data.path("."));
    run.addArg("--skip");
    run.addFileArg(b.path("test/suite-skip.txt"));
    // It reads the suite's files as it runs, which the build does not
    // see, so a cached pass could stand for a run that would now fail.
    run.has_side_effects = true;
    return run;
}
