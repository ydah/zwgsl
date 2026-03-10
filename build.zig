const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const static_lib = b.addLibrary(.{
        .name = "zwgsl",
        .linkage = .static,
        .root_module = lib_module,
    });
    static_lib.linkLibC();
    static_lib.installHeader(b.path("include/zwgsl.h"), "zwgsl.h");
    b.installArtifact(static_lib);

    const shared_lib = b.addLibrary(.{
        .name = "zwgsl",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    shared_lib.linkLibC();
    b.installArtifact(shared_lib);

    const lsp_server = b.addExecutable(.{
        .name = "zwgsl-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp/server.zig"),
            .imports = &.{
                .{
                    .name = "zwgsl",
                    .module = lib_module,
                },
            },
            .target = target,
            .optimize = optimize,
        }),
    });
    lsp_server.linkLibC();
    b.installArtifact(lsp_server);

    const wasm_lib = b.addLibrary(.{
        .name = "zwgsl-wasm",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = .ReleaseSmall,
        }),
    });
    const wasm_step = b.step("wasm", "Build the freestanding wasm32 library");
    wasm_step.dependOn(&wasm_lib.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_runner.zig"),
            .imports = &.{
                .{
                    .name = "zwgsl",
                    .module = lib_module,
                },
            },
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
