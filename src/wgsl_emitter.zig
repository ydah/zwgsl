const std = @import("std");
const ast = @import("ast.zig");
const glsl_emitter = @import("glsl_emitter.zig");
const ir = @import("ir.zig");
const token = @import("token.zig");
const types = @import("types.zig");

pub const EmitOptions = struct {
    emit_debug_comments: bool = false,
    optimize_output: bool = false,
    source: ?[]const u8 = null,
};

pub const Output = glsl_emitter.Output;

pub const EmitError = error{
    UnsupportedInOutParams,
    UnsupportedSamplerType,
    UnsupportedTextureBuiltin,
    UnsupportedTextureSource,
};

pub fn emit(allocator: std.mem.Allocator, module: *const ir.Module, options: EmitOptions) anyerror!Output {
    return .{
        .vertex = if (module.vertex) |stage| try emitStage(allocator, module, stage, options) else null,
        .fragment = if (module.fragment) |stage| try emitStage(allocator, module, stage, options) else null,
        .compute = if (module.compute) |stage| try emitStage(allocator, module, stage, options) else null,
    };
}

fn emitStage(allocator: std.mem.Allocator, module: *const ir.Module, stage: ir.Stage, options: EmitOptions) anyerror![]const u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
    const writer = buffer.writer(allocator);

    if (stage.stage != .compute) {
        try emitStageInterfaceStructs(writer, module, stage);
    }
    try emitUniforms(writer, module.uniforms);
    try emitPrivateGlobals(writer, stage);

    for (module.structs) |struct_decl| {
        try emitUserStruct(writer, struct_decl);
        try writer.writeByte('\n');
    }

    for (module.global_functions) |function| {
        try emitFunction(writer, function, options, null, module.uniforms);
        try writer.writeByte('\n');
    }

    for (stage.functions) |function| {
        try emitFunction(writer, function, options, stage.stage, module.uniforms);
        try writer.writeByte('\n');
    }

    try emitEntryPoint(writer, module, stage);

    const output = try buffer.toOwnedSlice(allocator);
    if (!options.optimize_output) return output;
    return compactOutput(allocator, output);
}

fn emitStageInterfaceStructs(writer: anytype, module: *const ir.Module, stage: ir.Stage) !void {
    switch (stage.stage) {
        .vertex => {
            if (stage.inputs.len > 0) {
                try writer.writeAll("struct VertexInput {\n");
                for (stage.inputs, 0..) |input, index| {
                    try writer.print("    @location({d}) {s}: {s},\n", .{ declLocation(input, index), input.name, input.ty.wgslName() });
                }
                try writer.writeAll("};\n\n");
            }

            try writer.writeAll("struct VertexOutput {\n");
            try writer.writeAll("    @builtin(position) gl_Position: vec4f,\n");
            for (stage.varyings) |varying| {
                try writer.print("    @location({d}) {s}: {s},\n", .{ varyingLocation(module, varying.name), varying.name, varying.ty.wgslName() });
            }
            for (stage.outputs, 0..) |output, index| {
                try writer.print("    @location({d}) {s}: {s},\n", .{ declLocation(output, index), output.name, output.ty.wgslName() });
            }
            try writer.writeAll("};\n\n");
        },
        .fragment => {
            if (stage.varyings.len > 0) {
                try writer.writeAll("struct FragmentInput {\n");
                for (stage.varyings) |varying| {
                    try writer.print("    @location({d}) {s}: {s},\n", .{ varyingLocation(module, varying.name), varying.name, varying.ty.wgslName() });
                }
                try writer.writeAll("};\n\n");
            }

            if (stage.outputs.len > 0) {
                try writer.writeAll("struct FragmentOutput {\n");
                for (stage.outputs, 0..) |output, index| {
                    try writer.print("    @location({d}) {s}: {s},\n", .{ declLocation(output, index), output.name, output.ty.wgslName() });
                }
                try writer.writeAll("};\n\n");
            }
        },
        .compute => {},
    }
}

fn emitUniforms(writer: anytype, uniforms: []const ir.Global) !void {
    var binding_index: u32 = 0;
    for (uniforms) |uniform| {
        if (uniform.ty.isSampler()) {
            try writer.print("@group(0) @binding({d}) var {s}_texture: {s};\n", .{
                binding_index,
                uniform.name,
                samplerTextureType(uniform.ty) orelse return error.UnsupportedSamplerType,
            });
            try writer.print("@group(0) @binding({d}) var {s}_sampler: sampler;\n", .{
                binding_index + 1,
                uniform.name,
            });
            binding_index += 2;
            continue;
        }

        try writer.print("@group(0) @binding({d}) var<uniform> {s}: {s};\n", .{
            binding_index,
            uniform.name,
            uniform.ty.wgslName(),
        });
        binding_index += 1;
    }
    if (uniforms.len > 0) try writer.writeByte('\n');
}

fn emitPrivateGlobals(writer: anytype, stage: ir.Stage) !void {
    switch (stage.stage) {
        .vertex => {
            try writer.writeAll("var<private> gl_Position: vec4f;\n");
            for (stage.inputs) |input| {
                try writer.print("var<private> {s}: {s};\n", .{ input.name, input.ty.wgslName() });
            }
            for (stage.varyings) |varying| {
                try writer.print("var<private> {s}: {s};\n", .{ varying.name, varying.ty.wgslName() });
            }
            for (stage.outputs) |output| {
                try writer.print("var<private> {s}: {s};\n", .{ output.name, output.ty.wgslName() });
            }
            if (stage.inputs.len > 0 or stage.varyings.len > 0 or stage.outputs.len > 0) try writer.writeByte('\n');
        },
        .fragment => {
            for (stage.varyings) |varying| {
                try writer.print("var<private> {s}: {s};\n", .{ varying.name, varying.ty.wgslName() });
            }
            for (stage.outputs) |output| {
                try writer.print("var<private> {s}: {s};\n", .{ output.name, output.ty.wgslName() });
            }
            if (stage.varyings.len > 0 or stage.outputs.len > 0) try writer.writeByte('\n');
        },
        .compute => {
            try writer.writeAll("var<private> global_invocation_id: vec3u;\n");
            try writer.writeAll("var<private> local_invocation_id: vec3u;\n");
            try writer.writeAll("var<private> workgroup_id: vec3u;\n");
            try writer.writeAll("var<private> num_workgroups: vec3u;\n");
            try writer.writeAll("var<private> local_invocation_index: u32;\n\n");
        },
    }
}

fn emitUserStruct(writer: anytype, struct_decl: ir.StructDecl) !void {
    try writer.print("struct {s} {{\n", .{struct_decl.name});
    for (struct_decl.fields) |field| {
        try writer.print("    {s}: {s},\n", .{ field.name, field.ty.wgslName() });
    }
    try writer.writeAll("};\n");
}

fn emitFunction(writer: anytype, function: ir.Function, options: EmitOptions, stage: ?ast.Stage, uniforms: []const ir.Global) anyerror!void {
    for (function.params) |param| {
        if (param.is_inout) return error.UnsupportedInOutParams;
    }

    try emitDebugComment(writer, options, function.source_line, 0);

    const name = if (stage != null and function.isMain()) internalMainName(stage.?) else function.name;
    try writer.print("fn {s}(", .{name});
    for (function.params, 0..) |param, index| {
        if (index > 0) try writer.writeAll(", ");
        try writer.print("{s}: {s}", .{ param.name, param.ty.wgslName() });
    }
    try writer.writeByte(')');
    if (!function.return_type.isVoid()) {
        try writer.print(" -> {s}", .{function.return_type.wgslName()});
    }
    try writer.writeAll(" {\n");
    try emitStatements(writer, function.body, 1, options, uniforms);
    try writer.writeAll("}\n");
}

fn emitEntryPoint(writer: anytype, module: *const ir.Module, stage: ir.Stage) !void {
    switch (stage.stage) {
        .vertex => {
            try writer.writeAll("@vertex\n");
            if (stage.inputs.len > 0) {
                try writer.writeAll("fn main(input: VertexInput) -> VertexOutput {\n");
                for (stage.inputs) |input| {
                    try writer.print("    {s} = input.{s};\n", .{ input.name, input.name });
                }
            } else {
                try writer.writeAll("fn main() -> VertexOutput {\n");
            }
            try writer.print("    {s}();\n", .{internalMainName(.vertex)});
            try writer.writeAll("    var output: VertexOutput;\n");
            try writer.writeAll("    output.gl_Position = gl_Position;\n");
            for (stage.varyings) |varying| {
                try writer.print("    output.{s} = {s};\n", .{ varying.name, varying.name });
            }
            for (stage.outputs) |output| {
                try writer.print("    output.{s} = {s};\n", .{ output.name, output.name });
            }
            try writer.writeAll("    return output;\n");
            try writer.writeAll("}\n");
        },
        .fragment => {
            try writer.writeAll("@fragment\n");
            if (stage.varyings.len > 0) {
                try writer.writeAll("fn main(input: FragmentInput)");
            } else {
                try writer.writeAll("fn main()");
            }
            if (stage.outputs.len > 0) {
                try writer.writeAll(" -> FragmentOutput");
            }
            try writer.writeAll(" {\n");
            for (stage.varyings) |varying| {
                try writer.print("    {s} = input.{s};\n", .{ varying.name, varying.name });
            }
            try writer.print("    {s}();\n", .{internalMainName(.fragment)});
            if (stage.outputs.len > 0) {
                try writer.writeAll("    var output: FragmentOutput;\n");
                for (stage.outputs) |output| {
                    try writer.print("    output.{s} = {s};\n", .{ output.name, output.name });
                }
                try writer.writeAll("    return output;\n");
            }
            try writer.writeAll("}\n");
        },
        .compute => {
            _ = module;
            try writer.writeAll("@compute @workgroup_size(1)\n");
            try writer.writeAll("fn main(\n");
            try writer.writeAll("    @builtin(global_invocation_id) global_invocation_id_input: vec3u,\n");
            try writer.writeAll("    @builtin(local_invocation_id) local_invocation_id_input: vec3u,\n");
            try writer.writeAll("    @builtin(workgroup_id) workgroup_id_input: vec3u,\n");
            try writer.writeAll("    @builtin(num_workgroups) num_workgroups_input: vec3u,\n");
            try writer.writeAll("    @builtin(local_invocation_index) local_invocation_index_input: u32,\n");
            try writer.writeAll(") {\n");
            try writer.writeAll("    global_invocation_id = global_invocation_id_input;\n");
            try writer.writeAll("    local_invocation_id = local_invocation_id_input;\n");
            try writer.writeAll("    workgroup_id = workgroup_id_input;\n");
            try writer.writeAll("    num_workgroups = num_workgroups_input;\n");
            try writer.writeAll("    local_invocation_index = local_invocation_index_input;\n");
            try writer.print("    {s}();\n", .{internalMainName(.compute)});
            try writer.writeAll("}\n");
        },
    }
}

fn emitStatements(writer: anytype, statements: []const ir.Statement, indent: usize, options: EmitOptions, uniforms: []const ir.Global) anyerror!void {
    for (statements) |statement| {
        try emitDebugComment(writer, options, statement.source_line, indent);
        try writeIndent(writer, indent);
        switch (statement.data) {
            .var_decl => |decl| {
                try writer.print("{s} {s}: {s}", .{
                    if (decl.mutable) "var" else "let",
                    decl.name,
                    decl.ty.wgslName(),
                });
                if (decl.value) |value| {
                    try writer.writeAll(" = ");
                    try emitExpr(writer, value, 0, uniforms);
                }
                try writer.writeAll(";\n");
            },
            .assign => |assignment| {
                try emitExpr(writer, assignment.target, 0, uniforms);
                try writer.print(" {s} ", .{assignmentOp(assignment.operator)});
                try emitExpr(writer, assignment.value, 0, uniforms);
                try writer.writeAll(";\n");
            },
            .expr => |expr| {
                try emitExpr(writer, expr, 0, uniforms);
                try writer.writeAll(";\n");
            },
            .return_stmt => |value| {
                if (value) |expr| {
                    try writer.writeAll("return ");
                    try emitExpr(writer, expr, 0, uniforms);
                    try writer.writeAll(";\n");
                } else {
                    try writer.writeAll("return;\n");
                }
            },
            .discard => try writer.writeAll("discard;\n"),
            .if_stmt => |if_stmt| {
                try writer.writeAll("if (");
                try emitExpr(writer, if_stmt.condition, 0, uniforms);
                try writer.writeAll(") {\n");
                try emitStatements(writer, if_stmt.then_body, indent + 1, options, uniforms);
                try writeIndent(writer, indent);
                try writer.writeAll("}");
                if (if_stmt.else_body.len > 0) {
                    try writer.writeAll(" else {\n");
                    try emitStatements(writer, if_stmt.else_body, indent + 1, options, uniforms);
                    try writeIndent(writer, indent);
                    try writer.writeAll("}");
                }
                try writer.writeByte('\n');
            },
        }
    }
}

fn emitExpr(writer: anytype, expr: *const ir.Expr, parent_precedence: u8, uniforms: []const ir.Global) anyerror!void {
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
            try emitExpr(writer, unary.operand, precedence, uniforms);
        },
        .binary => |binary| {
            try emitExpr(writer, binary.lhs, precedence, uniforms);
            try writer.print(" {s} ", .{binaryOp(binary.operator)});
            try emitExpr(writer, binary.rhs, precedence + 1, uniforms);
        },
        .call => |call| {
            if (std.mem.eql(u8, call.name, "texture")) {
                try emitTextureCall(writer, call, uniforms);
                if (wrap) try writer.writeByte(')');
                return;
            }

            try writer.print("{s}(", .{callName(call.name, expr.ty)});
            for (call.args, 0..) |arg, index| {
                if (index > 0) try writer.writeAll(", ");
                try emitExpr(writer, arg, 0, uniforms);
            }
            try writer.writeByte(')');
        },
        .field => |field| {
            try emitExpr(writer, field.target, precedence, uniforms);
            try writer.print(".{s}", .{field.name});
        },
        .index => |index_expr| {
            try emitExpr(writer, index_expr.target, precedence, uniforms);
            try writer.writeByte('[');
            try emitExpr(writer, index_expr.index, 0, uniforms);
            try writer.writeByte(']');
        },
    }

    if (wrap) try writer.writeByte(')');
}

fn emitTextureCall(writer: anytype, call: ir.Expr.Call, uniforms: []const ir.Global) anyerror!void {
    if (call.args.len != 2) return error.UnsupportedTextureBuiltin;
    const sampler_name = switch (call.args[0].data) {
        .identifier => |name| name,
        else => return error.UnsupportedTextureSource,
    };

    const uniform = findUniform(uniforms, sampler_name) orelse return error.UnsupportedTextureSource;
    if (!uniform.ty.isSampler()) return error.UnsupportedTextureBuiltin;

    try writer.print("textureSample({s}_texture, {s}_sampler, ", .{ sampler_name, sampler_name });
    try emitExpr(writer, call.args[1], 0, uniforms);
    try writer.writeByte(')');
}

fn findUniform(uniforms: []const ir.Global, name: []const u8) ?ir.Global {
    for (uniforms) |uniform| {
        if (std.mem.eql(u8, uniform.name, name)) return uniform;
    }
    return null;
}

fn samplerTextureType(ty: types.Type) ?[]const u8 {
    return switch (ty) {
        .builtin => |builtin| switch (builtin) {
            .sampler2d => "texture_2d<f32>",
            .sampler_cube => "texture_cube<f32>",
            .sampler3d => "texture_3d<f32>",
            else => null,
        },
        else => null,
    };
}

fn varyingLocation(module: *const ir.Module, name: []const u8) u32 {
    if (module.vertex) |stage| {
        for (stage.varyings, 0..) |varying, index| {
            if (std.mem.eql(u8, varying.name, name)) return @intCast(index);
        }
    }
    if (module.fragment) |stage| {
        for (stage.varyings, 0..) |varying, index| {
            if (std.mem.eql(u8, varying.name, name)) return @intCast(index);
        }
    }
    return 0;
}

fn declLocation(decl: ir.Global, index: usize) u32 {
    return decl.location orelse @intCast(index);
}

fn internalMainName(stage: ast.Stage) []const u8 {
    return switch (stage) {
        .vertex => "__zwgsl_vertex_main",
        .fragment => "__zwgsl_fragment_main",
        .compute => "__zwgsl_compute_main",
    };
}

fn callName(name: []const u8, ty: types.Type) []const u8 {
    if (types.fromConstructorName(name) != null) {
        return switch (ty) {
            .builtin => |builtin| switch (builtin) {
                .float => "f32",
                .int => "i32",
                .uint => "u32",
                .bool => "bool",
                .vec2 => "vec2f",
                .vec3 => "vec3f",
                .vec4 => "vec4f",
                .ivec2 => "vec2i",
                .ivec3 => "vec3i",
                .ivec4 => "vec4i",
                .uvec2 => "vec2u",
                .uvec3 => "vec3u",
                .uvec4 => "vec4u",
                .bvec2 => "vec2<bool>",
                .bvec3 => "vec3<bool>",
                .bvec4 => "vec4<bool>",
                .mat2 => "mat2x2f",
                .mat3 => "mat3x3f",
                .mat4 => "mat4x4f",
                else => name,
            },
            .struct_type => |struct_name| struct_name,
            .function, .type_var, .nat => name,
            .type_app => ty.wgslName(),
        };
    }
    return name;
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

fn writeFloat(writer: anytype, value: f64) !void {
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    if (std.mem.indexOfAny(u8, text, ".eE") == null) {
        try writer.print("{s}.0", .{text});
    } else {
        try writer.writeAll(text);
    }
}

fn writeIndent(writer: anytype, indent: usize) !void {
    for (0..indent) |_| {
        try writer.writeAll("    ");
    }
}

fn emitDebugComment(writer: anytype, options: EmitOptions, source_line: ?u32, indent: usize) !void {
    if (!options.emit_debug_comments) return;
    const line = source_line orelse return;
    const source = options.source orelse return;
    const text = sourceLineText(source, line);
    try writeIndent(writer, indent);
    if (text.len == 0) {
        try writer.print("// zwgsl:{d}\n", .{line});
    } else {
        try writer.print("// zwgsl:{d}: {s}\n", .{ line, text });
    }
}

fn sourceLineText(source: []const u8, line: u32) []const u8 {
    var current_line: u32 = 1;
    var start: usize = 0;
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        if (current_line == line and source[index] == '\n') {
            return std.mem.trim(u8, source[start..index], " \t\r");
        }
        if (source[index] == '\n') {
            current_line += 1;
            start = index + 1;
        }
    }
    if (current_line == line and start <= source.len) {
        return std.mem.trim(u8, source[start..], " \t\r");
    }
    return "";
}

fn compactOutput(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, source.len);
    const writer = buffer.writer(allocator);
    var iter = std.mem.splitScalar(u8, source, '\n');
    var wrote_line = false;
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (wrote_line) try writer.writeByte('\n');
        try writer.writeAll(trimmed);
        wrote_line = true;
    }
    if (wrote_line) try writer.writeByte('\n');
    return try buffer.toOwnedSlice(allocator);
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
        .bang => "!",
        .minus => "-",
        else => "",
    };
}
