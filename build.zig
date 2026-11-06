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

    // The yaml-test-suite: test/suite.zig reads its data tree (build.zig.zon's
    // yaml_test_suite, a lazy dependency). Only this repo's own build asks
    // for it, so a package that depends on this one never fetches it.
    const suite_mod = b.createModule(.{
        .root_source_file = b.path("test/suite.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = suite_mod })).step);
    const suite_step = b.step("suite", "Count the yaml-test-suite's cases (-- --list lists each)");
    if (b.isRoot()) {
        if (b.lazyDependency("yaml_test_suite", .{})) |suite_data| {
            const list = b.addRunArtifact(b.addExecutable(.{ .name = "suite", .root_module = suite_mod }));
            list.addDirectoryArg(suite_data.path("."));
            list.addPassthruArgs();
            suite_step.dependOn(&list.step);
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
