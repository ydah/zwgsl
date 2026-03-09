const std = @import("std");
const ir = @import("ir.zig");
const token = @import("token.zig");

pub const EmitOptions = struct {
    emit_debug_comments: bool = false,
};

pub const Output = struct {
    vertex: ?[]const u8 = null,
    fragment: ?[]const u8 = null,
};

pub fn emit(allocator: std.mem.Allocator, module: *const ir.Module, options: EmitOptions) anyerror!Output {
    _ = options;
    return .{
        .vertex = if (module.vertex) |stage| try emitStage(allocator, module, stage) else null,
        .fragment = if (module.fragment) |stage| try emitStage(allocator, module, stage) else null,
    };
}

fn emitStage(allocator: std.mem.Allocator, module: *const ir.Module, stage: ir.Stage) anyerror![]const u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
    const writer = buffer.writer(allocator);

    try writer.print("#version {s}\n", .{module.version});
    if (stage.stage == .fragment) {
        if (stage.precision) |precision| {
            try writer.print("precision {s} float;\n", .{precision});
        }
    }
    try writer.writeByte('\n');

    for (module.uniforms) |uniform| {
        try writer.print("uniform {s} {s};\n", .{ uniform.ty.glslName(), uniform.name });
    }
    if (module.uniforms.len > 0) try writer.writeByte('\n');

    for (stage.inputs) |input| {
        if (input.location) |location| {
            try writer.print("layout(location = {d}) in {s} {s};\n", .{ location, input.ty.glslName(), input.name });
        } else {
            try writer.print("in {s} {s};\n", .{ input.ty.glslName(), input.name });
        }
    }
    if (stage.inputs.len > 0) try writer.writeByte('\n');

    for (stage.varyings) |varying| {
        const qualifier = if (stage.stage == .vertex) "out" else "in";
        try writer.print("{s} {s} {s};\n", .{ qualifier, varying.ty.glslName(), varying.name });
    }
    if (stage.varyings.len > 0) try writer.writeByte('\n');

    for (stage.outputs) |output| {
        if (output.location) |location| {
            try writer.print("layout(location = {d}) out {s} {s};\n", .{ location, output.ty.glslName(), output.name });
        } else {
            try writer.print("out {s} {s};\n", .{ output.ty.glslName(), output.name });
        }
    }
    if (stage.outputs.len > 0) try writer.writeByte('\n');

    for (module.structs) |struct_decl| {
        try writer.print("struct {s} {{\n", .{struct_decl.name});
        for (struct_decl.fields) |field| {
            try writer.print("    {s} {s};\n", .{ field.ty.glslName(), field.name });
        }
        try writer.writeAll("};\n\n");
    }

    for (module.global_functions) |function| {
        try emitFunction(writer, function);
        try writer.writeByte('\n');
    }

    for (stage.functions) |function| {
        if (std.mem.eql(u8, function.name, "main")) continue;
        try emitFunction(writer, function);
        try writer.writeByte('\n');
    }

    for (stage.functions) |function| {
        if (!std.mem.eql(u8, function.name, "main")) continue;
        try emitFunction(writer, function);
        break;
    }

    return try buffer.toOwnedSlice(allocator);
}

fn emitFunction(writer: anytype, function: ir.Function) anyerror!void {
    try writer.print("{s} {s}(", .{ function.return_type.glslName(), function.name });
    for (function.params, 0..) |param, index| {
        if (index > 0) try writer.writeAll(", ");
        if (param.is_inout) {
            try writer.print("inout {s} {s}", .{ param.ty.glslName(), param.name });
        } else {
            try writer.print("{s} {s}", .{ param.ty.glslName(), param.name });
        }
    }
    try writer.writeAll(") {\n");
    try emitStatements(writer, function.body, 1);
    try writer.writeAll("}\n");
}

fn emitStatements(writer: anytype, statements: []const ir.Statement, indent: usize) anyerror!void {
    for (statements) |statement| {
        try writeIndent(writer, indent);
        switch (statement) {
            .var_decl => |decl| {
                try writer.print("{s} {s}", .{ decl.ty.glslName(), decl.name });
                if (decl.value) |value| {
                    try writer.writeAll(" = ");
                    try emitExpr(writer, value, 0);
                }
                try writer.writeAll(";\n");
            },
            .assign => |assignment| {
                try emitExpr(writer, assignment.target, 0);
                try writer.print(" {s} ", .{assignmentOp(assignment.operator)});
                try emitExpr(writer, assignment.value, 0);
                try writer.writeAll(";\n");
            },
            .expr => |expr| {
                try emitExpr(writer, expr, 0);
                try writer.writeAll(";\n");
            },
            .return_stmt => |value| {
                if (value) |expr| {
                    try writer.writeAll("return ");
                    try emitExpr(writer, expr, 0);
                    try writer.writeAll(";\n");
                } else {
                    try writer.writeAll("return;\n");
                }
            },
            .discard => try writer.writeAll("discard;\n"),
            .if_stmt => |if_stmt| {
                try writer.writeAll("if (");
                try emitExpr(writer, if_stmt.condition, 0);
                try writer.writeAll(") {\n");
                try emitStatements(writer, if_stmt.then_body, indent + 1);
                try writeIndent(writer, indent);
                try writer.writeAll("}");
                if (if_stmt.else_body.len > 0) {
                    try writer.writeAll(" else {\n");
                    try emitStatements(writer, if_stmt.else_body, indent + 1);
                    try writeIndent(writer, indent);
                    try writer.writeAll("}");
                }
                try writer.writeByte('\n');
            },
        }
    }
}

fn emitExpr(writer: anytype, expr: *const ir.Expr, parent_precedence: u8) anyerror!void {
    const precedence = exprPrecedence(expr);
    const wrap = precedence < parent_precedence;
    if (wrap) try writer.writeByte('(');

    switch (expr.data) {
        .integer => |value| try writer.print("{d}", .{value}),
        .float => |value| try writeFloat(writer, value),
        .bool => |value| try writer.writeAll(if (value) "true" else "false"),
        .identifier => |name| try writer.writeAll(name),
        .unary => |unary| {
            try writer.print("{s}", .{unaryOp(unary.operator)});
            try emitExpr(writer, unary.operand, precedence);
        },
        .binary => |binary| {
            try emitExpr(writer, binary.lhs, precedence);
            try writer.print(" {s} ", .{binaryOp(binary.operator)});
            try emitExpr(writer, binary.rhs, precedence + 1);
        },
        .call => |call| {
            try writer.print("{s}(", .{call.name});
            for (call.args, 0..) |arg, index| {
                if (index > 0) try writer.writeAll(", ");
                try emitExpr(writer, arg, 0);
            }
            try writer.writeByte(')');
        },
        .field => |field| {
            try emitExpr(writer, field.target, precedence);
            try writer.print(".{s}", .{field.name});
        },
        .index => |index_expr| {
            try emitExpr(writer, index_expr.target, precedence);
            try writer.writeByte('[');
            try emitExpr(writer, index_expr.index, 0);
            try writer.writeByte(']');
        },
    }

    if (wrap) try writer.writeByte(')');
}

fn exprPrecedence(expr: *const ir.Expr) u8 {
    return switch (expr.data) {
        .integer, .float, .bool, .identifier => 9,
        .call, .field, .index => 8,
        .unary => 7,
        .binary => |binary| switch (binary.operator) {
            .star, .slash, .percent => 6,
            .plus, .minus => 5,
            .lt, .gt, .le, .ge => 4,
            .eq, .neq => 3,
            .and_and => 2,
            .or_or => 1,
            else => 0,
        },
    };
}

fn writeFloat(writer: anytype, value: f64) anyerror!void {
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    if (std.mem.indexOfAny(u8, text, ".eE") == null) {
        try writer.print("{s}.0", .{text});
    } else {
        try writer.writeAll(text);
    }
}

fn writeIndent(writer: anytype, indent: usize) anyerror!void {
    for (0..indent) |_| {
        try writer.writeAll("    ");
    }
}

fn assignmentOp(tag: token.TokenTag) []const u8 {
    return switch (tag) {
        .assign => "=",
        .plus_assign => "+=",
        .minus_assign => "-=",
        .star_assign => "*=",
        .slash_assign => "/=",
        else => "=",
    };
}

fn binaryOp(tag: token.TokenTag) []const u8 {
    return switch (tag) {
        .plus => "+",
        .minus => "-",
        .star => "*",
        .slash => "/",
        .percent => "%",
        .eq => "==",
        .neq => "!=",
        .lt => "<",
        .gt => ">",
        .le => "<=",
        .ge => ">=",
        .and_and => "&&",
        .or_or => "||",
        else => "",
    };
}

fn unaryOp(tag: token.TokenTag) []const u8 {
    return switch (tag) {
        .minus => "-",
        .bang => "!",
        else => "",
    };
}
