const std = @import("std");
const compiler = @import("compiler.zig");

pub const ast = @import("ast.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const token = @import("token.zig");

pub const ZwgslTarget = compiler.Target;
pub const ZwgslErrorKind = compiler.ErrorKind;
pub const ZwgslError = compiler.Error;
pub const ZwgslOptions = compiler.Options;
pub const ZwgslResult = compiler.Result;

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

pub export fn zwgsl_compile(source: [*]const u8, source_len: usize, options: compiler.Options) compiler.Result {
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
    const output = compiler.compile(arena, source_slice, options) catch |err| {
        storage.errors = arena.alloc(compiler.Error, 1) catch return emptyResult();
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

pub export fn zwgsl_free(result: *compiler.Result) void {
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
