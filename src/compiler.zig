const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const glsl_emitter = @import("glsl_emitter.zig");
const ir_builder = @import("ir_builder.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const string_pool = @import("string_pool.zig");
const wgsl_emitter = @import("wgsl_emitter.zig");

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
    compute_source: ?[*:0]const u8 = null,
    errors: ?[*]const Error = null,
    error_count: u32 = 0,
    _internal: ?*anyopaque = null,
};

pub const CompileOutput = struct {
    vertex_source: ?[]const u8 = null,
    fragment_source: ?[]const u8 = null,
    compute_source: ?[]const u8 = null,
    errors: []const Error = &.{},
};

pub fn compile(allocator: std.mem.Allocator, source: []const u8, options: Options) !CompileOutput {
    var pool = string_pool.StringPool.init(allocator);
    defer pool.deinit();

    const tokens = try lexer.Lexer.tokenizeWithPool(allocator, &pool, source);
    var diagnostic_list = diagnostics.DiagnosticList.init(allocator);
    var syntax_parser = parser.Parser.initWithPool(allocator, &pool, source, tokens, &diagnostic_list);
    const program = try syntax_parser.parseProgram();

    if (diagnostic_list.items.items.len > 0) {
        return .{ .errors = try diagnosticsToErrors(allocator, diagnostic_list.items.items) };
    }

    const typed = try sema.analyzeWithPool(allocator, &pool, program, &diagnostic_list);
    if (diagnostic_list.items.items.len > 0) {
        return .{ .errors = try diagnosticsToErrors(allocator, diagnostic_list.items.items) };
    }

    if (typed.compute_block != null and options.target == .glsl_es_300) {
        return singleError(
            allocator,
            "GLSL ES 3.00 backend does not support compute shaders",
            typed.compute_block.?.position.line,
            typed.compute_block.?.position.column,
        );
    }

    const module = try ir_builder.build(allocator, typed);
    const emitted = switch (options.target) {
        .glsl_es_300 => try glsl_emitter.emit(allocator, module, .{
            .emit_debug_comments = options.emit_debug_comments != 0,
            .optimize_output = options.optimize_output != 0,
            .source = source,
        }),
        .wgsl => wgsl_emitter.emit(allocator, module, .{
            .emit_debug_comments = options.emit_debug_comments != 0,
            .optimize_output = options.optimize_output != 0,
            .source = source,
        }) catch |err| switch (err) {
            error.UnsupportedInOutParams => return singleError(allocator, "WGSL backend does not support inout parameters yet", 0, 0),
            error.UnsupportedSamplerType => return singleError(allocator, "WGSL backend encountered an unsupported sampler type", 0, 0),
            error.UnsupportedTextureBuiltin => return singleError(allocator, "WGSL backend encountered an unsupported texture() call", 0, 0),
            error.UnsupportedTextureSource => return singleError(allocator, "WGSL backend only supports texture() on sampler uniforms", 0, 0),
            else => return err,
        },
    };

    return .{
        .vertex_source = emitted.vertex,
        .fragment_source = emitted.fragment,
        .compute_source = emitted.compute,
    };
}

fn diagnosticsToErrors(allocator: std.mem.Allocator, items: []const diagnostics.Diagnostic) ![]Error {
    const errors = try allocator.alloc(Error, items.len);
    for (items, 0..) |item, index| {
        errors[index] = .{
            .kind = switch (item.kind) {
                .@"error" => .semantic,
                .warning => .semantic,
            },
            .message = try allocator.dupeZ(u8, item.message),
            .line = item.line,
            .column = item.column,
        };
    }
    return errors;
}

fn singleError(allocator: std.mem.Allocator, message: []const u8, line: u32, column: u32) !CompileOutput {
    const errors = try allocator.alloc(Error, 1);
    errors[0] = .{
        .kind = .semantic,
        .message = try allocator.dupeZ(u8, message),
        .line = line,
        .column = column,
    };
    return .{ .errors = errors };
}
