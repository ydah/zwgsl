const std = @import("std");
const ast = @import("../ast.zig");
const core_diagnostics = @import("../diagnostics.zig");
const lexer = @import("../lexer.zig");
const parser = @import("../parser.zig");

const SymbolKind = enum(u8) {
    module = 2,
    interface = 11,
    function = 12,
    variable = 13,
    enum_type = 10,
    struct_type = 23,
};

pub fn response(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var diagnostic_list = core_diagnostics.DiagnosticList.init(arena_allocator);
    const tokens = lexer.Lexer.tokenizeResolved(arena_allocator, source) catch
        return try allocator.dupe(u8, "[]");
    var syntax_parser = parser.Parser.init(arena_allocator, source, tokens, &diagnostic_list);
    const program = syntax_parser.parseProgram() catch
        return try allocator.dupe(u8, "[]");

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);
    var first = true;

    try writer.writeByte('[');
    for (program.items) |item| {
        switch (item) {
            .uniform => |uniform| try writeSymbol(writer, &first, uniform.name, uniform.type_name, .variable, uniform.position),
            .struct_def => |struct_def| try writeSymbol(writer, &first, struct_def.name, "struct", .struct_type, struct_def.position),
            .type_def => |type_def| {
                try writeSymbol(writer, &first, type_def.name, "type", .enum_type, type_def.position);
                for (type_def.variants) |variant| {
                    try writeSymbol(writer, &first, variant.name, type_def.name, .enum_type, variant.position);
                }
            },
            .trait_def => |trait_def| try writeSymbol(writer, &first, trait_def.name, "trait", .interface, trait_def.position),
            .impl_def => |impl_def| {
                const name = try std.fmt.allocPrint(arena_allocator, "impl {s} for {s}", .{ impl_def.trait_name, impl_def.for_type_name });
                try writeSymbol(writer, &first, name, "impl", .interface, impl_def.position);
                for (impl_def.methods) |method| {
                    const method_name = try std.fmt.allocPrint(arena_allocator, "impl.{s}", .{method.name});
                    try writeSymbol(writer, &first, method_name, impl_def.trait_name, .function, method.position);
                }
            },
            .function => |function| try writeSymbol(writer, &first, function.name, "function", .function, function.position),
            .shader_block => |block| {
                const stage = stageName(block.stage);
                try writeSymbol(writer, &first, stage, "stage", .module, block.position);
                for (block.items) |stage_item| {
                    switch (stage_item) {
                        .input => |decl| try writeStageSymbol(arena_allocator, writer, &first, stage, "input", decl),
                        .output => |decl| try writeStageSymbol(arena_allocator, writer, &first, stage, "output", decl),
                        .varying => |decl| try writeStageSymbol(arena_allocator, writer, &first, stage, "varying", decl),
                        .function => |function| {
                            const name = try std.fmt.allocPrint(arena_allocator, "{s}.{s}", .{ stage, function.name });
                            try writeSymbol(writer, &first, name, "function", .function, function.position);
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    try writer.writeByte(']');

    return try buffer.toOwnedSlice(allocator);
}

fn writeStageSymbol(
    allocator: std.mem.Allocator,
    writer: anytype,
    first: *bool,
    stage: []const u8,
    role: []const u8,
    decl: ast.IoDecl,
) !void {
    const name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ stage, decl.name });
    try writeSymbol(writer, first, name, role, .variable, decl.position);
}

fn writeSymbol(
    writer: anytype,
    first: *bool,
    name: []const u8,
    detail: []const u8,
    kind: SymbolKind,
    position: ast.Position,
) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;

    const line = if (position.line > 0) position.line - 1 else 0;
    const character = if (position.column > 0) position.column - 1 else 0;
    const end_character = character + @as(u32, @intCast(@max(name.len, @as(usize, 1))));

    try writer.writeAll("{\"name\":");
    try writeJsonString(writer, name);
    try writer.writeAll(",\"detail\":");
    try writeJsonString(writer, detail);
    try writer.print(
        ",\"kind\":{d},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}",
        .{
            @intFromEnum(kind),
            line,
            character,
            line,
            end_character,
            line,
            character,
            line,
            end_character,
        },
    );
}

fn stageName(stage: ast.Stage) []const u8 {
    return switch (stage) {
        .vertex => "vertex",
        .fragment => "fragment",
        .compute => "compute",
    };
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| switch (ch) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(ch),
    };
    try writer.writeByte('"');
}
