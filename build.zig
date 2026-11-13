const std = @import("std");
const zon = @import("build.zig.zon");

/// What a GitHub release carries: the `yaml` command for each platform,
/// named yaml-<os>-<arch> as the Homebrew formula names them.
const release_targets = [_]struct { query: std.Target.Query, name: []const u8 }{
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux }, .name = "yaml-linux-amd64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux }, .name = "yaml-linux-arm64" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .name = "yaml-darwin-amd64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "yaml-darwin-arm64" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .name = "yaml-windows-amd64.exe" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .windows }, .name = "yaml-windows-arm64.exe" },
};

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

    // The `yaml` command (src/cli): `zig build` installs it in zig-out/bin.
    // Its tests: its parts', and the command run end to end (test/cli.zig).
    // `yaml --version` prints build.zig.zon's version; the release workflow
    // refuses a tag that does not match it.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", zon.version);
    const cli = b.addExecutable(.{ .name = "yaml", .root_module = cliModule(b, target, optimize, mod, build_options) });
    b.installArtifact(cli);
    // `zig build release`: the command for every platform a release
    // carries, into zig-out/release/.
    const release = b.step("release", "Build the yaml command for every release platform into zig-out/release/");
    for (release_targets) |release_target| release.dependOn(releaseBinary(b, release_target.query, release_target.name, build_options));

    // pyyaml-zig (python/, karte t63): the CPython extension, built against
    // the headers of the Python -Dpython-include names (python3 -c "import
    // sysconfig; print(sysconfig.get_paths()['include'])"), into
    // zig-out/python/pyyaml_zig/ with the package's Python files, which
    // PYTHONPATH=zig-out/python imports. The stable ABI (python/src/python.h):
    // one build serves CPython 3.9 and later. Its symbols are Python's: on
    // Windows linked through python3.lib in the -Dpython-lib directory,
    // elsewhere left to be found where the library is loaded. No libc, so
    // on Linux one library serves glibc and musl.
    if (b.option([]const u8, "python-include", "Python's include directory, for pyyaml-zig (zig build python)")) |include| {
        const python_c = b.addTranslateC(.{ .root_source_file = b.path("python/src/python.h"), .target = target, .optimize = optimize, .link_libc = true });
        python_c.addIncludePath(.{ .cwd_relative = include });
        // Translating needs libc's headers; the extension calls nothing in
        // libc, so the translated module links none.
        const python_mod = python_c.createModule();
        python_mod.link_libc = false;
        const ext_mod = b.createModule(.{
            .root_source_file = b.path("python/src/ext.zig"),
            .target = target,
            .optimize = optimize,
            // A wheel's library carries no debug info, which holds the paths
            // of the machine that built it.
            .strip = optimize != .debug,
            .imports = &.{
                .{ .name = "yaml", .module = mod },
                .{ .name = "python", .module = python_mod },
            },
        });
        ext_mod.addOptions("build_options", build_options);
        const ext = b.addLibrary(.{ .linkage = .dynamic, .name = "_yaml", .root_module = ext_mod });
        const windows = target.result.os.tag == .windows;
        if (windows) {
            const lib_dir = b.option([]const u8, "python-lib", "On Windows, the directory holding Python's python3.lib") orelse
                @panic("-Dpython-lib names the directory holding python3.lib, on Windows");
            ext_mod.addLibraryPath(.{ .cwd_relative = lib_dir });
            ext_mod.linkSystemLibrary("python3", .{});
        } else {
            ext.linker_allow_shlib_undefined = true;
        }
        const python_step = b.step("python", "Build pyyaml-zig into zig-out/python/ (-Dpython-include=...)");
        python_step.dependOn(&b.addInstallFileWithDir(ext.getEmittedBin(), .{ .custom = "python/pyyaml_zig" }, if (windows) "_yaml.pyd" else "_yaml.abi3.so").step);
        python_step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("python/src/pyyaml_zig"), .install_dir = .{ .custom = "python/pyyaml_zig" }, .install_subdir = "" }).step);
    }
    // `zig build run -- check config.yaml`: the command, built and run,
    // with the arguments after `--`.
    const run_cli = b.addRunArtifact(cli);
    run_cli.addPassthruArgs();
    b.step("run", "Run the yaml command: zig build run -- check FILE... (-- --help for all)").dependOn(&run_cli.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli.root_module })).step);
    const cli_options = b.addOptions();
    cli_options.addOptionPath("yaml_exe", cli.getEmittedBin());
    cli_options.addOption([]const u8, "version", zon.version);
    const cli_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/cli.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    cli_test.root_module.addOptions("test_options", cli_options);
    test_step.dependOn(&b.addRunArtifact(cli_test).step);

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

    // `zig build differential -Ddifferential` (src/differential_test.zig,
    // karte t68): the parser's events held to libfyaml's, the target's
    // seeded draws and every suite input; `--fuzz` fuzzes. Only then is
    // libfyaml fetched, so no other build needs it, or a network.
    const differential_step = b.step("differential", "Hold the parser's events to libfyaml's (-Ddifferential; --fuzz to fuzz)");
    if (b.option(bool, "differential", "Fetch libfyaml, for zig build differential") orelse false) {
        differential(b, differential_step, target, optimize);
    } else {
        differential_step.dependOn(&b.addFail("zig build differential needs -Ddifferential, which fetches libfyaml").step);
    }

    // `zig build suite` prints the yaml-test-suite's counts (addTests).
    const suite_step = b.step("suite", "Run the yaml-test-suite, print the counts (-- list [--all], -- show <case>)");
    if (harness) |h| {
        const verbose = suiteRun(b, h, suiteData(b).?);
        verbose.addPassthruArgs();
        suite_step.dependOn(&verbose.step);
    }

    // `zig build bench [-- records [runs]]` (tools/bench.zig, karte t46):
    // each stage's median time, allocations, bytes and peak over a
    // generated document, the library built ReleaseFast whatever
    // -Doptimize says, as a consumer ships it. Not in `test`: its numbers
    // are read, not checked.
    const bench_yaml = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = .fast });
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = .fast,
            .imports = &.{.{ .name = "yaml", .module = bench_yaml }},
            // Its `file` mode runs on malloc, as the libraries it is held to.
            .link_libc = true,
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    run_bench.has_side_effects = true;
    b.step("bench", "Time each stage and count its allocations (-- records runs)").dependOn(&run_bench.step);
    // It is compiled by `test`, so an API change cannot leave it broken.
    test_step.dependOn(&bench.step);

    // The security catalog (test/security/CATALOG.md): every covered row
    // names a test that exists, and every `security: ...` test is in a
    // row. It reads files the build does not track: always run it.
    const catalog_tool = b.addExecutable(.{ .name = "security-catalog", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/security_catalog.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    }) });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = catalog_tool.root_module })).step);
    const check_catalog = b.addRunArtifact(catalog_tool);
    check_catalog.setCwd(b.path("."));
    check_catalog.addArgs(&.{ "test/security/CATALOG.md", "test/security" });
    check_catalog.has_side_effects = true;
    test_step.dependOn(&check_catalog.step);
    const security_step = b.step("security", "Run the security suite and check its catalog (test/security)");
    // With LLVM, as addTests builds it: its stack test is LLVM's figure.
    security_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = securityModule(b, target, optimize, mod), .use_llvm = true })).step);
    security_step.dependOn(&check_catalog.step);

    // zigvet (github.com/kmoneil/zigvet) reports code the compiler accepts
    // that is almost certainly wrong. A program on the PATH, not a package.
    // `zig build test` runs it too, so no change is tested without it.
    // zigvet skips zig-pkg and hidden directories by itself.
    const lint = b.addSystemCommand(&.{ "zigvet", "build.zig", "src", "test", "tools", "examples", "python" });
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

    const fmt = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src"), b.path("test"), b.path("tools"), b.path("examples"), b.path("python") } });
    b.step("fmt", "Format the Zig in build.zig, src/, test/, tools/ and examples/").dependOn(&fmt.step);
}

/// The tests of yaml built in `optimize`, as `yaml` is, as steps `step`
/// depends on: its unit tests; the examples README.md shows, each a test
/// in examples/; and the yaml-test-suite harness (test/main.zig), its
/// own tests and its check over the suite's data held to
/// test/suite-skip.txt, failing on a regression or a listed check that
/// now passes. Returns the harness, null when the data is not fetched.
fn addTests(b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, yaml: *std.Build.Module) ?*std.Build.Step.Compile {
    // The unit tests and the security suite hold construction to what
    // ParseOptions.max_depth and the guide say a level takes: the deepest
    // document the defaults take, on a 512 KiB stack. Those figures are
    // LLVM's, so these build with LLVM on every target: Zig's own x86_64
    // backend, the default for a Debug build on Linux, takes more stack a
    // level, and overflowed there.
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = yaml, .use_llvm = true })).step);
    const examples_mod = b.createModule(.{
        .root_source_file = b.path("examples/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "yaml", .module = yaml }},
    });
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = examples_mod })).step);
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = securityModule(b, target, optimize, yaml), .use_llvm = true })).step);
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

/// The `yaml` command's module, over `yaml`, built for `target`.
fn cliModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, yaml: *std.Build.Module, options: *std.Build.Step.Options) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "yaml", .module = yaml }},
    });
    m.addOptions("build_options", options);
    return m;
}

/// One release binary: ReleaseSafe, so a bug stops `yaml` with a message
/// rather than letting it print a wrong answer, and stripped, since the
/// debug info holds the paths of the machine that built it.
fn releaseBinary(b: *std.Build, query: std.Target.Query, name: []const u8, options: *std.Build.Step.Options) *std.Build.Step {
    const target = b.resolveTargetQuery(query);
    const yaml = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = .ReleaseSafe });
    const exe = b.addExecutable(.{ .name = "yaml", .root_module = cliModule(b, target, .ReleaseSafe, yaml, options) });
    exe.root_module.strip = true;
    const install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "release" } },
        .dest_sub_path = name,
        .pdb_dir = .disabled,
    });
    return &install.step;
}

/// The security suite (test/security, karte t44), a test per known
/// attack on a YAML library, through the public API only.
fn securityModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, yaml: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("test/security/security_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "yaml", .module = yaml }},
    });
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

/// libfyaml's library sources, under its src/, as its CMakeLists.txt
/// lists them, BLAKE3's SIMD variants left out (tools/differential/config.h).
const libfyaml_sources = [_][]const u8{
    "lib/fy-accel.c",                  "lib/fy-atom.c",                   "lib/fy-composer.c",
    "lib/fy-diag.c",                   "lib/fy-doc.c",                    "lib/fy-docbuilder.c",
    "lib/fy-docstate.c",               "lib/fy-dump.c",                   "lib/fy-emit.c",
    "lib/fy-event.c",                  "lib/fy-input.c",                  "lib/fy-parse.c",
    "lib/fy-path.c",                   "lib/fy-token.c",                  "lib/fy-types.c",
    "lib/fy-walk.c",                   "util/fy-blob.c",                  "util/fy-ctype.c",
    "util/fy-utf8.c",                  "util/fy-utils.c",                 "xxhash/xxhash.c",
    "thread/fy-thread.c",              "allocator/fy-allocator.c",        "allocator/fy-allocator-linear.c",
    "allocator/fy-allocator-malloc.c", "allocator/fy-allocator-mremap.c", "allocator/fy-allocator-dedup.c",
    "allocator/fy-allocator-auto.c",   "blake3/blake3_host_state.c",      "blake3/blake3_backend.c",
    "blake3/blake3_be_cpusimd.c",      "blake3/fy-blake3.c",              "lib/fy-composer-diag.c",
    "lib/fy-doc-diag.c",               "lib/fy-docbuilder-diag.c",        "lib/fy-input-diag.c",
    "lib/fy-parse-diag.c",
};

/// `zig build differential`'s work (t68): libfyaml and the shim compiled
/// into one library, linked into the fuzz target and into the check of
/// every suite input, which takes the suite's directory as the suite
/// harness does. Nothing while a dependency is fetched.
///
/// The test binary runs its own tests alone (the filter): the library's
/// come with root.zig, and `test` runs them. With them, `--fuzz` shared
/// its runs among the library's fuzz targets too, and on Linux one test
/// on a thread of its own hung: with libc and libfyaml linked, Zig
/// 0.17.1's stack unwinder faulted in the testing allocator, and the
/// fault handler waited on a lock the unwinder held.
fn differential(b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const fy = b.lazyDependency("libfyaml", .{}) orelse return;
    const suite = suiteData(b) orelse return;
    const c = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    c.addIncludePath(b.path("tools/differential"));
    for ([_][]const u8{ "include", "src/lib", "src/util", "src/xxhash", "src/thread", "src/allocator", "src/blake3", "src/tool", "src/valgrind" }) |dir| c.addIncludePath(fy.path(dir));
    // Its own code, as its release build compiles it: a trap from the
    // C sanitizer a Debug build adds would be libfyaml's, no disagreement.
    const flags = [_][]const u8{ "-std=gnu11", "-DHAVE_CONFIG_H", "-D_GNU_SOURCE", "-DNDEBUG", "-w", "-fno-sanitize=undefined" };
    c.addCSourceFiles(.{ .root = fy.path("src"), .files = &libfyaml_sources, .flags = &flags });
    c.addCSourceFiles(.{ .root = fy.path("src/blake3"), .files = &.{ "blake3_portable.c", "blake3.c" }, .flags = &(flags ++ [_][]const u8{ "-DHASHER_SUFFIX=portable", "-DSIMD_DEGREE=1" }) });
    // Its fy-tool's printer, writing to memory (redirect.h), and the shim.
    c.addCSourceFile(.{ .file = fy.path("src/tool/fy-tool-dump.c"), .flags = &(flags ++ [_][]const u8{ "-include", "tools/differential/redirect.h" }) });
    c.addCSourceFile(.{ .file = b.path("tools/differential/shim.c"), .flags = &flags });
    const lib = b.addLibrary(.{ .name = "fyshim", .linkage = .static, .root_module = c });

    const tests_mod = b.createModule(.{ .root_source_file = b.path("src/differential_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    tests_mod.linkLibrary(lib);
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tests_mod, .use_llvm = true, .filters = &.{"differential_test.test."} })).step);

    const check_mod = b.createModule(.{ .root_source_file = b.path("src/differential_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    check_mod.linkLibrary(lib);
    const check = b.addRunArtifact(b.addExecutable(.{ .name = "differential-suite", .root_module = check_mod }));
    check.addDirectoryArg(suite.path("."));
    step.dependOn(&check.step);
}
