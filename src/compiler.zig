const std = @import("std");

pub const Target = enum(c_int) {
    glsl_es_300 = 0,
    wgsl = 1,
};

pub const ErrorKind = enum(c_int) {
    ok = 0,
    syntax = 1,
    type = 2,
    semantic = 3,
    internal = 99,
};

pub const Error = extern struct {
    kind: ErrorKind,
    message: [*:0]const u8,
    line: u32,
    column: u32,
};

pub const Options = extern struct {
    target: Target = .glsl_es_300,
    emit_debug_comments: c_int = 0,
    optimize_output: c_int = 0,
};

pub const Result = extern struct {
    vertex_source: ?[*:0]const u8 = null,
    fragment_source: ?[*:0]const u8 = null,
    errors: ?[*]const Error = null,
    error_count: u32 = 0,
    _internal: ?*anyopaque = null,
};

pub const CompileOutput = struct {
    vertex_source: ?[]const u8 = null,
    fragment_source: ?[]const u8 = null,
    errors: []const Error = &.{},
};

pub fn compile(allocator: std.mem.Allocator, source: []const u8, options: Options) !CompileOutput {
    _ = allocator;
    _ = source;
    return switch (options.target) {
        .glsl_es_300 => .{},
        .wgsl => .{
            .errors = &[_]Error{.{
                .kind = .semantic,
                .message = "WGSL backend is not implemented yet",
                .line = 0,
                .column = 0,
            }},
        },
    };
}
