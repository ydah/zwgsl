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

const EmitFunctionContext = struct {
    definitions: std.StringHashMap(*const mir.Instruction),
    use_counts: std.StringHashMap(usize),

    fn init(allocator: std.mem.Allocator) EmitFunctionContext {
        return .{
            .definitions = std.StringHashMap(*const mir.Instruction).init(allocator),
            .use_counts = std.StringHashMap(usize).init(allocator),
        };
    }

    fn build(allocator: std.mem.Allocator, function: mir.Function) !EmitFunctionContext {
        var context = EmitFunctionContext.init(allocator);

        for (function.blocks) |*block| {
            for (block.instructions) |*instruction| {
                if (instruction.result) |result| {
                    if (isTemporaryValue(result.name)) {
                        try context.definitions.put(result.name, instruction);
                    }
                }
            }
        }

        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                try context.recordInstructionUses(instruction);
            }
            try context.recordTerminatorUses(block.terminator);
        }

        return context;
    }

    fn deinit(self: *EmitFunctionContext) void {
        self.definitions.deinit();
        self.use_counts.deinit();
    }

    fn definition(self: *const EmitFunctionContext, name: []const u8) ?*const mir.Instruction {
        return self.definitions.get(name);
    }

    fn useCount(self: *const EmitFunctionContext, name: []const u8) usize {
        return self.use_counts.get(name) orelse 0;
    }

    fn recordInstructionUses(self: *EmitFunctionContext, instruction: mir.Instruction) !void {
        switch (instruction.data) {
            .local_alloc => |alloc| {
                if (alloc.init) |value| try self.recordValueUse(value);
            },
            .copy => |copy| try self.recordValueUse(copy.value),
            .load => |place| try self.recordPlaceUse(place),
            .store => |store| {
                try self.recordPlaceUse(store.target);
                try self.recordValueUse(store.value);
            },
            .unary => |unary| try self.recordValueUse(unary.operand),
            .binary => |binary| {
                try self.recordValueUse(binary.lhs);
                try self.recordValueUse(binary.rhs);
            },
            .call => |call| {
                for (call.args) |arg| {
                    try self.recordValueUse(arg);
                }
            },
            .field => |field| try self.recordValueUse(field.target),
            .index => |index_expr| {
                try self.recordValueUse(index_expr.target);
                try self.recordValueUse(index_expr.index);
            },
        }
    }

    fn recordTerminatorUses(self: *EmitFunctionContext, terminator: mir.Terminator) !void {
        switch (terminator) {
            .none, .jump, .discard => {},
            .return_stmt => |value| {
                if (value) |returned_value| try self.recordValueUse(returned_value);
            },
            .if_term => |if_term| try self.recordValueUse(if_term.condition),
            .switch_term => |switch_term| try self.recordValueUse(switch_term.selector),
        }
    }

    fn recordValueUse(self: *EmitFunctionContext, value: *const mir.Value) !void {
        switch (value.data) {
            .identifier => |name| {
                const entry = try self.use_counts.getOrPut(name);
                if (entry.found_existing) {
                    entry.value_ptr.* += 1;
                } else {
                    entry.value_ptr.* = 1;
                }
            },
            else => {},
        }
    }

    fn recordPlaceUse(self: *EmitFunctionContext, place: *const mir.Place) !void {
        switch (place.data) {
            .identifier => |name| {
                const entry = try self.use_counts.getOrPut(name);
                if (entry.found_existing) {
                    entry.value_ptr.* += 1;
                } else {
                    entry.value_ptr.* = 1;
                }
            },
            .field => |field| try self.recordPlaceUse(field.target),
            .index => |index_expr| {
                try self.recordPlaceUse(index_expr.target);
                try self.recordValueUse(index_expr.index);
            },
        }
    }
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

    var function_context = try EmitFunctionContext.build(allocator, function);
    defer function_context.deinit();

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
    try emitBlockRegion(writer, allocator, module, function, &function_context, function.entry_block, null, 1, options, uniforms, current_functions, function.params, &sampler_aliases);
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
    function_context: *const EmitFunctionContext,
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
            try emitInstruction(writer, allocator, module, instruction, function_context, indent, options, uniforms, current_functions, current_params, sampler_aliases);
        }

        switch (block.terminator) {
            .none => return,
            .jump => |target| current = target,
            .return_stmt => |value| {
                try emitDebugComment(writer, options, block.source_line, indent);
                try writeIndent(writer, indent);
                if (value) |returned_value| {
                    try writer.writeAll("return ");
                    try emitValue(writer, module, function_context, returned_value, 0, uniforms, current_functions, current_params, sampler_aliases.items);
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
                try emitValue(writer, module, function_context, if_term.condition, 0, uniforms, current_functions, current_params, sampler_aliases.items);
                try writer.writeAll(") {\n");
                const alias_checkpoint = sampler_aliases.items.len;
                try emitBlockRegion(writer, allocator, module, function, function_context, if_term.then_block, if_term.merge_block, indent + 1, options, uniforms, current_functions, current_params, sampler_aliases);
                sampler_aliases.items.len = alias_checkpoint;
                try writeIndent(writer, indent);
                try writer.writeAll("} else {\n");
                try emitBlockRegion(writer, allocator, module, function, function_context, if_term.else_block, if_term.merge_block, indent + 1, options, uniforms, current_functions, current_params, sampler_aliases);
                sampler_aliases.items.len = alias_checkpoint;
                try writeIndent(writer, indent);
                try writer.writeAll("}\n");
                current = if_term.merge_block;
            },
            .switch_term => |switch_term| {
                try emitDebugComment(writer, options, block.source_line, indent);
                try writeIndent(writer, indent);
                try writer.writeAll("switch (");
                try emitValue(writer, module, function_context, switch_term.selector, 0, uniforms, current_functions, current_params, sampler_aliases.items);
                try writer.writeAll(") {\n");
                for (switch_term.cases) |case_target| {
                    try writeIndent(writer, indent + 1);
                    try writer.print("case {d}: {{\n", .{case_target.value});
                    const alias_checkpoint = sampler_aliases.items.len;
                    try emitBlockRegion(writer, allocator, module, function, function_context, case_target.block, switch_term.merge_block, indent + 2, options, uniforms, current_functions, current_params, sampler_aliases);
                    sampler_aliases.items.len = alias_checkpoint;
                    try writeIndent(writer, indent + 1);
                    try writer.writeAll("}\n");
                }
                try writeIndent(writer, indent + 1);
                try writer.writeAll("default: {\n");
                const alias_checkpoint = sampler_aliases.items.len;
                try emitBlockRegion(writer, allocator, module, function, function_context, switch_term.default_block, switch_term.merge_block, indent + 2, options, uniforms, current_functions, current_params, sampler_aliases);
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
    function_context: *const EmitFunctionContext,
    indent: usize,
    options: EmitOptions,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: *std.ArrayListUnmanaged(SamplerAlias),
) anyerror!void {
    switch (instruction.data) {
        .local_alloc => |alloc| {
            if (alloc.ty.isSampler()) return error.UnsupportedSamplerValue;
            try emitDebugComment(writer, options, instruction.source_line, indent);
            try writeIndent(writer, indent);
            try writer.print("{s} {s}: {s}", .{
                if (alloc.mutable) "var" else "let",
                alloc.name,
                alloc.ty.wgslName(),
            });
            if (alloc.init) |value| {
                try writer.writeAll(" = ");
                try emitValue(writer, module, function_context, value, 0, uniforms, current_functions, current_params, sampler_aliases.items);
            }
            try writer.writeAll(";\n");
        },
        .copy => |copy| {
            const result = instruction.result orelse return error.InvalidMirInstruction;
            if (result.ty.isSampler()) {
                const target = resolveSamplerIdentifier(uniforms, current_params, sampler_aliases.items, copy.value) orelse return error.UnsupportedTextureSource;
                try sampler_aliases.append(allocator, .{
                    .name = result.name,
                    .target = target,
                });
                return;
            }
            if (shouldInlineInstruction(module, function_context, instruction, current_functions)) return;
            if (isUnusedTemporary(function_context, result.name)) return;

            try emitDebugComment(writer, options, instruction.source_line, indent);
            try writeIndent(writer, indent);
            try writer.print("let {s}: {s} = ", .{ result.name, result.ty.wgslName() });
            try emitValue(writer, module, function_context, copy.value, 0, uniforms, current_functions, current_params, sampler_aliases.items);
            try writer.writeAll(";\n");
        },
        .load => |place| {
            const result = instruction.result orelse return error.InvalidMirInstruction;
            if (shouldInlineInstruction(module, function_context, instruction, current_functions)) return;
            if (isUnusedTemporary(function_context, result.name)) return;
            try emitDebugComment(writer, options, instruction.source_line, indent);
            try writeIndent(writer, indent);
            try writer.print("let {s}: {s} = ", .{ result.name, result.ty.wgslName() });
            try emitPlace(writer, module, function_context, place, 0, uniforms, current_functions, current_params, sampler_aliases.items);
            try writer.writeAll(";\n");
        },
        .store => |store| {
            try emitDebugComment(writer, options, instruction.source_line, indent);
            try writeIndent(writer, indent);
            if (matchCompoundStore(function_context, store)) |compound| {
                try emitPlace(writer, module, function_context, store.target, 0, uniforms, current_functions, current_params, sampler_aliases.items);
                try writer.print(" {s} ", .{compoundAssignOp(compound.operator)});
                try emitValue(writer, module, function_context, compound.rhs, 0, uniforms, current_functions, current_params, sampler_aliases.items);
                try writer.writeAll(";\n");
                return;
            }
            try emitPlace(writer, module, function_context, store.target, 0, uniforms, current_functions, current_params, sampler_aliases.items);
            try writer.writeAll(" = ");
            try emitValue(writer, module, function_context, store.value, 0, uniforms, current_functions, current_params, sampler_aliases.items);
            try writer.writeAll(";\n");
        },
        .unary => |unary| {
            const result = instruction.result orelse return error.InvalidMirInstruction;
            if (shouldInlineInstruction(module, function_context, instruction, current_functions)) return;
            if (isUnusedTemporary(function_context, result.name)) return;
            try emitDebugComment(writer, options, instruction.source_line, indent);
            try writeIndent(writer, indent);
            try writer.print("let {s}: {s} = {s}", .{ result.name, result.ty.wgslName(), unaryOp(unary.operator) });
            try emitValue(writer, module, function_context, unary.operand, unaryPrecedence(), uniforms, current_functions, current_params, sampler_aliases.items);
            try writer.writeAll(";\n");
        },
        .binary => |binary| {
            const result = instruction.result orelse return error.InvalidMirInstruction;
            if (shouldInlineInstruction(module, function_context, instruction, current_functions)) return;
            if (isUnusedTemporary(function_context, result.name)) return;
            const precedence = binaryPrecedence(binary.operator);
            try emitDebugComment(writer, options, instruction.source_line, indent);
            try writeIndent(writer, indent);
            try writer.print("let {s}: {s} = ", .{ result.name, result.ty.wgslName() });
            try emitValue(writer, module, function_context, binary.lhs, precedence, uniforms, current_functions, current_params, sampler_aliases.items);
            try writer.print(" {s} ", .{binaryOp(binary.operator)});
            try emitValue(writer, module, function_context, binary.rhs, precedence + 1, uniforms, current_functions, current_params, sampler_aliases.items);
            try writer.writeAll(";\n");
        },
        .call => |call| {
            if (instruction.result) |result| {
                if (shouldInlineInstruction(module, function_context, instruction, current_functions)) return;
                if (isUnusedTemporary(function_context, result.name)) {
                    try emitDebugComment(writer, options, instruction.source_line, indent);
                    try writeIndent(writer, indent);
                    try emitCallExpr(writer, module, function_context, call, result.ty, uniforms, current_functions, current_params, sampler_aliases.items);
                    try writer.writeAll(";\n");
                    return;
                }
            }

            try emitDebugComment(writer, options, instruction.source_line, indent);
            try writeIndent(writer, indent);
            if (instruction.result) |result| {
                try writer.print("let {s}: {s} = ", .{ result.name, result.ty.wgslName() });
            }
            try emitCallExpr(
                writer,
                module,
                function_context,
                call,
                if (instruction.result) |result| result.ty else null,
                uniforms,
                current_functions,
                current_params,
                sampler_aliases.items,
            );
            try writer.writeAll(";\n");
        },
        .field => |field| {
            const result = instruction.result orelse return error.InvalidMirInstruction;
            if (shouldInlineInstruction(module, function_context, instruction, current_functions)) return;
            if (isUnusedTemporary(function_context, result.name)) return;
            try emitDebugComment(writer, options, instruction.source_line, indent);
            try writeIndent(writer, indent);
            try writer.print("let {s}: {s} = ", .{ result.name, result.ty.wgslName() });
            try emitValue(writer, module, function_context, field.target, fieldPrecedence(), uniforms, current_functions, current_params, sampler_aliases.items);
            try writer.print(".{s};\n", .{field.name});
        },
        .index => |index_expr| {
            const result = instruction.result orelse return error.InvalidMirInstruction;
            if (shouldInlineInstruction(module, function_context, instruction, current_functions)) return;
            if (isUnusedTemporary(function_context, result.name)) return;
            try emitDebugComment(writer, options, instruction.source_line, indent);
            try writeIndent(writer, indent);
            try writer.print("let {s}: {s} = ", .{ result.name, result.ty.wgslName() });
            try emitValue(writer, module, function_context, index_expr.target, fieldPrecedence(), uniforms, current_functions, current_params, sampler_aliases.items);
            try writer.writeByte('[');
            try emitValue(writer, module, function_context, index_expr.index, 0, uniforms, current_functions, current_params, sampler_aliases.items);
            try writer.writeAll("];\n");
        },
    }
}

fn emitValue(
    writer: anytype,
    module: *const mir.Module,
    function_context: *const EmitFunctionContext,
    value: *const mir.Value,
    parent_precedence: u8,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
) anyerror!void {
    const precedence = valuePrecedence(module, function_context, value, current_functions);
    const wrap = precedence < parent_precedence;
    if (wrap) try writer.writeByte('(');
    try emitValueInner(writer, module, function_context, value, precedence, uniforms, current_functions, current_params, sampler_aliases);
    if (wrap) try writer.writeByte(')');
}

fn emitValueInner(
    writer: anytype,
    module: *const mir.Module,
    function_context: *const EmitFunctionContext,
    value: *const mir.Value,
    precedence: u8,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
) anyerror!void {
    switch (value.data) {
        .integer => |int_value| try writer.print("{d}", .{int_value}),
        .float => |float_value| try writeFloat(writer, float_value),
        .bool => |bool_value| try writer.writeAll(if (bool_value) "true" else "false"),
        .identifier => |name| {
            if (function_context.definition(name)) |definition| {
                if (shouldInlineInstruction(module, function_context, definition.*, current_functions)) {
                    try emitInstructionExpr(writer, module, function_context, definition.*, precedence, uniforms, current_functions, current_params, sampler_aliases);
                    return;
                }
            }
            if (resolveSamplerName(uniforms, current_params, sampler_aliases, name) != null) return error.UnsupportedSamplerValue;
            if (isInoutParam(current_params, name)) {
                try writer.print("(*{s})", .{name});
            } else {
                try writer.writeAll(name);
            }
        },
    }
}

fn emitPlace(
    writer: anytype,
    module: *const mir.Module,
    function_context: *const EmitFunctionContext,
    place: *const mir.Place,
    parent_precedence: u8,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
) anyerror!void {
    const precedence = placePrecedence(place);
    const wrap = precedence < parent_precedence;
    if (wrap) try writer.writeByte('(');
    try emitPlaceInner(writer, module, function_context, place, uniforms, current_functions, current_params, sampler_aliases);
    if (wrap) try writer.writeByte(')');
}

fn emitPlaceInner(
    writer: anytype,
    module: *const mir.Module,
    function_context: *const EmitFunctionContext,
    place: *const mir.Place,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
) anyerror!void {
    switch (place.data) {
        .identifier => |name| {
            if (isInoutParam(current_params, name)) {
                try writer.print("(*{s})", .{name});
            } else {
                try writer.writeAll(name);
            }
        },
        .field => |field| {
            try emitPlace(writer, module, function_context, field.target, fieldPrecedence(), uniforms, current_functions, current_params, sampler_aliases);
            try writer.print(".{s}", .{field.name});
        },
        .index => |index_expr| {
            try emitPlace(writer, module, function_context, index_expr.target, fieldPrecedence(), uniforms, current_functions, current_params, sampler_aliases);
            try writer.writeByte('[');
            try emitValue(writer, module, function_context, index_expr.index, 0, uniforms, current_functions, current_params, sampler_aliases);
            try writer.writeByte(']');
        },
    }
}

fn emitCallExpr(
    writer: anytype,
    module: *const mir.Module,
    function_context: *const EmitFunctionContext,
    call: mir.Call,
    result_type: ?types.Type,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
) anyerror!void {
    if (std.mem.eql(u8, call.name, "texture")) {
        try emitTextureCall(writer, module, function_context, call, uniforms, current_functions, current_params, sampler_aliases);
        return;
    }
    if (std.mem.eql(u8, call.name, "mod")) {
        try emitModCall(writer, module, function_context, call, uniforms, current_functions, current_params, sampler_aliases);
        return;
    }

    try writer.print("{s}(", .{callName(call.name, result_type orelse types.builtinType(.void))});
    const callee = findFunction(current_functions, call.name) orelse findFunction(module.global_functions, call.name);
    for (call.args, 0..) |arg, index| {
        if (callee) |function| {
            if (index < function.params.len and function.params[index].ty.isSampler()) {
                if (index > 0) try writer.writeAll(", ");
                try emitSamplerArg(writer, arg, uniforms, current_params, sampler_aliases);
                continue;
            }
            if (index < function.params.len and function.params[index].is_inout) {
                if (index > 0) try writer.writeAll(", ");
                try emitInoutArg(writer, module, function_context, arg, uniforms, current_functions, current_params, sampler_aliases);
                continue;
            }
        }
        if (index > 0) try writer.writeAll(", ");
        try emitValue(writer, module, function_context, arg, 0, uniforms, current_functions, current_params, sampler_aliases);
    }
    try writer.writeByte(')');
}

fn emitTextureCall(
    writer: anytype,
    module: *const mir.Module,
    function_context: *const EmitFunctionContext,
    call: mir.Call,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
) anyerror!void {
    if (call.args.len != 2) return error.UnsupportedTextureBuiltin;
    const sampler_name = resolveSamplerIdentifier(uniforms, current_params, sampler_aliases, call.args[0]) orelse return error.UnsupportedTextureSource;

    try writer.print("textureSample({s}_texture, {s}_sampler, ", .{ sampler_name, sampler_name });
    try emitValue(writer, module, function_context, call.args[1], 0, uniforms, current_functions, current_params, sampler_aliases);
    try writer.writeByte(')');
}

fn emitModCall(
    writer: anytype,
    module: *const mir.Module,
    function_context: *const EmitFunctionContext,
    call: mir.Call,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
) anyerror!void {
    std.debug.assert(call.args.len == 2);
    try emitValue(writer, module, function_context, call.args[0], binaryPrecedence(.percent), uniforms, current_functions, current_params, sampler_aliases);
    try writer.writeAll(" % ");
    try emitValue(writer, module, function_context, call.args[1], binaryPrecedence(.percent) + 1, uniforms, current_functions, current_params, sampler_aliases);
}

fn emitInoutArg(
    writer: anytype,
    module: *const mir.Module,
    function_context: *const EmitFunctionContext,
    arg: *const mir.Value,
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
    try emitValue(writer, module, function_context, arg, 0, uniforms, current_functions, current_params, sampler_aliases);
}

fn emitSamplerArg(
    writer: anytype,
    arg: *const mir.Value,
    uniforms: []const mir.Global,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
) anyerror!void {
    const sampler_name = resolveSamplerIdentifier(uniforms, current_params, sampler_aliases, arg) orelse return error.UnsupportedTextureSource;
    try writer.print("{s}_texture, {s}_sampler", .{ sampler_name, sampler_name });
}

fn emitInstructionExpr(
    writer: anytype,
    module: *const mir.Module,
    function_context: *const EmitFunctionContext,
    instruction: mir.Instruction,
    parent_precedence: u8,
    uniforms: []const mir.Global,
    current_functions: []const mir.Function,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
) anyerror!void {
    switch (instruction.data) {
        .copy => |copy| try emitValue(writer, module, function_context, copy.value, parent_precedence, uniforms, current_functions, current_params, sampler_aliases),
        .load => |place| try emitPlace(writer, module, function_context, place, parent_precedence, uniforms, current_functions, current_params, sampler_aliases),
        .unary => |unary| {
            try writer.print("{s}", .{unaryOp(unary.operator)});
            try emitValue(writer, module, function_context, unary.operand, unaryPrecedence(), uniforms, current_functions, current_params, sampler_aliases);
        },
        .binary => |binary| {
            const precedence = binaryPrecedence(binary.operator);
            try emitValue(writer, module, function_context, binary.lhs, precedence, uniforms, current_functions, current_params, sampler_aliases);
            try writer.print(" {s} ", .{binaryOp(binary.operator)});
            try emitValue(writer, module, function_context, binary.rhs, precedence + 1, uniforms, current_functions, current_params, sampler_aliases);
        },
        .call => |call| try emitCallExpr(writer, module, function_context, call, if (instruction.result) |result| result.ty else null, uniforms, current_functions, current_params, sampler_aliases),
        .field => |field| {
            try emitValue(writer, module, function_context, field.target, fieldPrecedence(), uniforms, current_functions, current_params, sampler_aliases);
            try writer.print(".{s}", .{field.name});
        },
        .index => |index_expr| {
            try emitValue(writer, module, function_context, index_expr.target, fieldPrecedence(), uniforms, current_functions, current_params, sampler_aliases);
            try writer.writeByte('[');
            try emitValue(writer, module, function_context, index_expr.index, 0, uniforms, current_functions, current_params, sampler_aliases);
            try writer.writeByte(']');
        },
        .local_alloc, .store => return error.InvalidMirInstruction,
    }
}

fn shouldInlineInstruction(
    module: *const mir.Module,
    function_context: *const EmitFunctionContext,
    instruction: mir.Instruction,
    current_functions: []const mir.Function,
) bool {
    const result = instruction.result orelse return false;
    if (!isTemporaryValue(result.name)) return false;
    if (function_context.useCount(result.name) != 1) return false;

    return switch (instruction.data) {
        .copy, .load, .unary, .binary, .field, .index => true,
        .call => |call| canInlineCall(module, current_functions, call),
        .local_alloc, .store => false,
    };
}

fn canInlineCall(module: *const mir.Module, current_functions: []const mir.Function, call: mir.Call) bool {
    const callee = findFunction(current_functions, call.name) orelse findFunction(module.global_functions, call.name);
    if (callee) |function| {
        for (function.params) |param| {
            if (param.is_inout) return false;
        }
    }
    return true;
}

fn isUnusedTemporary(function_context: *const EmitFunctionContext, name: []const u8) bool {
    return isTemporaryValue(name) and function_context.useCount(name) == 0;
}

fn isTemporaryValue(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__ssa_");
}

fn matchCompoundStore(function_context: *const EmitFunctionContext, store: mir.Store) ?struct {
    operator: token.TokenTag,
    rhs: *const mir.Value,
} {
    const binary_name = switch (store.value.data) {
        .identifier => |name| name,
        else => return null,
    };
    const binary_instruction = function_context.definition(binary_name) orelse return null;
    const binary = switch (binary_instruction.data) {
        .binary => |binary| binary,
        else => return null,
    };
    const load_name = switch (binary.lhs.data) {
        .identifier => |name| name,
        else => return null,
    };
    const load_instruction = function_context.definition(load_name) orelse return null;
    const load_place = switch (load_instruction.data) {
        .load => |place| place,
        else => return null,
    };
    if (load_place != store.target) return null;
    return .{
        .operator = binary.operator,
        .rhs = binary.rhs,
    };
}

fn valuePrecedence(
    module: *const mir.Module,
    function_context: *const EmitFunctionContext,
    value: *const mir.Value,
    current_functions: []const mir.Function,
) u8 {
    return switch (value.data) {
        .integer, .float, .bool => 9,
        .identifier => |name| blk: {
            if (function_context.definition(name)) |definition| {
                if (shouldInlineInstruction(module, function_context, definition.*, current_functions)) {
                    break :blk instructionPrecedence(definition.*);
                }
            }
            break :blk 9;
        },
    };
}

fn instructionPrecedence(instruction: mir.Instruction) u8 {
    return switch (instruction.data) {
        .copy => |copy| switch (copy.value.data) {
            .integer, .float, .bool, .identifier => 9,
        },
        .load => |place| placePrecedence(place),
        .unary => unaryPrecedence(),
        .binary => |binary| binaryPrecedence(binary.operator),
        .call, .field, .index => fieldPrecedence(),
        .local_alloc, .store => 0,
    };
}

fn placePrecedence(place: *const mir.Place) u8 {
    return switch (place.data) {
        .identifier => 9,
        .field, .index => fieldPrecedence(),
    };
}

fn fieldPrecedence() u8 {
    return 8;
}

fn unaryPrecedence() u8 {
    return 7;
}

fn binaryPrecedence(tag: token.TokenTag) u8 {
    return switch (tag) {
        .star, .slash, .percent => 6,
        .plus, .minus => 5,
        .lt, .gt, .le, .ge => 4,
        .eq, .neq => 3,
        .and_and => 2,
        .or_or => 1,
        else => 0,
    };
}

fn compoundAssignOp(tag: token.TokenTag) []const u8 {
    return switch (tag) {
        .plus => "+=",
        .minus => "-=",
        .star => "*=",
        .slash => "/=",
        else => "=",
    };
}

fn resolveSamplerIdentifier(
    uniforms: []const mir.Global,
    current_params: []const mir.Param,
    sampler_aliases: []const SamplerAlias,
    value: *const mir.Value,
) ?[]const u8 {
    return switch (value.data) {
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
