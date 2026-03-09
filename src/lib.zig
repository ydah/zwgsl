const std = @import("std");
const compiler_api = @import("compiler.zig");

pub const ast = @import("ast.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const builtins = @import("builtins.zig");
pub const compiler = compiler_api;
pub const glsl_emitter = @import("glsl_emitter.zig");
pub const ir = @import("ir.zig");
pub const ir_builder = @import("ir_builder.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const sema = @import("sema.zig");
pub const string_pool = @import("string_pool.zig");
pub const token = @import("token.zig");
pub const types = @import("types.zig");

pub const ZwgslTarget = compiler_api.Target;
pub const ZwgslErrorKind = compiler_api.ErrorKind;
pub const ZwgslError = compiler_api.Error;
pub const ZwgslOptions = compiler_api.Options;
pub const ZwgslResult = compiler_api.Result;

const VERSION: [*:0]const u8 = "0.1.0";

const ResultStorage = struct {
    arena: std.heap.ArenaAllocator,
    errors: []compiler.Error = &.{},
    vertex_source: ?[:0]u8 = null,
    fragment_source: ?[:0]u8 = null,
};

fn emptyResult() compiler.Result {
    return .{
        .vertex_source = null,
        .fragment_source = null,
        .errors = null,
        .error_count = 0,
        ._internal = null,
    };
}

pub export fn zwgsl_compile(source: [*]const u8, source_len: usize, options: compiler_api.Options) compiler_api.Result {
    var storage = std.heap.c_allocator.create(ResultStorage) catch return emptyResult();
    storage.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
    };
    errdefer {
        storage.arena.deinit();
        std.heap.c_allocator.destroy(storage);
    }

    const arena = storage.arena.allocator();
    const source_slice = source[0..source_len];
    const output = compiler_api.compile(arena, source_slice, options) catch |err| {
        storage.errors = arena.alloc(compiler_api.Error, 1) catch return emptyResult();
        storage.errors[0] = .{
            .kind = .internal,
            .message = arena.dupeZ(u8, @errorName(err)) catch return emptyResult(),
            .line = 0,
            .column = 0,
        };
        return .{
            .errors = storage.errors.ptr,
            .error_count = 1,
            ._internal = storage,
        };
    };

    if (output.vertex_source) |vertex| {
        storage.vertex_source = arena.dupeZ(u8, vertex) catch return emptyResult();
    }
    if (output.fragment_source) |fragment| {
        storage.fragment_source = arena.dupeZ(u8, fragment) catch return emptyResult();
    }
    if (output.errors.len > 0) {
        storage.errors = arena.alloc(compiler.Error, output.errors.len) catch return emptyResult();
        @memcpy(storage.errors, output.errors);
    }

    return .{
        .vertex_source = if (storage.vertex_source) |value| value.ptr else null,
        .fragment_source = if (storage.fragment_source) |value| value.ptr else null,
        .errors = if (storage.errors.len > 0) storage.errors.ptr else null,
        .error_count = @intCast(storage.errors.len),
        ._internal = storage,
    };
}

pub export fn zwgsl_free(result: *compiler_api.Result) void {
    const internal = result._internal orelse return;
    const storage: *ResultStorage = @ptrCast(@alignCast(internal));
    storage.arena.deinit();
    std.heap.c_allocator.destroy(storage);
    result.* = emptyResult();
}

pub export fn zwgsl_version() [*:0]const u8 {
    return VERSION;
}

test "version is stable" {
    try std.testing.expectEqualStrings("0.1.0", std.mem.span(zwgsl_version()));
}

test "C API compiles a basic shader" {
    const source =
        \\version "300 es"
        \\precision :fragment, :highp
        \\
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  def main
        \\    gl_Position = vec4(position, 1.0)
        \\  end
        \\end
        \\
        \\fragment do
        \\  output :frag_color, Vec4, location: 0
        \\  def main
        \\    frag_color = vec4(1.0)
        \\  end
        \\end
    ;

    var result = zwgsl_compile(source.ptr, source.len, .{});
    defer zwgsl_free(&result);

    try std.testing.expectEqual(@as(u32, 0), result.error_count);
    try std.testing.expect(result.vertex_source != null);
    try std.testing.expect(result.fragment_source != null);
}

test "C API returns semantic errors" {
    const source =
        \\vertex do
        \\  def main
        \\    gl_Position = vec4(position, 1.0)
        \\  end
        \\end
    ;

    var result = zwgsl_compile(source.ptr, source.len, .{});
    defer zwgsl_free(&result);

    try std.testing.expect(result.error_count > 0);
    try std.testing.expect(result.errors != null);
}
