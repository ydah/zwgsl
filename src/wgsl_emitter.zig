const std = @import("std");
const ast = @import("ast.zig");
const glsl_emitter = @import("glsl_emitter.zig");
const mir = @import("mir.zig");
const token = @import("token.zig");
const types = @import("types.zig");

pub const EmitOptions = struct {
    emit_debug_comments: bool = false,
    optimize_output: bool = false,
    source: ?[]const u8 = null,
};

pub const Output = glsl_emitter.Output;

pub const EmitError = error{
    UnsupportedSamplerValue,
    UnsupportedSamplerType,
    UnsupportedTextureBuiltin,
    UnsupportedTextureSource,
};

const SamplerAlias = struct {
    name: []const u8,
    target: []const u8,
};

pub fn emit(allocator: std.mem.Allocator, module: *const mir.Module, options: EmitOptions) anyerror!Output {
    return .{
        .vertex = if (module.entryPoint(.vertex)) |entry_point| try emitStage(allocator, module, entry_point, options) else null,
        .fragment = if (module.entryPoint(.fragment)) |entry_point| try emitStage(allocator, module, entry_point, options) else null,
        .compute = if (module.entryPoint(.compute)) |entry_point| try emitStage(allocator, module, entry_point, options) else null,
    };
}

fn emitStage(allocator: std.mem.Allocator, module: *const mir.Module, entry_point: mir.EntryPoint, options: EmitOptions) anyerror![]const u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
    const writer = buffer.writer(allocator);

    if (entry_point.stage != .compute) {
        try emitStageInterfaceStructs(writer, module, entry_point);
    }
    try emitBindings(writer, module.bindings);
    try emitPrivateGlobals(writer, entry_point);

    for (module.structs) |struct_decl| {
        try emitUserStruct(writer, struct_decl);
        try writer.writeByte('\n');
    }

    for (module.global_functions) |function| {
        try emitFunction(writer, allocator, module, function, options, null, false, module.uniforms, module.global_functions);
        try writer.writeByte('\n');
    }

    for (entry_point.functions, 0..) |function, index| {
        try emitFunction(
            writer,
            allocator,
            module,
            function,
            options,
            entry_point.stage,
            index == entry_point.main_function_index,
            module.uniforms,
            entry_point.functions,
        );
        try writer.writeByte('\n');
    }

    try emitEntryPoint(writer, module, entry_point);

    const output = try buffer.toOwnedSlice(allocator);
    if (!options.optimize_output) return output;
    return compactOutput(allocator, output);
}

fn emitStageInterfaceStructs(writer: anytype, module: *const mir.Module, entry_point: mir.EntryPoint) !void {
    switch (entry_point.stage) {
        .vertex => {
            if (entry_point.interface.inputs.len > 0) {
                try writer.writeAll("struct VertexInput {\n");
                for (entry_point.interface.inputs, 0..) |input, index| {
                    try writer.print("    @location({d}) {s}: {s},\n", .{ declLocation(input, index), input.name, input.ty.wgslName() });
                }
                try writer.writeAll("};\n\n");
            }

            try writer.writeAll("struct VertexOutput {\n");
            try writer.writeAll("    @builtin(position) gl_Position: vec4f,\n");
            for (entry_point.interface.varyings) |varying| {
                try writer.print("    @location({d}) {s}: {s},\n", .{ varyingLocation(module, varying.name), varying.name, varying.ty.wgslName() });
            }
            for (entry_point.interface.outputs, 0..) |output, index| {
                try writer.print("    @location({d}) {s}: {s},\n", .{ declLocation(output, index), output.name, output.ty.wgslName() });
            }
            try writer.writeAll("};\n\n");
        },
        .fragment => {
            if (entry_point.interface.varyings.len > 0) {
                try writer.writeAll("struct FragmentInput {\n");
                for (entry_point.interface.varyings) |varying| {
                    try writer.print("    @location({d}) {s}: {s},\n", .{ varyingLocation(module, varying.name), varying.name, varying.ty.wgslName() });
                }
                try writer.writeAll("};\n\n");
            }

            if (entry_point.interface.outputs.len > 0) {
                try writer.writeAll("struct FragmentOutput {\n");
                for (entry_point.interface.outputs, 0..) |output, index| {
                    try writer.print("    @location({d}) {s}: {s},\n", .{ declLocation(output, index), output.name, output.ty.wgslName() });
                }
                try writer.writeAll("};\n\n");
            }
        },
        .compute => {},
    }
}

fn emitBindings(writer: anytype, bindings: []const mir.Binding) !void {
    for (bindings) |binding| {
        switch (binding.kind) {
            .uniform => try writer.print("@group({d}) @binding({d}) var<uniform> {s}: {s};\n", .{
                binding.group,
                binding.binding,
                binding.name,
                binding.ty.wgslName(),
            }),
            .texture => try writer.print("@group({d}) @binding({d}) var {s}_texture: {s};\n", .{
                binding.group,
                binding.binding,
                binding.name,
                samplerTextureType(binding.ty) orelse return error.UnsupportedSamplerType,
            }),
            .sampler => try writer.print("@group({d}) @binding({d}) var {s}_sampler: sampler;\n", .{
                binding.group,
                binding.binding,
                binding.name,
            }),
        }
    }
    if (bindings.len > 0) try writer.writeByte('\n');
}

fn emitPrivateGlobals(writer: anytype, entry_point: mir.EntryPoint) !void {
    switch (entry_point.stage) {
        .vertex => {
            try writer.writeAll("var<private> gl_Position: vec4f;\n");
            for (entry_point.interface.inputs) |input| {
                try writer.print("var<private> {s}: {s};\n", .{ input.name, input.ty.wgslName() });
            }
            for (entry_point.interface.varyings) |varying| {
                try writer.print("var<private> {s}: {s};\n", .{ varying.name, varying.ty.wgslName() });
            }
            for (entry_point.interface.outputs) |output| {
                try writer.print("var<private> {s}: {s};\n", .{ output.name, output.ty.wgslName() });
            }
            if (entry_point.interface.inputs.len > 0 or entry_point.interface.varyings.len > 0 or entry_point.interface.outputs.len > 0) try writer.writeByte('\n');
        },
        .fragment => {
            for (entry_point.interface.varyings) |varying| {
                try writer.print("var<private> {s}: {s};\n", .{ varying.name, varying.ty.wgslName() });
            }
            for (entry_point.interface.outputs) |output| {
                try writer.print("var<private> {s}: {s};\n", .{ output.name, output.ty.wgslName() });
            }
            if (entry_point.interface.varyings.len > 0 or entry_point.interface.outputs.len > 0) try writer.writeByte('\n');
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

fn emitUserStruct(writer: anytype, struct_decl: mir.StructDecl) !void {
    try writer.print("struct {s} {{\n", .{struct_decl.name});
    for (struct_decl.fields) |field| {
        try writer.print("    {s}: {s},\n", .{ field.name, field.ty.wgslName() });
    }
    try writer.writeAll("};\n");
}

fn emitFunction(
    writer: anytype,
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: mir.Function,
    options: EmitOptions,
    stage: ?ast.Stage,
    is_entry_main: bool,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
) anyerror!void {
    try emitDebugComment(writer, options, function.source_line, 0);

    const name = if (stage != null and is_entry_main) internalMainName(stage.?) else function.name;
    try writer.print("fn {s}(", .{name});
    var wrote_param = false;
    for (function.params) |param| {
        if (param.ty.isSampler()) {
            if (wrote_param) try writer.writeAll(", ");
            try writer.print("{s}_texture: {s}, {s}_sampler: sampler", .{
                param.name,
                samplerTextureType(param.ty) orelse return error.UnsupportedSamplerType,
                param.name,
            });
            wrote_param = true;
            continue;
        }
        if (wrote_param) try writer.writeAll(", ");
        if (param.is_inout) {
            try writer.print("{s}: ptr<function, {s}>", .{ param.name, param.ty.wgslName() });
        } else {
            try writer.print("{s}: {s}", .{ param.name, param.ty.wgslName() });
        }
        wrote_param = true;
    }
    try writer.writeByte(')');
    if (!function.return_type.isVoid()) {
        try writer.print(" -> {s}", .{function.return_type.wgslName()});
    }
    try writer.writeAll(" {\n");
    var sampler_aliases = std.ArrayListUnmanaged(SamplerAlias){};
    defer sampler_aliases.deinit(allocator);
    try emitBlockRegion(writer, allocator, module, function, function.entry_block, null, 1, options, uniforms, current_functions, function.params, &sampler_aliases);
    try writer.writeAll("}\n");
}

fn emitEntryPoint(writer: anytype, module: *const mir.Module, entry_point: mir.EntryPoint) !void {
    _ = module;
    switch (entry_point.stage) {
        .vertex => {
            try writer.writeAll("@vertex\n");
            if (entry_point.interface.inputs.len > 0) {
                try writer.writeAll("fn main(input: VertexInput) -> VertexOutput {\n");
                for (entry_point.interface.inputs) |input| {
                    try writer.print("    {s} = input.{s};\n", .{ input.name, input.name });
                }
            } else {
                try writer.writeAll("fn main() -> VertexOutput {\n");
            }
            try writer.print("    {s}();\n", .{internalMainName(.vertex)});
            try writer.writeAll("    var output: VertexOutput;\n");
            try writer.writeAll("    output.gl_Position = gl_Position;\n");
            for (entry_point.interface.varyings) |varying| {
                try writer.print("    output.{s} = {s};\n", .{ varying.name, varying.name });
            }
            for (entry_point.interface.outputs) |output| {
                try writer.print("    output.{s} = {s};\n", .{ output.name, output.name });
            }
            try writer.writeAll("    return output;\n");
            try writer.writeAll("}\n");
        },
        .fragment => {
            try writer.writeAll("@fragment\n");
            if (entry_point.interface.varyings.len > 0) {
                try writer.writeAll("fn main(input: FragmentInput)");
            } else {
                try writer.writeAll("fn main()");
            }
            if (entry_point.interface.outputs.len > 0) {
                try writer.writeAll(" -> FragmentOutput");
            }
            try writer.writeAll(" {\n");
            for (entry_point.interface.varyings) |varying| {
                try writer.print("    {s} = input.{s};\n", .{ varying.name, varying.name });
            }
            try writer.print("    {s}();\n", .{internalMainName(.fragment)});
            if (entry_point.interface.outputs.len > 0) {
                try writer.writeAll("    var output: FragmentOutput;\n");
                for (entry_point.interface.outputs) |output| {
                    try writer.print("    output.{s} = {s};\n", .{ output.name, output.name });
                }
                try writer.writeAll("    return output;\n");
            }
            try writer.writeAll("}\n");
        },
        .compute => {
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

fn emitBlockRegion(
    writer: anytype,
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    function: mir.Function,
    start_label: []const u8,
    stop_label: ?[]const u8,
    indent: usize,
    options: EmitOptions,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: *std.ArrayListUnmanaged(SamplerAlias),
) anyerror!void {
    var current: ?[]const u8 = start_label;
    while (current) |label| {
        if (stop_label) |stop| {
            if (std.mem.eql(u8, label, stop)) return;
        }

        const block = findBlock(function.blocks, label) orelse return error.InvalidBlockGraph;
        for (block.instructions) |instruction| {
            try emitInstruction(writer, allocator, module, instruction, indent, options, uniforms, current_functions, current_params, sampler_aliases);
        }

        switch (block.terminator) {
            .none => return,
            .jump => |target| current = target,
            .return_stmt => |value| {
                try emitDebugComment(writer, options, block.source_line, indent);
                try writeIndent(writer, indent);
                if (value) |expr| {
                    try writer.writeAll("return ");
                    try emitExpr(writer, module, expr, 0, uniforms, current_functions, current_params, sampler_aliases.items);
                    try writer.writeAll(";\n");
                } else {
                    try writer.writeAll("return;\n");
                }
                return;
            },
            .discard => {
                try emitDebugComment(writer, options, block.source_line, indent);
                try writeIndent(writer, indent);
                try writer.writeAll("discard;\n");
                return;
            },
            .if_term => |if_term| {
                try emitDebugComment(writer, options, block.source_line, indent);
                try writeIndent(writer, indent);
                try writer.writeAll("if (");
                try emitExpr(writer, module, if_term.condition, 0, uniforms, current_functions, current_params, sampler_aliases.items);
                try writer.writeAll(") {\n");
                const alias_checkpoint = sampler_aliases.items.len;
                try emitBlockRegion(writer, allocator, module, function, if_term.then_block, if_term.merge_block, indent + 1, options, uniforms, current_functions, current_params, sampler_aliases);
                sampler_aliases.items.len = alias_checkpoint;
                try writeIndent(writer, indent);
                try writer.writeAll("} else {\n");
                try emitBlockRegion(writer, allocator, module, function, if_term.else_block, if_term.merge_block, indent + 1, options, uniforms, current_functions, current_params, sampler_aliases);
                sampler_aliases.items.len = alias_checkpoint;
                try writeIndent(writer, indent);
                try writer.writeAll("}\n");
                current = if_term.merge_block;
            },
            .switch_term => |switch_term| {
                try emitDebugComment(writer, options, block.source_line, indent);
                try writeIndent(writer, indent);
                try writer.writeAll("switch (");
                try emitExpr(writer, module, switch_term.selector, 0, uniforms, current_functions, current_params, sampler_aliases.items);
                try writer.writeAll(") {\n");
                for (switch_term.cases) |case_target| {
                    try writeIndent(writer, indent + 1);
                    try writer.print("case {d}: {{\n", .{case_target.value});
                    const alias_checkpoint = sampler_aliases.items.len;
                    try emitBlockRegion(writer, allocator, module, function, case_target.block, switch_term.merge_block, indent + 2, options, uniforms, current_functions, current_params, sampler_aliases);
                    sampler_aliases.items.len = alias_checkpoint;
                    try writeIndent(writer, indent + 1);
                    try writer.writeAll("}\n");
                }
                try writeIndent(writer, indent + 1);
                try writer.writeAll("default: {\n");
                const alias_checkpoint = sampler_aliases.items.len;
                try emitBlockRegion(writer, allocator, module, function, switch_term.default_block, switch_term.merge_block, indent + 2, options, uniforms, current_functions, current_params, sampler_aliases);
                sampler_aliases.items.len = alias_checkpoint;
                try writeIndent(writer, indent + 1);
                try writer.writeAll("}\n");
                try writeIndent(writer, indent);
                try writer.writeAll("}\n");
                current = switch_term.merge_block;
            },
        }
    }
}

fn emitInstruction(
    writer: anytype,
    allocator: std.mem.Allocator,
    module: *const mir.Module,
    instruction: mir.Instruction,
    indent: usize,
    options: EmitOptions,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: *std.ArrayListUnmanaged(SamplerAlias),
) anyerror!void {
    switch (instruction.data) {
        .var_decl => |decl| {
            if (decl.ty.isSampler()) {
                const value = decl.value orelse return error.UnsupportedTextureSource;
                if (decl.mutable) return error.UnsupportedSamplerValue;
                const target = resolveSamplerIdentifier(uniforms, current_params, sampler_aliases.items, value) orelse return error.UnsupportedTextureSource;
                try sampler_aliases.append(allocator, .{
                    .name = decl.name,
                    .target = target,
                });
                return;
            }

            try emitDebugComment(writer, options, instruction.source_line, indent);
            try writeIndent(writer, indent);
            try writer.print("{s} {s}: {s}", .{
                if (decl.mutable) "var" else "let",
                decl.name,
                decl.ty.wgslName(),
            });
            if (decl.value) |value| {
                try writer.writeAll(" = ");
                try emitExpr(writer, module, value, 0, uniforms, current_functions, current_params, sampler_aliases.items);
            }
            try writer.writeAll(";\n");
        },
        .assign => |assignment| {
            try emitDebugComment(writer, options, instruction.source_line, indent);
            try writeIndent(writer, indent);
            try emitExpr(writer, module, assignment.target, 0, uniforms, current_functions, current_params, sampler_aliases.items);
            try writer.print(" {s} ", .{assignmentOp(assignment.operator)});
            try emitExpr(writer, module, assignment.value, 0, uniforms, current_functions, current_params, sampler_aliases.items);
            try writer.writeAll(";\n");
        },
        .expr => |expr| {
            try emitDebugComment(writer, options, instruction.source_line, indent);
            try writeIndent(writer, indent);
            try emitExpr(writer, module, expr, 0, uniforms, current_functions, current_params, sampler_aliases.items);
            try writer.writeAll(";\n");
        },
    }
}

fn emitExpr(
    writer: anytype,
    module: *const mir.Module,
    expr: *const mir.Expr,
    parent_precedence: u8,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
) anyerror!void {
    const precedence = exprPrecedence(expr);
    const wrap = precedence < parent_precedence;
    if (wrap) try writer.writeByte('(');

    switch (expr.data) {
        .integer => |value| try writer.print("{d}", .{value}),
        .float => |value| try writeFloat(writer, value),
        .bool => |value| try writer.writeAll(if (value) "true" else "false"),
        .identifier => |name| {
            if (resolveSamplerName(uniforms, current_params, sampler_aliases, name) != null) return error.UnsupportedSamplerValue;
            if (isInoutParam(current_params, name)) {
                try writer.print("(*{s})", .{name});
            } else {
                try writer.writeAll(name);
            }
        },
        .unary => |unary| {
            try writer.print("{s}", .{unaryOp(unary.operator)});
            try emitExpr(writer, module, unary.operand, precedence, uniforms, current_functions, current_params, sampler_aliases);
        },
        .binary => |binary| {
            try emitExpr(writer, module, binary.lhs, precedence, uniforms, current_functions, current_params, sampler_aliases);
            try writer.print(" {s} ", .{binaryOp(binary.operator)});
            try emitExpr(writer, module, binary.rhs, precedence + 1, uniforms, current_functions, current_params, sampler_aliases);
        },
        .call => |call| {
            if (std.mem.eql(u8, call.name, "texture")) {
                try emitTextureCall(writer, module, call, uniforms, current_functions, current_params, sampler_aliases);
                if (wrap) try writer.writeByte(')');
                return;
            }
            if (std.mem.eql(u8, call.name, "mod")) {
                try emitModCall(writer, module, call, uniforms, current_functions, current_params, sampler_aliases);
                if (wrap) try writer.writeByte(')');
                return;
            }

            try writer.print("{s}(", .{callName(call.name, expr.ty)});
            const callee = findFunction(current_functions, call.name) orelse findFunction(module.global_functions, call.name);
            for (call.args, 0..) |arg, index| {
                if (callee) |function| {
                    if (index < function.params.len and function.params[index].ty.isSampler()) {
                        if (index > 0) try writer.writeAll(", ");
                        try emitSamplerArg(writer, module, arg, uniforms, current_functions, current_params, sampler_aliases);
                        continue;
                    }
                    if (index < function.params.len and function.params[index].is_inout) {
                        if (index > 0) try writer.writeAll(", ");
                        try emitInoutArg(writer, module, arg, uniforms, current_functions, current_params, sampler_aliases);
                        continue;
                    }
                }
                if (index > 0) try writer.writeAll(", ");
                try emitExpr(writer, module, arg, 0, uniforms, current_functions, current_params, sampler_aliases);
            }
            try writer.writeByte(')');
        },
        .field => |field| {
            try emitExpr(writer, module, field.target, precedence, uniforms, current_functions, current_params, sampler_aliases);
            try writer.print(".{s}", .{field.name});
        },
        .index => |index_expr| {
            try emitExpr(writer, module, index_expr.target, precedence, uniforms, current_functions, current_params, sampler_aliases);
            try writer.writeByte('[');
            try emitExpr(writer, module, index_expr.index, 0, uniforms, current_functions, current_params, sampler_aliases);
            try writer.writeByte(']');
        },
    }

    if (wrap) try writer.writeByte(')');
}

fn emitTextureCall(
    writer: anytype,
    module: *const mir.Module,
    call: mir.Expr.Call,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
) anyerror!void {
    if (call.args.len != 2) return error.UnsupportedTextureBuiltin;
    const sampler_name = resolveSamplerIdentifier(uniforms, current_params, sampler_aliases, call.args[0]) orelse return error.UnsupportedTextureSource;

    try writer.print("textureSample({s}_texture, {s}_sampler, ", .{ sampler_name, sampler_name });
    try emitExpr(writer, module, call.args[1], 0, uniforms, current_functions, current_params, sampler_aliases);
    try writer.writeByte(')');
}

fn emitModCall(
    writer: anytype,
    module: *const mir.Module,
    call: mir.Expr.Call,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
) anyerror!void {
    std.debug.assert(call.args.len == 2);
    try emitExpr(writer, module, call.args[0], 6, uniforms, current_functions, current_params, sampler_aliases);
    try writer.writeAll(" % ");
    try emitExpr(writer, module, call.args[1], 7, uniforms, current_functions, current_params, sampler_aliases);
}

fn emitInoutArg(
    writer: anytype,
    module: *const mir.Module,
    arg: *const mir.Expr,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
) anyerror!void {
    if (arg.data == .identifier and isInoutParam(current_params, arg.data.identifier)) {
        try writer.writeAll(arg.data.identifier);
        return;
    }

    try writer.writeByte('&');
    try emitExpr(writer, module, arg, 0, uniforms, current_functions, current_params, sampler_aliases);
}

fn emitSamplerArg(
    writer: anytype,
    module: *const mir.Module,
    arg: *const mir.Expr,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
) anyerror!void {
    _ = module;
    _ = current_functions;

    const sampler_name = resolveSamplerIdentifier(uniforms, current_params, sampler_aliases, arg) orelse return error.UnsupportedTextureSource;
    try writer.print("{s}_texture, {s}_sampler", .{ sampler_name, sampler_name });
}

fn findUniform(uniforms: []const mir.Global, name: []const u8) ?mir.Global {
    for (uniforms) |uniform| {
        if (std.mem.eql(u8, uniform.name, name)) return uniform;
    }
    return null;
}

fn findFunction(functions: []const mir.Function, name: []const u8) ?mir.Function {
    for (functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn findBlock(blocks: []const mir.BasicBlock, label: []const u8) ?*const mir.BasicBlock {
    for (blocks) |*block| {
        if (std.mem.eql(u8, block.label, label)) return block;
    }
    return null;
}

fn isInoutParam(params: []const mir.Param, name: []const u8) bool {
    for (params) |param| {
        if (param.is_inout and std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

fn resolveSamplerIdentifier(
    uniforms: []const mir.Global,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
    expr: *const mir.Expr,
) ?[]const u8 {
    return switch (expr.data) {
        .identifier => |name| resolveSamplerName(uniforms, current_params, sampler_aliases, name),
        else => null,
    };
}

fn resolveSamplerName(
    uniforms: []const mir.Global,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
    name: []const u8,
) ?[]const u8 {
    var alias_index = sampler_aliases.len;
    while (alias_index > 0) {
        alias_index -= 1;
        const alias = sampler_aliases[alias_index];
        if (std.mem.eql(u8, alias.name, name)) {
            if (std.mem.eql(u8, alias.target, name)) return alias.target;
            return resolveSamplerName(uniforms, current_params, sampler_aliases[0..alias_index], alias.target) orelse alias.target;
        }
    }

    if (findUniform(uniforms, name)) |uniform| {
        if (uniform.ty.isSampler()) return uniform.name;
    }

    for (current_params) |param| {
        if (param.ty.isSampler() and std.mem.eql(u8, param.name, name)) return param.name;
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

fn varyingLocation(module: *const mir.Module, name: []const u8) u32 {
    for (module.entry_points) |entry_point| {
        for (entry_point.interface.varyings, 0..) |varying, index| {
            if (std.mem.eql(u8, varying.name, name)) return @intCast(index);
        }
    }
    return 0;
}

fn declLocation(decl: mir.Global, index: usize) u32 {
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
                .symbol => "i32",
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

fn exprPrecedence(expr: *const mir.Expr) u8 {
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
