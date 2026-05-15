const std = @import("std");
const analysis = @import("analysis.zig");
const token = @import("../token.zig");

const CallContext = struct {
    name: []const u8,
    active_parameter: u32,
    is_method: bool,
};

const Signature = struct {
    label: []const u8,
    documentation: []const u8 = "",
};

const Frame = struct {
    paren_index: usize,
    active_parameter: u32 = 0,
};

pub fn response(allocator: std.mem.Allocator, source: []const u8, line: u32, character: u32) ![]u8 {
    var document = try analysis.Document.init(allocator, source);
    defer document.deinit();

    const context = callContextAt(&document, line, character) orelse return try allocator.dupe(u8, "null");
    const signature = signatureFor(&document, context.name, line, character) orelse return try allocator.dupe(u8, "null");
    const params = try parameterLabels(allocator, signature.label);
    defer allocator.free(params);

    const active_parameter = activeParameter(context, params.len);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.writeAll("{\"signatures\":[{\"label\":");
    try writeJsonString(writer, signature.label);
    if (signature.documentation.len > 0) {
        try writer.writeAll(",\"documentation\":{\"kind\":\"markdown\",\"value\":");
        try writeJsonString(writer, signature.documentation);
        try writer.writeByte('}');
    }
    try writer.writeAll(",\"parameters\":[");
    for (params, 0..) |param, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"label\":");
        try writeJsonString(writer, param);
        try writer.writeByte('}');
    }
    try writer.print("]}}],\"activeSignature\":0,\"activeParameter\":{d}}}", .{active_parameter});
    return try buffer.toOwnedSlice(allocator);
}

fn callContextAt(document: *const analysis.Document, line: u32, character: u32) ?CallContext {
    var frames: [64]Frame = undefined;
    var depth: usize = 0;

    for (document.tokens, 0..) |tok, index| {
        if (!tokenStartsBefore(tok, line, character)) break;
        switch (tok.tag) {
            .lparen => {
                if (depth == frames.len) return null;
                frames[depth] = .{ .paren_index = index };
                depth += 1;
            },
            .rparen => if (depth > 0) {
                depth -= 1;
            },
            .comma => if (depth > 0) {
                frames[depth - 1].active_parameter += 1;
            },
            else => {},
        }
    }

    while (depth > 0) {
        depth -= 1;
        const frame = frames[depth];
        if (callNameBeforeParen(document, frame.paren_index)) |call| {
            return .{
                .name = call.name,
                .active_parameter = frame.active_parameter,
                .is_method = call.is_method,
            };
        }
    }
    return null;
}

fn tokenStartsBefore(tok: token.Token, line: u32, character: u32) bool {
    if (tok.line == 0) return false;
    const token_line = tok.line - 1;
    if (token_line < line) return true;
    if (token_line > line) return false;
    const column = if (tok.column > 0) tok.column - 1 else 0;
    return column < character;
}

fn callNameBeforeParen(document: *const analysis.Document, paren_index: usize) ?struct {
    name: []const u8,
    is_method: bool,
} {
    const name_token = document.previousSignificantToken(paren_index) orelse return null;
    if (name_token.tok.tag != .identifier) return null;

    const is_method = if (document.previousSignificantToken(name_token.index)) |previous|
        previous.tok.tag == .dot
    else
        false;

    return .{
        .name = document.lexeme(name_token.tok),
        .is_method = is_method,
    };
}

fn signatureFor(document: *const analysis.Document, name: []const u8, line: u32, character: u32) ?Signature {
    if (document.resolveDefinition(name, line, character)) |definition| {
        switch (definition.kind) {
            .function, .builtin, .constructor => return .{
                .label = definition.detail,
                .documentation = definition.documentation orelse "",
            },
            .variable, .uniform, .input, .output, .varying, .parameter, .type_name, .trait => {},
        }
    }
    return staticSignature(name);
}

fn staticSignature(name: []const u8) ?Signature {
    for (staticSignatures()) |item| {
        if (std.mem.eql(u8, item.label_name, name)) {
            return .{ .label = item.label, .documentation = item.documentation };
        }
    }
    return null;
}

fn activeParameter(context: CallContext, param_count: usize) u32 {
    if (param_count == 0) return 0;
    var active = context.active_parameter;
    if (context.is_method and param_count > 1) active += 1;
    const max_param: u32 = @intCast(param_count - 1);
    return @min(active, max_param);
}

fn parameterLabels(allocator: std.mem.Allocator, label: []const u8) ![]const []const u8 {
    const open_index = std.mem.indexOfScalar(u8, label, '(') orelse return try allocator.alloc([]const u8, 0);
    var params: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer params.deinit(allocator);

    var start = open_index + 1;
    var depth: usize = 0;
    var index = start;
    while (index < label.len) : (index += 1) {
        switch (label[index]) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) {
                    try appendParameter(allocator, &params, label[start..index]);
                    return try params.toOwnedSlice(allocator);
                }
                depth -= 1;
            },
            ',' => if (depth == 0) {
                try appendParameter(allocator, &params, label[start..index]);
                start = index + 1;
            },
            else => {},
        }
    }

    return try params.toOwnedSlice(allocator);
}

fn appendParameter(
    allocator: std.mem.Allocator,
    params: *std.ArrayListUnmanaged([]const u8),
    value: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return;
    try params.append(allocator, trimmed);
}

const StaticSignature = struct {
    label_name: []const u8,
    label: []const u8,
    documentation: []const u8 = "",
};

fn staticSignatures() []const StaticSignature {
    return &.{
        .{ .label_name = "vec2", .label = "fn vec2(x: Float, y: Float) -> Vec2", .documentation = "Constructs a floating-point 2D vector." },
        .{ .label_name = "vec3", .label = "fn vec3(x: Float, y: Float, z: Float) -> Vec3", .documentation = "Constructs a floating-point 3D vector." },
        .{ .label_name = "vec4", .label = "fn vec4(x: Float, y: Float, z: Float, w: Float) -> Vec4", .documentation = "Constructs a floating-point 4D vector." },
        .{ .label_name = "ivec2", .label = "fn ivec2(x: Int, y: Int) -> IVec2" },
        .{ .label_name = "ivec3", .label = "fn ivec3(x: Int, y: Int, z: Int) -> IVec3" },
        .{ .label_name = "ivec4", .label = "fn ivec4(x: Int, y: Int, z: Int, w: Int) -> IVec4" },
        .{ .label_name = "uvec2", .label = "fn uvec2(x: UInt, y: UInt) -> UVec2" },
        .{ .label_name = "uvec3", .label = "fn uvec3(x: UInt, y: UInt, z: UInt) -> UVec3" },
        .{ .label_name = "uvec4", .label = "fn uvec4(x: UInt, y: UInt, z: UInt, w: UInt) -> UVec4" },
        .{ .label_name = "bvec2", .label = "fn bvec2(x: Bool, y: Bool) -> BVec2" },
        .{ .label_name = "bvec3", .label = "fn bvec3(x: Bool, y: Bool, z: Bool) -> BVec3" },
        .{ .label_name = "bvec4", .label = "fn bvec4(x: Bool, y: Bool, z: Bool, w: Bool) -> BVec4" },
        .{ .label_name = "mat2", .label = "fn mat2(value: Float) -> Mat2" },
        .{ .label_name = "mat3", .label = "fn mat3(value: Float | Mat4) -> Mat3" },
        .{ .label_name = "mat4", .label = "fn mat4(value: Float) -> Mat4" },
        .{ .label_name = "distance", .label = "fn distance(a: Vec(N) | Sca, b: Vec(N) | Sca) -> Float" },
        .{ .label_name = "refract", .label = "fn refract(i: Vec(N), n: Vec(N), eta: Float) -> Vec(N)" },
        .{ .label_name = "clamp", .label = "fn clamp(x: T, min: T | Sca, max: T | Sca) -> T" },
        .{ .label_name = "min", .label = "fn min(a: T, b: T | Sca) -> T" },
        .{ .label_name = "max", .label = "fn max(a: T, b: T | Sca) -> T" },
        .{ .label_name = "pow", .label = "fn pow(x: T, y: T | Sca) -> T" },
        .{ .label_name = "step", .label = "fn step(edge: T | Sca, x: T) -> T" },
        .{ .label_name = "smoothstep", .label = "fn smoothstep(edge0: T | Sca, edge1: T | Sca, x: T) -> T" },
        .{ .label_name = "mod", .label = "fn mod(x: T, y: T | Sca) -> T" },
        .{ .label_name = "atan", .label = "fn atan(y: T, x: T) -> T" },
        .{ .label_name = "abs", .label = "fn abs(x: T) -> T" },
        .{ .label_name = "sign", .label = "fn sign(x: T) -> T" },
        .{ .label_name = "floor", .label = "fn floor(x: T) -> T" },
        .{ .label_name = "ceil", .label = "fn ceil(x: T) -> T" },
        .{ .label_name = "fract", .label = "fn fract(x: T) -> T" },
        .{ .label_name = "sqrt", .label = "fn sqrt(x: T) -> T" },
        .{ .label_name = "exp", .label = "fn exp(x: T) -> T" },
        .{ .label_name = "log", .label = "fn log(x: T) -> T" },
        .{ .label_name = "sin", .label = "fn sin(x: T) -> T" },
        .{ .label_name = "cos", .label = "fn cos(x: T) -> T" },
        .{ .label_name = "tan", .label = "fn tan(x: T) -> T" },
        .{ .label_name = "asin", .label = "fn asin(x: T) -> T" },
        .{ .label_name = "acos", .label = "fn acos(x: T) -> T" },
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
