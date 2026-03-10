const std = @import("std");
const hir = @import("hir.zig");
const mir = @import("mir.zig");
const token = @import("token.zig");
const types = @import("types.zig");

pub fn build(allocator: std.mem.Allocator, module: *hir.Module) !*mir.Module {
    var builder = Builder{ .allocator = allocator };
    return try builder.lowerModule(module);
}

const Builder = struct {
    allocator: std.mem.Allocator,

    fn lowerModule(self: *Builder, module: *hir.Module) !*mir.Module {
        const lowered = try self.allocator.create(mir.Module);
        lowered.* = .{
            .version = module.version,
            .uniforms = try self.lowerGlobals(module.uniforms),
            .bindings = try self.lowerBindings(module.uniforms),
            .structs = try self.lowerStructs(module.structs),
            .global_functions = try self.lowerFunctions(module.global_functions),
            .entry_points = try self.lowerEntryPoints(module.entry_points),
        };
        return lowered;
    }

    fn lowerEntryPoints(self: *Builder, entry_points: []const hir.EntryPoint) ![]const mir.EntryPoint {
        const lowered = try self.allocator.alloc(mir.EntryPoint, entry_points.len);
        for (entry_points, 0..) |entry_point, index| {
            lowered[index] = .{
                .stage = entry_point.stage,
                .precision = entry_point.precision,
                .interface = .{
                    .inputs = try self.lowerGlobals(entry_point.interface.inputs),
                    .outputs = try self.lowerGlobals(entry_point.interface.outputs),
                    .varyings = try self.lowerGlobals(entry_point.interface.varyings),
                },
                .functions = try self.lowerFunctions(entry_point.functions),
                .main_function_index = entry_point.main_function_index,
                .source_line = entry_point.source_line,
                .source_column = entry_point.source_column,
            };
        }
        return lowered;
    }

    fn lowerBindings(self: *Builder, uniforms: []const hir.Global) ![]const mir.Binding {
        var bindings = std.ArrayListUnmanaged(mir.Binding){};
        defer bindings.deinit(self.allocator);

        var next_binding: u32 = 0;
        for (uniforms) |uniform| {
            if (uniform.ty.isSampler()) {
                try bindings.append(self.allocator, .{
                    .name = uniform.name,
                    .ty = uniform.ty,
                    .kind = .texture,
                    .binding = next_binding,
                    .source_line = uniform.source_line,
                    .source_column = uniform.source_column,
                });
                try bindings.append(self.allocator, .{
                    .name = uniform.name,
                    .ty = uniform.ty,
                    .kind = .sampler,
                    .binding = next_binding + 1,
                    .source_line = uniform.source_line,
                    .source_column = uniform.source_column,
                });
                next_binding += 2;
                continue;
            }

            try bindings.append(self.allocator, .{
                .name = uniform.name,
                .ty = uniform.ty,
                .kind = .uniform,
                .binding = next_binding,
                .source_line = uniform.source_line,
                .source_column = uniform.source_column,
            });
            next_binding += 1;
        }

        return try bindings.toOwnedSlice(self.allocator);
    }

    fn lowerGlobals(self: *Builder, globals: []const hir.Global) ![]const mir.Global {
        const lowered = try self.allocator.alloc(mir.Global, globals.len);
        for (globals, 0..) |global, index| {
            lowered[index] = .{
                .name = global.name,
                .ty = global.ty,
                .location = global.location,
                .source_line = global.source_line,
                .source_column = global.source_column,
            };
        }
        return lowered;
    }

    fn lowerStructs(self: *Builder, structs: []const hir.StructDecl) ![]const mir.StructDecl {
        const lowered = try self.allocator.alloc(mir.StructDecl, structs.len);
        for (structs, 0..) |struct_decl, index| {
            lowered[index] = .{
                .name = struct_decl.name,
                .fields = try self.lowerStructFields(struct_decl.fields),
                .source_line = struct_decl.source_line,
                .source_column = struct_decl.source_column,
            };
        }
        return lowered;
    }

    fn lowerStructFields(self: *Builder, fields: []const hir.StructField) ![]const mir.StructField {
        const lowered = try self.allocator.alloc(mir.StructField, fields.len);
        for (fields, 0..) |field, index| {
            lowered[index] = .{
                .name = field.name,
                .ty = field.ty,
                .source_line = field.source_line,
                .source_column = field.source_column,
            };
        }
        return lowered;
    }

    fn lowerFunctions(self: *Builder, functions: []const hir.Function) ![]const mir.Function {
        const lowered = try self.allocator.alloc(mir.Function, functions.len);
        for (functions, 0..) |function, index| {
            lowered[index] = try self.lowerFunction(function);
        }
        return lowered;
    }

    fn lowerFunction(self: *Builder, function: hir.Function) !mir.Function {
        var lowerer = FunctionLowerer{
            .allocator = self.allocator,
        };
        return try lowerer.lower(function);
    }
};

const FunctionLowerer = struct {
    allocator: std.mem.Allocator,
    next_block_id: usize = 0,
    next_value_id: usize = 0,
    blocks: std.ArrayListUnmanaged(PendingBlock) = .{},

    fn lower(self: *FunctionLowerer, function: hir.Function) !mir.Function {
        defer self.deinit();

        var context = LowerContext.init(self.allocator);
        defer context.deinit();

        const entry_index = try self.newBlock("entry", function.source_line, function.source_column);
        _ = try self.lowerStatements(entry_index, function.body, &context);

        const finalized_blocks = try self.finalizeBlocks();
        return .{
            .name = function.name,
            .return_type = function.return_type,
            .params = try self.lowerParams(function.params),
            .entry_block = finalized_blocks[entry_index].label,
            .blocks = finalized_blocks,
            .stage = function.stage,
            .source_line = function.source_line,
            .source_column = function.source_column,
        };
    }

    fn deinit(self: *FunctionLowerer) void {
        self.blocks.deinit(self.allocator);
    }

    fn lowerParams(self: *FunctionLowerer, params: []const hir.Param) ![]const mir.Param {
        const lowered = try self.allocator.alloc(mir.Param, params.len);
        for (params, 0..) |param, index| {
            lowered[index] = .{
                .name = param.name,
                .ty = param.ty,
                .is_inout = param.is_inout,
                .source_line = param.source_line,
                .source_column = param.source_column,
            };
        }
        return lowered;
    }

    fn finalizeBlocks(self: *FunctionLowerer) ![]const mir.BasicBlock {
        const finalized = try self.allocator.alloc(mir.BasicBlock, self.blocks.items.len);
        for (self.blocks.items, 0..) |*block, index| {
            finalized[index] = .{
                .label = block.label,
                .instructions = try block.instructions.toOwnedSlice(self.allocator),
                .terminator = block.terminator,
                .source_line = block.source_line,
                .source_column = block.source_column,
            };
        }
        return finalized;
    }

    fn newBlock(self: *FunctionLowerer, prefix: []const u8, source_line: ?u32, source_column: ?u32) !usize {
        const label = try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ prefix, self.next_block_id });
        self.next_block_id += 1;
        try self.blocks.append(self.allocator, .{
            .label = label,
            .source_line = source_line,
            .source_column = source_column,
        });
        return self.blocks.items.len - 1;
    }

    fn lowerStatements(
        self: *FunctionLowerer,
        start_block: usize,
        statements: []const hir.Statement,
        context: *LowerContext,
    ) anyerror!usize {
        var current = start_block;
        for (statements) |statement| {
            current = switch (statement.data) {
                .var_decl => blk: {
                    try self.lowerVarDecl(current, statement, context);
                    break :blk current;
                },
                .assign => blk: {
                    try self.lowerAssign(current, statement.data.assign, statement.source_line, statement.source_column, context);
                    break :blk current;
                },
                .expr => blk: {
                    try self.lowerExprStatement(current, statement.data.expr, context);
                    break :blk current;
                },
                .return_stmt => blk: {
                    self.blocks.items[current].source_line = statement.source_line;
                    self.blocks.items[current].source_column = statement.source_column;
                    self.blocks.items[current].terminator = .{
                        .return_stmt = if (statement.data.return_stmt) |value|
                            try self.lowerValue(current, value, null, context)
                        else
                            null,
                    };
                    break :blk current;
                },
                .discard => blk: {
                    self.blocks.items[current].source_line = statement.source_line;
                    self.blocks.items[current].source_column = statement.source_column;
                    self.blocks.items[current].terminator = .{ .discard = {} };
                    break :blk current;
                },
                .if_stmt => try self.lowerIf(current, statement, context),
                .switch_stmt => try self.lowerSwitch(current, statement, context),
            };
        }
        return current;
    }

    fn lowerVarDecl(
        self: *FunctionLowerer,
        block_index: usize,
        statement: hir.Statement,
        context: *LowerContext,
    ) anyerror!void {
        const decl = statement.data.var_decl;
        if (!decl.mutable) {
            const value_expr = decl.value orelse return error.InvalidImmutableBinding;
            const value = try self.lowerValue(block_index, value_expr, decl.name, context);
            try context.immutable_values.put(decl.name, value);
            return;
        }

        const init = if (decl.value) |expr| try self.lowerValue(block_index, expr, null, context) else null;
        try self.blocks.items[block_index].instructions.append(self.allocator, .{
            .source_line = statement.source_line,
            .source_column = statement.source_column,
            .data = .{
                .local_alloc = .{
                    .name = decl.name,
                    .ty = decl.ty,
                    .mutable = true,
                    .init = init,
                },
            },
        });
        try context.mutable_locals.put(decl.name, decl.ty);
    }

    fn lowerAssign(
        self: *FunctionLowerer,
        block_index: usize,
        assignment: hir.Assign,
        source_line: ?u32,
        source_column: ?u32,
        context: *LowerContext,
    ) anyerror!void {
        const target_place = try self.lowerPlace(block_index, assignment.target, context);
        const value = if (assignment.operator == .assign) blk: {
            break :blk try self.lowerValue(block_index, assignment.value, null, context);
        } else blk: {
            const current_value = try self.emitInstructionValue(
                block_index,
                try self.freshResult(assignment.target.ty, null),
                source_line,
                source_column,
                .{ .load = target_place },
            );
            const rhs = try self.lowerValue(block_index, assignment.value, null, context);
            break :blk try self.emitInstructionValue(
                block_index,
                try self.freshResult(assignment.target.ty, null),
                source_line,
                source_column,
                .{
                    .binary = .{
                        .operator = compoundOperator(assignment.operator),
                        .lhs = current_value,
                        .rhs = rhs,
                    },
                },
            );
        };

        try self.blocks.items[block_index].instructions.append(self.allocator, .{
            .source_line = source_line,
            .source_column = source_column,
            .data = .{
                .store = .{
                    .target = target_place,
                    .value = value,
                },
            },
        });
    }

    fn lowerExprStatement(
        self: *FunctionLowerer,
        block_index: usize,
        expr: *const hir.Expr,
        context: *LowerContext,
    ) anyerror!void {
        if (expr.data == .call) {
            _ = try self.lowerCall(block_index, expr, null, context);
            return;
        }
        _ = try self.lowerValue(block_index, expr, null, context);
    }

    fn lowerIf(
        self: *FunctionLowerer,
        current: usize,
        statement: hir.Statement,
        context: *LowerContext,
    ) anyerror!usize {
        const then_index = try self.newBlock("if_then", statement.source_line, statement.source_column);
        const else_index = try self.newBlock("if_else", statement.source_line, statement.source_column);
        const merge_index = try self.newBlock("if_merge", statement.source_line, statement.source_column);
        const if_stmt = statement.data.if_stmt;

        self.blocks.items[current].source_line = statement.source_line;
        self.blocks.items[current].source_column = statement.source_column;
        self.blocks.items[current].terminator = .{
            .if_term = .{
                .condition = try self.lowerValue(current, if_stmt.condition, null, context),
                .then_block = self.blocks.items[then_index].label,
                .else_block = self.blocks.items[else_index].label,
                .merge_block = self.blocks.items[merge_index].label,
            },
        };

        var then_context = try context.clone(self.allocator);
        defer then_context.deinit();
        const then_end = try self.lowerStatements(then_index, if_stmt.then_body, &then_context);
        self.ensureJumpToMerge(then_end, merge_index);

        var else_context = try context.clone(self.allocator);
        defer else_context.deinit();
        const else_end = try self.lowerStatements(else_index, if_stmt.else_body, &else_context);
        self.ensureJumpToMerge(else_end, merge_index);

        return merge_index;
    }

    fn lowerSwitch(
        self: *FunctionLowerer,
        current: usize,
        statement: hir.Statement,
        context: *LowerContext,
    ) anyerror!usize {
        const switch_stmt = statement.data.switch_stmt;
        const merge_index = try self.newBlock("switch_merge", statement.source_line, statement.source_column);
        const default_index = try self.newBlock("switch_default", statement.source_line, statement.source_column);

        var cases = std.ArrayListUnmanaged(mir.SwitchTarget){};
        defer cases.deinit(self.allocator);

        for (switch_stmt.cases) |case_stmt| {
            const case_index = try self.newBlock("switch_case", case_stmt.source_line, case_stmt.source_column);
            try cases.append(self.allocator, .{
                .value = case_stmt.value,
                .block = self.blocks.items[case_index].label,
                .source_line = case_stmt.source_line,
                .source_column = case_stmt.source_column,
            });

            var case_context = try context.clone(self.allocator);
            defer case_context.deinit();
            const case_end = try self.lowerStatements(case_index, case_stmt.body, &case_context);
            self.ensureJumpToMerge(case_end, merge_index);
        }

        var default_context = try context.clone(self.allocator);
        defer default_context.deinit();
        const default_end = try self.lowerStatements(default_index, switch_stmt.default_body, &default_context);
        self.ensureJumpToMerge(default_end, merge_index);

        self.blocks.items[current].source_line = statement.source_line;
        self.blocks.items[current].source_column = statement.source_column;
        self.blocks.items[current].terminator = .{
            .switch_term = .{
                .selector = try self.lowerValue(current, switch_stmt.selector, null, context),
                .cases = try cases.toOwnedSlice(self.allocator),
                .default_block = self.blocks.items[default_index].label,
                .merge_block = self.blocks.items[merge_index].label,
            },
        };

        return merge_index;
    }

    fn ensureJumpToMerge(self: *FunctionLowerer, block_index: usize, merge_index: usize) void {
        if (self.blocks.items[block_index].terminator == .none) {
            self.blocks.items[block_index].terminator = .{
                .jump = self.blocks.items[merge_index].label,
            };
        }
    }

    fn lowerValue(
        self: *FunctionLowerer,
        block_index: usize,
        expr: *const hir.Expr,
        preferred_name: ?[]const u8,
        context: *LowerContext,
    ) anyerror!*mir.Value {
        switch (expr.data) {
            .integer => |value| {
                const immediate = try self.makeImmediateValue(.{ .integer = value }, expr.ty, expr.source_line, expr.source_column);
                if (preferred_name) |name| {
                    return try self.emitInstructionValue(
                        block_index,
                        .{ .name = name, .ty = expr.ty },
                        expr.source_line,
                        expr.source_column,
                        .{ .copy = .{ .value = immediate } },
                    );
                }
                return immediate;
            },
            .float => |value| {
                const immediate = try self.makeImmediateValue(.{ .float = value }, expr.ty, expr.source_line, expr.source_column);
                if (preferred_name) |name| {
                    return try self.emitInstructionValue(
                        block_index,
                        .{ .name = name, .ty = expr.ty },
                        expr.source_line,
                        expr.source_column,
                        .{ .copy = .{ .value = immediate } },
                    );
                }
                return immediate;
            },
            .bool => |value| {
                const immediate = try self.makeImmediateValue(.{ .bool = value }, expr.ty, expr.source_line, expr.source_column);
                if (preferred_name) |name| {
                    return try self.emitInstructionValue(
                        block_index,
                        .{ .name = name, .ty = expr.ty },
                        expr.source_line,
                        expr.source_column,
                        .{ .copy = .{ .value = immediate } },
                    );
                }
                return immediate;
            },
            .identifier => |name| {
                if (context.immutable_values.get(name)) |value| {
                    if (preferred_name) |preferred| {
                        return try self.emitInstructionValue(
                            block_index,
                            .{ .name = preferred, .ty = expr.ty },
                            expr.source_line,
                            expr.source_column,
                            .{ .copy = .{ .value = value } },
                        );
                    }
                    return value;
                }
                if (context.mutable_locals.get(name) != null) {
                    const place = try self.makeIdentifierPlace(name, expr.ty, expr.source_line, expr.source_column);
                    return try self.emitInstructionValue(
                        block_index,
                        try self.freshResult(expr.ty, preferred_name),
                        expr.source_line,
                        expr.source_column,
                        .{ .load = place },
                    );
                }

                const value = try self.makeIdentifierValue(expr.ty, name, expr.source_line, expr.source_column);
                if (preferred_name) |preferred| {
                    return try self.emitInstructionValue(
                        block_index,
                        .{ .name = preferred, .ty = expr.ty },
                        expr.source_line,
                        expr.source_column,
                        .{ .copy = .{ .value = value } },
                    );
                }
                return value;
            },
            .unary => |unary| {
                const operand = try self.lowerValue(block_index, unary.operand, null, context);
                return try self.emitInstructionValue(
                    block_index,
                    try self.freshResult(expr.ty, preferred_name),
                    expr.source_line,
                    expr.source_column,
                    .{
                        .unary = .{
                            .operator = unary.operator,
                            .operand = operand,
                        },
                    },
                );
            },
            .binary => |binary| {
                const lhs = try self.lowerValue(block_index, binary.lhs, null, context);
                const rhs = try self.lowerValue(block_index, binary.rhs, null, context);
                return try self.emitInstructionValue(
                    block_index,
                    try self.freshResult(expr.ty, preferred_name),
                    expr.source_line,
                    expr.source_column,
                    .{
                        .binary = .{
                            .operator = binary.operator,
                            .lhs = lhs,
                            .rhs = rhs,
                        },
                    },
                );
            },
            .call => {
                return try self.lowerCall(block_index, expr, preferred_name, context);
            },
            .field => |field| {
                const target = try self.lowerValue(block_index, field.target, null, context);
                return try self.emitInstructionValue(
                    block_index,
                    try self.freshResult(expr.ty, preferred_name),
                    expr.source_line,
                    expr.source_column,
                    .{
                        .field = .{
                            .target = target,
                            .name = field.name,
                        },
                    },
                );
            },
            .index => |index_expr| {
                const target = try self.lowerValue(block_index, index_expr.target, null, context);
                const index = try self.lowerValue(block_index, index_expr.index, null, context);
                return try self.emitInstructionValue(
                    block_index,
                    try self.freshResult(expr.ty, preferred_name),
                    expr.source_line,
                    expr.source_column,
                    .{
                        .index = .{
                            .target = target,
                            .index = index,
                        },
                    },
                );
            },
        }
    }

    fn lowerCall(
        self: *FunctionLowerer,
        block_index: usize,
        expr: *const hir.Expr,
        preferred_name: ?[]const u8,
        context: *LowerContext,
    ) anyerror!*mir.Value {
        const call = expr.data.call;
        const args = try self.allocator.alloc(*mir.Value, call.args.len);
        for (call.args, 0..) |arg, index| {
            args[index] = try self.lowerValue(block_index, arg, null, context);
        }

        const result = if (preferred_name) |name|
            mir.Instruction.Result{ .name = name, .ty = expr.ty }
        else
            try self.freshResult(expr.ty, null);

        return try self.emitInstructionValue(
            block_index,
            result,
            expr.source_line,
            expr.source_column,
            .{
                .call = .{
                    .name = call.name,
                    .args = args,
                },
            },
        );
    }

    fn lowerPlace(
        self: *FunctionLowerer,
        block_index: usize,
        expr: *const hir.Expr,
        context: *LowerContext,
    ) anyerror!*mir.Place {
        const place = try self.allocator.create(mir.Place);
        place.* = .{
            .ty = expr.ty,
            .source_line = expr.source_line,
            .source_column = expr.source_column,
            .data = switch (expr.data) {
                .identifier => |name| .{ .identifier = name },
                .field => |field| .{
                    .field = .{
                        .target = try self.lowerPlace(block_index, field.target, context),
                        .name = field.name,
                    },
                },
                .index => |index_expr| .{
                    .index = .{
                        .target = try self.lowerPlace(block_index, index_expr.target, context),
                        .index = try self.lowerValue(block_index, index_expr.index, null, context),
                    },
                },
                else => return error.InvalidAssignmentTarget,
            },
        };
        return place;
    }

    fn emitInstructionValue(
        self: *FunctionLowerer,
        block_index: usize,
        result: mir.Instruction.Result,
        source_line: ?u32,
        source_column: ?u32,
        data: mir.Instruction.Data,
    ) anyerror!*mir.Value {
        try self.blocks.items[block_index].instructions.append(self.allocator, .{
            .result = result,
            .source_line = source_line,
            .source_column = source_column,
            .data = data,
        });
        return try mir.resultValue(self.allocator, result, source_line, source_column);
    }

    fn freshResult(self: *FunctionLowerer, ty: types.Type, preferred_name: ?[]const u8) !mir.Instruction.Result {
        if (preferred_name) |name| {
            return .{ .name = name, .ty = ty };
        }
        const name = try std.fmt.allocPrint(self.allocator, "__ssa_{d}", .{self.next_value_id});
        self.next_value_id += 1;
        return .{ .name = name, .ty = ty };
    }

    fn makeImmediateValue(
        self: *FunctionLowerer,
        data: mir.Value.Data,
        ty: types.Type,
        source_line: ?u32,
        source_column: ?u32,
    ) !*mir.Value {
        const value = try self.allocator.create(mir.Value);
        value.* = .{
            .ty = ty,
            .source_line = source_line,
            .source_column = source_column,
            .data = data,
        };
        return value;
    }

    fn makeIdentifierValue(
        self: *FunctionLowerer,
        ty: types.Type,
        name: []const u8,
        source_line: ?u32,
        source_column: ?u32,
    ) !*mir.Value {
        return self.makeImmediateValue(.{ .identifier = name }, ty, source_line, source_column);
    }

    fn makeIdentifierPlace(
        self: *FunctionLowerer,
        name: []const u8,
        ty: types.Type,
        source_line: ?u32,
        source_column: ?u32,
    ) !*mir.Place {
        const place = try self.allocator.create(mir.Place);
        place.* = .{
            .ty = ty,
            .source_line = source_line,
            .source_column = source_column,
            .data = .{ .identifier = name },
        };
        return place;
    }
};

const LowerContext = struct {
    immutable_values: std.StringHashMap(*mir.Value),
    mutable_locals: std.StringHashMap(types.Type),

    fn init(allocator: std.mem.Allocator) LowerContext {
        return .{
            .immutable_values = std.StringHashMap(*mir.Value).init(allocator),
            .mutable_locals = std.StringHashMap(types.Type).init(allocator),
        };
    }

    fn clone(self: *const LowerContext, allocator: std.mem.Allocator) !LowerContext {
        var cloned = LowerContext.init(allocator);

        var immutable_it = self.immutable_values.iterator();
        while (immutable_it.next()) |entry| {
            try cloned.immutable_values.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var mutable_it = self.mutable_locals.iterator();
        while (mutable_it.next()) |entry| {
            try cloned.mutable_locals.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        return cloned;
    }

    fn deinit(self: *LowerContext) void {
        self.immutable_values.deinit();
        self.mutable_locals.deinit();
    }
};

const PendingBlock = struct {
    label: []const u8,
    instructions: std.ArrayListUnmanaged(mir.Instruction) = .{},
    terminator: mir.Terminator = .{ .none = {} },
    source_line: ?u32 = null,
    source_column: ?u32 = null,
};

fn compoundOperator(tag: token.TokenTag) token.TokenTag {
    return switch (tag) {
        .plus_assign => .plus,
        .minus_assign => .minus,
        .star_assign => .star,
        .slash_assign => .slash,
        else => .assign,
    };
}
