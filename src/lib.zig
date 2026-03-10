const std = @import("std");
const builtin = @import("builtin");
const compiler_api = @import("compiler.zig");

pub const ast = @import("ast.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const builtins = @import("builtins.zig");
pub const compiler = compiler_api;
pub const glsl_emitter = @import("glsl_emitter.zig");
pub const hm = @import("hm.zig");
pub const hir = @import("hir.zig");
pub const hir_builder = @import("hir_builder.zig");
pub const ir = @import("ir.zig");
pub const ir_builder = @import("ir_builder.zig");
pub const layout = @import("layout.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const sema = @import("sema.zig");
pub const mir = @import("mir.zig");
pub const mir_builder = @import("mir_builder.zig");
pub const string_pool = @import("string_pool.zig");
pub const token = @import("token.zig");
pub const typeclass = @import("typeclass.zig");
pub const types = @import("types.zig");
pub const unify = @import("unify.zig");
pub const wgsl_emitter = @import("wgsl_emitter.zig");

pub const ZwgslTarget = compiler_api.Target;
pub const ZwgslErrorKind = compiler_api.ErrorKind;
pub const ZwgslError = compiler_api.Error;
pub const ZwgslOptions = compiler_api.Options;
pub const ZwgslResult = compiler_api.Result;

const VERSION: [*:0]const u8 = "0.1.0";
const ffi_allocator = if (builtin.target.cpu.arch == .wasm32)
    std.heap.wasm_allocator
else
    std.heap.c_allocator;

const ResultStorage = struct {
    arena: std.heap.ArenaAllocator,
    errors: []compiler.Error = &.{},
    vertex_source: ?[:0]u8 = null,
    fragment_source: ?[:0]u8 = null,
    compute_source: ?[:0]u8 = null,
};

fn emptyResult() compiler.Result {
    return .{
        .vertex_source = null,
        .fragment_source = null,
        .compute_source = null,
        .errors = null,
        .error_count = 0,
        ._internal = null,
    };
}

pub export fn zwgsl_compile(source: [*]const u8, source_len: usize, options: compiler_api.Options) compiler_api.Result {
    var storage = ffi_allocator.create(ResultStorage) catch return emptyResult();
    storage.* = .{
        .arena = std.heap.ArenaAllocator.init(ffi_allocator),
    };
    errdefer {
        storage.arena.deinit();
        ffi_allocator.destroy(storage);
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
    if (output.compute_source) |compute| {
        storage.compute_source = arena.dupeZ(u8, compute) catch return emptyResult();
    }
    if (output.errors.len > 0) {
        storage.errors = arena.alloc(compiler.Error, output.errors.len) catch return emptyResult();
        @memcpy(storage.errors, output.errors);
    }

    return .{
        .vertex_source = if (storage.vertex_source) |value| value.ptr else null,
        .fragment_source = if (storage.fragment_source) |value| value.ptr else null,
        .compute_source = if (storage.compute_source) |value| value.ptr else null,
        .errors = if (storage.errors.len > 0) storage.errors.ptr else null,
        .error_count = @intCast(storage.errors.len),
        ._internal = storage,
    };
}

pub export fn zwgsl_free(result: *compiler_api.Result) void {
    const internal = result._internal orelse return;
    const storage: *ResultStorage = @ptrCast(@alignCast(internal));
    storage.arena.deinit();
    ffi_allocator.destroy(storage);
    result.* = emptyResult();
}

pub export fn zwgsl_version() [*:0]const u8 {
    return VERSION;
}

pub const WasmDiagnostic = extern struct {
    message_ptr: usize = 0,
    message_len: usize = 0,
    line: u32 = 0,
    column: u32 = 0,
    severity: u32 = 0,
};

pub const WasmCompileResult = extern struct {
    vertex_ptr: usize = 0,
    vertex_len: usize = 0,
    fragment_ptr: usize = 0,
    fragment_len: usize = 0,
    compute_ptr: usize = 0,
    compute_len: usize = 0,
    diagnostics_ptr: usize = 0,
    diagnostics_len: usize = 0,
};

const WasmResultStorage = struct {
    result: WasmCompileResult = .{},
    arena: std.heap.ArenaAllocator,
    diagnostics: []WasmDiagnostic = &.{},
};

pub export fn zwgsl_wasm_alloc(len: usize) usize {
    if (len == 0) return 0;
    const buffer = ffi_allocator.alloc(u8, len) catch return 0;
    return pointerToInt(buffer.ptr);
}

pub export fn zwgsl_wasm_free(ptr: usize, len: usize) void {
    if (ptr == 0 or len == 0) return;
    const buffer: [*]u8 = @ptrFromInt(ptr);
    ffi_allocator.free(buffer[0..len]);
}

pub export fn zwgsl_wasm_compile(source_ptr: usize, source_len: usize) usize {
    var storage = ffi_allocator.create(WasmResultStorage) catch return 0;
    storage.* = .{
        .arena = std.heap.ArenaAllocator.init(ffi_allocator),
    };
    errdefer {
        storage.arena.deinit();
        ffi_allocator.destroy(storage);
    }

    const arena = storage.arena.allocator();
    const source: []const u8 = if (source_len == 0)
        ""
    else
        @as([*]const u8, @ptrFromInt(source_ptr))[0..source_len];

    const output = compiler_api.compile(arena, source, .{ .target = .wgsl }) catch |err| {
        const message = arena.dupe(u8, @errorName(err)) catch return 0;
        storage.diagnostics = arena.alloc(WasmDiagnostic, 1) catch return 0;
        storage.diagnostics[0] = .{
            .message_ptr = slicePtrU32(message),
            .message_len = message.len,
            .severity = 1,
        };
        storage.result = .{
            .diagnostics_ptr = slicePtrU32(storage.diagnostics),
            .diagnostics_len = 1,
        };
        return pointerToInt(&storage.result);
    };

    if (output.errors.len > 0) {
        storage.diagnostics = arena.alloc(WasmDiagnostic, output.errors.len) catch return 0;
        for (output.errors, 0..) |diagnostic, index| {
            const message = std.mem.span(diagnostic.message);
            storage.diagnostics[index] = .{
                .message_ptr = slicePtrU32(message),
                .message_len = message.len,
                .line = diagnostic.line,
                .column = diagnostic.column,
                .severity = switch (diagnostic.kind) {
                    .ok => 0,
                    else => 1,
                },
            };
        }
    }

    storage.result = .{
        .vertex_ptr = optionalSlicePtrU32(output.vertex_source),
        .vertex_len = optionalSliceLen(output.vertex_source),
        .fragment_ptr = optionalSlicePtrU32(output.fragment_source),
        .fragment_len = optionalSliceLen(output.fragment_source),
        .compute_ptr = optionalSlicePtrU32(output.compute_source),
        .compute_len = optionalSliceLen(output.compute_source),
        .diagnostics_ptr = if (storage.diagnostics.len > 0) slicePtrU32(storage.diagnostics) else 0,
        .diagnostics_len = storage.diagnostics.len,
    };

    return pointerToInt(&storage.result);
}

pub export fn zwgsl_wasm_result_free(result_ptr: usize) void {
    if (result_ptr == 0) return;
    const result: *WasmCompileResult = @ptrFromInt(result_ptr);
    const storage: *WasmResultStorage = @alignCast(@fieldParentPtr("result", result));
    storage.arena.deinit();
    ffi_allocator.destroy(storage);
}

fn pointerToInt(ptr: anytype) usize {
    return @intFromPtr(ptr);
}

fn slicePtrU32(slice: anytype) usize {
    return pointerToInt(slice.ptr);
}

fn optionalSlicePtrU32(value: ?[]const u8) usize {
    return if (value) |slice| slicePtrU32(slice) else 0;
}

fn optionalSliceLen(value: ?[]const u8) usize {
    return if (value) |slice| slice.len else 0;
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
    try std.testing.expect(result.compute_source == null);
}

test "C API returns WGSL compute output" {
    const source =
        \\compute do
        \\  def main
        \\    id: UVec3 = global_invocation_id
        \\  end
        \\end
    ;

    var result = zwgsl_compile(source.ptr, source.len, .{ .target = .wgsl });
    defer zwgsl_free(&result);

    try std.testing.expectEqual(@as(u32, 0), result.error_count);
    try std.testing.expect(result.compute_source != null);
    try std.testing.expect(result.vertex_source == null);
    try std.testing.expect(result.fragment_source == null);
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
