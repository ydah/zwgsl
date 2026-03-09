const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const glsl_emitter = @import("glsl_emitter.zig");
const ir_builder = @import("ir_builder.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");

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
    if (options.target == .wgsl) {
        const errors = try allocator.alloc(Error, 1);
        errors[0] = .{
            .kind = .semantic,
            .message = try allocator.dupeZ(u8, "WGSL backend is not implemented yet"),
            .line = 0,
            .column = 0,
        };
        return .{ .errors = errors };
    }

    const tokens = try lexer.Lexer.tokenize(allocator, source);
    var diagnostic_list = diagnostics.DiagnosticList.init(allocator);
    var syntax_parser = parser.Parser.init(allocator, source, tokens, &diagnostic_list);
    const program = try syntax_parser.parseProgram();

    if (diagnostic_list.items.items.len > 0) {
        return .{ .errors = try diagnosticsToErrors(allocator, diagnostic_list.items.items) };
    }

    const typed = try sema.analyze(allocator, program, &diagnostic_list);
    if (diagnostic_list.items.items.len > 0) {
        return .{ .errors = try diagnosticsToErrors(allocator, diagnostic_list.items.items) };
    }

    const module = try ir_builder.build(allocator, typed);
    const emitted = try glsl_emitter.emit(allocator, module, .{
        .emit_debug_comments = options.emit_debug_comments != 0,
        .optimize_output = options.optimize_output != 0,
        .source = source,
    });

    return .{
        .vertex_source = emitted.vertex,
        .fragment_source = emitted.fragment,
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
