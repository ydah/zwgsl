const std = @import("std");
const hir = @import("hir.zig");
const mir = @import("mir.zig");
const token = @import("token.zig");
const types = @import("types.zig");

pub fn build(allocator: std.mem.Allocator, module: *hir.Module) !*mir.Module {
    var builder = Builder{
        .allocator = allocator,
        .function_index = FunctionIndex.init(allocator),
    };
    defer builder.function_index.deinit();
    return try builder.lowerModule(module);
}

const Builder = struct {
    allocator: std.mem.Allocator,
    function_index: FunctionIndex,

    fn lowerModule(self: *Builder, module: *hir.Module) !*mir.Module {
        try self.function_index.addFunctions(module.global_functions);
        for (module.entry_points) |entry_point| {
            try self.function_index.addFunctions(entry_point.functions);
        }

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
            .function_index = &self.function_index,
        };
        return try lowerer.lower(function);
    }
};

const FunctionIndex = struct {
    params_by_name: std.StringHashMap([]const hir.Param),

    fn init(allocator: std.mem.Allocator) FunctionIndex {
        return .{
            .params_by_name = std.StringHashMap([]const hir.Param).init(allocator),
        };
    }

    fn deinit(self: *FunctionIndex) void {
        self.params_by_name.deinit();
    }

    fn addFunctions(self: *FunctionIndex, functions: []const hir.Function) !void {
        for (functions) |function| {
            try self.params_by_name.put(function.name, function.params);
        }
    }

    fn params(self: *const FunctionIndex, name: []const u8) ?[]const hir.Param {
        return self.params_by_name.get(name);
    }
};

const FunctionLowerer = struct {
    allocator: std.mem.Allocator,
    function_index: *const FunctionIndex,
    next_block_id: usize = 0,
    next_value_id: usize = 0,
    blocks: std.ArrayListUnmanaged(PendingBlock) = .{},
    storage_locals: std.StringHashMap(void) = undefined,

    fn lower(self: *FunctionLowerer, function: hir.Function) !mir.Function {
        defer self.deinit();

        self.storage_locals = std.StringHashMap(void).init(self.allocator);
        defer self.storage_locals.deinit();
        try self.collectStorageLocals(function.body);

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
    ) anyerror!LoweredBlock {
        var current = start_block;
        for (statements) |statement| {
            const lowered = switch (statement.data) {
                .var_decl => blk: {
                    try self.lowerVarDecl(current, statement, context);
                    break :blk LoweredBlock{ .index = current };
                },
                .assign => blk: {
                    try self.lowerAssign(current, statement.data.assign, statement.source_line, statement.source_column, context);
                    break :blk LoweredBlock{ .index = current };
                },
                .expr => blk: {
                    try self.lowerExprStatement(current, statement.data.expr, context);
                    break :blk LoweredBlock{ .index = current };
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
                    break :blk LoweredBlock{
                        .index = current,
                        .reachable = false,
                    };
                },
                .discard => blk: {
                    self.blocks.items[current].source_line = statement.source_line;
                    self.blocks.items[current].source_column = statement.source_column;
                    self.blocks.items[current].terminator = .{ .discard = {} };
                    break :blk LoweredBlock{
                        .index = current,
                        .reachable = false,
                    };
                },
                .if_stmt => try self.lowerIf(current, statement, context),
                .switch_stmt => try self.lowerSwitch(current, statement, context),
            };
            current = lowered.index;
            if (!lowered.reachable) return lowered;
        }
        return .{ .index = current };
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

        if (!self.storage_locals.contains(decl.name) and decl.value != null) {
            const value = try self.lowerValue(block_index, decl.value.?, decl.name, context);
            try context.promoted_types.put(decl.name, decl.ty);
            try context.promoted_values.put(decl.name, value);
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
        try context.storage_values.put(decl.name, decl.ty);
    }

    fn lowerAssign(
        self: *FunctionLowerer,
        block_index: usize,
        assignment: hir.Assign,
        source_line: ?u32,
        source_column: ?u32,
        context: *LowerContext,
    ) anyerror!void {
        if (assignment.target.data == .identifier) {
            const name = assignment.target.data.identifier;
            if (context.promoted_types.get(name)) |_| {
                const value = if (assignment.operator == .assign) blk: {
                    break :blk try self.lowerValue(block_index, assignment.value, null, context);
                } else blk: {
                    const current_value = context.promoted_values.get(name) orelse return error.UnknownIdentifier;
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

                try context.promoted_values.put(name, value);
                return;
            }
        }

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
    ) anyerror!LoweredBlock {
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
        self.ensureJumpToMerge(then_end.index, then_end.reachable, merge_index);

        var else_context = try context.clone(self.allocator);
        defer else_context.deinit();
        const else_end = try self.lowerStatements(else_index, if_stmt.else_body, &else_context);
        self.ensureJumpToMerge(else_end.index, else_end.reachable, merge_index);

        const reachable = try self.mergePromotedLocals(
            merge_index,
            context,
            &.{
                .{
                    .reachable = then_end.reachable,
                    .predecessor_label = if (then_end.reachable) self.blocks.items[then_end.index].label else null,
                    .context = &then_context,
                },
                .{
                    .reachable = else_end.reachable,
                    .predecessor_label = if (else_end.reachable) self.blocks.items[else_end.index].label else null,
                    .context = &else_context,
                },
            },
            statement.source_line,
            statement.source_column,
        );

        return .{
            .index = merge_index,
            .reachable = reachable,
        };
    }

    fn lowerSwitch(
        self: *FunctionLowerer,
        current: usize,
        statement: hir.Statement,
        context: *LowerContext,
    ) anyerror!LoweredBlock {
        const switch_stmt = statement.data.switch_stmt;
        const merge_index = try self.newBlock("switch_merge", statement.source_line, statement.source_column);
        const default_index = try self.newBlock("switch_default", statement.source_line, statement.source_column);

        var cases = std.ArrayListUnmanaged(mir.SwitchTarget){};
        defer cases.deinit(self.allocator);
        var owned_branches = std.ArrayListUnmanaged(OwnedBranchMerge){};
        defer {
            for (owned_branches.items) |*branch| {
                branch.context.deinit();
            }
            owned_branches.deinit(self.allocator);
        }

        for (switch_stmt.cases) |case_stmt| {
            const case_index = try self.newBlock("switch_case", case_stmt.source_line, case_stmt.source_column);
            try cases.append(self.allocator, .{
                .value = case_stmt.value,
                .block = self.blocks.items[case_index].label,
                .source_line = case_stmt.source_line,
                .source_column = case_stmt.source_column,
            });

            var case_context = try context.clone(self.allocator);
            const case_end = try self.lowerStatements(case_index, case_stmt.body, &case_context);
            self.ensureJumpToMerge(case_end.index, case_end.reachable, merge_index);
            try owned_branches.append(self.allocator, .{
                .reachable = case_end.reachable,
                .predecessor_label = if (case_end.reachable) self.blocks.items[case_end.index].label else null,
                .context = case_context,
            });
        }

        var default_context = try context.clone(self.allocator);
        const default_end = try self.lowerStatements(default_index, switch_stmt.default_body, &default_context);
        self.ensureJumpToMerge(default_end.index, default_end.reachable, merge_index);
        try owned_branches.append(self.allocator, .{
            .reachable = default_end.reachable,
            .predecessor_label = if (default_end.reachable) self.blocks.items[default_end.index].label else null,
            .context = default_context,
        });

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

        var branches = try self.allocator.alloc(BranchMerge, owned_branches.items.len);
        defer self.allocator.free(branches);
        for (owned_branches.items, 0..) |*branch, index| {
            branches[index] = .{
                .reachable = branch.reachable,
                .predecessor_label = branch.predecessor_label,
                .context = &branch.context,
            };
        }

        const reachable = try self.mergePromotedLocals(
            merge_index,
            context,
            branches,
            statement.source_line,
            statement.source_column,
        );
        return .{
            .index = merge_index,
            .reachable = reachable,
        };
    }

    fn ensureJumpToMerge(self: *FunctionLowerer, block_index: usize, reachable: bool, merge_index: usize) void {
        if (!reachable) return;
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
                if (context.promoted_values.get(name)) |value| {
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
                if (context.storage_values.get(name) != null) {
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

    fn collectStorageLocals(self: *FunctionLowerer, statements: []const hir.Statement) !void {
        for (statements) |statement| {
            switch (statement.data) {
                .var_decl => |decl| {
                    if (decl.mutable and decl.value == null) {
                        try self.storage_locals.put(decl.name, {});
                    }
                    if (decl.value) |value| try self.collectStorageInExpr(value);
                },
                .assign => |assign| {
                    if (rootIdentifier(assign.target)) |name| {
                        if (assign.target.data != .identifier) {
                            try self.storage_locals.put(name, {});
                        }
                    }
                    try self.collectStorageInExpr(assign.target);
                    try self.collectStorageInExpr(assign.value);
                },
                .expr => |expr| try self.collectStorageInExpr(expr),
                .if_stmt => |if_stmt| {
                    try self.collectStorageInExpr(if_stmt.condition);
                    try self.collectStorageLocals(if_stmt.then_body);
                    try self.collectStorageLocals(if_stmt.else_body);
                },
                .switch_stmt => |switch_stmt| {
                    try self.collectStorageInExpr(switch_stmt.selector);
                    for (switch_stmt.cases) |case_stmt| {
                        try self.collectStorageLocals(case_stmt.body);
                    }
                    try self.collectStorageLocals(switch_stmt.default_body);
                },
                .return_stmt => |value| if (value) |expr| try self.collectStorageInExpr(expr),
                .discard => {},
            }
        }
    }

    fn collectStorageInExpr(self: *FunctionLowerer, expr: *const hir.Expr) !void {
        switch (expr.data) {
            .integer, .float, .bool, .identifier => {},
            .unary => |unary| try self.collectStorageInExpr(unary.operand),
            .binary => |binary| {
                try self.collectStorageInExpr(binary.lhs);
                try self.collectStorageInExpr(binary.rhs);
            },
            .call => |call| {
                if (self.function_index.params(call.name)) |params| {
                    for (call.args, 0..) |arg, index| {
                        if (index < params.len and params[index].is_inout) {
                            if (rootIdentifier(arg)) |name| {
                                try self.storage_locals.put(name, {});
                            }
                        }
                    }
                }
                for (call.args) |arg| {
                    try self.collectStorageInExpr(arg);
                }
            },
            .field => |field| try self.collectStorageInExpr(field.target),
            .index => |index_expr| {
                try self.collectStorageInExpr(index_expr.target);
                try self.collectStorageInExpr(index_expr.index);
            },
        }
    }

    fn mergePromotedLocals(
        self: *FunctionLowerer,
        merge_index: usize,
        context: *LowerContext,
        branches: []const BranchMerge,
        source_line: ?u32,
        source_column: ?u32,
    ) anyerror!bool {
        var names = std.ArrayListUnmanaged([]const u8){};
        defer names.deinit(self.allocator);

        var name_it = context.promoted_types.iterator();
        while (name_it.next()) |entry| {
            try names.append(self.allocator, entry.key_ptr.*);
        }

        var any_reachable = false;
        for (names.items) |name| {
            const ty = context.promoted_types.get(name).?;
            var first_value: ?*mir.Value = null;
            var need_phi = false;
            var reachable_count: usize = 0;
            for (branches) |branch| {
                if (!branch.reachable) continue;
                any_reachable = true;
                reachable_count += 1;
                const branch_value = branch.context.promoted_values.get(name) orelse continue;
                if (first_value == null) {
                    first_value = branch_value;
                    continue;
                }
                if (!sameValue(first_value.?, branch_value)) {
                    need_phi = true;
                }
            }

            const merged_value = if (reachable_count == 0)
                context.promoted_values.get(name) orelse continue
            else if (!need_phi)
                first_value.?
            else blk: {
                const incomings = try self.allocator.alloc(mir.PhiIncoming, reachable_count);
                var incoming_index: usize = 0;
                for (branches) |branch| {
                    if (!branch.reachable) continue;
                    incomings[incoming_index] = .{
                        .label = branch.predecessor_label.?,
                        .value = branch.context.promoted_values.get(name).?,
                    };
                    incoming_index += 1;
                }
                break :blk try self.emitPhiValue(
                    merge_index,
                    try self.freshResult(ty, null),
                    source_line,
                    source_column,
                    incomings,
                );
            };

            try context.promoted_values.put(name, merged_value);
        }

        return any_reachable;
    }

    fn emitPhiValue(
        self: *FunctionLowerer,
        block_index: usize,
        result: mir.Instruction.Result,
        source_line: ?u32,
        source_column: ?u32,
        incomings: []const mir.PhiIncoming,
    ) anyerror!*mir.Value {
        try self.blocks.items[block_index].instructions.append(self.allocator, .{
            .result = result,
            .source_line = source_line,
            .source_column = source_column,
            .data = .{
                .phi = .{
                    .incomings = incomings,
                },
            },
        });
        return try mir.resultValue(self.allocator, result, source_line, source_column);
    }
};

const BranchMerge = struct {
    reachable: bool,
    predecessor_label: ?[]const u8,
    context: *const LowerContext,
};

const OwnedBranchMerge = struct {
    reachable: bool,
    predecessor_label: ?[]const u8,
    context: LowerContext,
};

fn rootIdentifier(expr: *const hir.Expr) ?[]const u8 {
    return switch (expr.data) {
        .identifier => expr.data.identifier,
        .field => |field| rootIdentifier(field.target),
        .index => |index_expr| rootIdentifier(index_expr.target),
        else => null,
    };
}

fn sameValue(lhs: *const mir.Value, rhs: *const mir.Value) bool {
    if (lhs == rhs) return true;
    if (!lhs.ty.eql(rhs.ty)) return false;
    return switch (lhs.data) {
        .integer => rhs.data == .integer and lhs.data.integer == rhs.data.integer,
        .float => rhs.data == .float and lhs.data.float == rhs.data.float,
        .bool => rhs.data == .bool and lhs.data.bool == rhs.data.bool,
        .identifier => rhs.data == .identifier and std.mem.eql(u8, lhs.data.identifier, rhs.data.identifier),
    };
}

const LowerContext = struct {
    immutable_values: std.StringHashMap(*mir.Value),
    promoted_values: std.StringHashMap(*mir.Value),
    promoted_types: std.StringHashMap(types.Type),
    storage_values: std.StringHashMap(types.Type),

    fn init(allocator: std.mem.Allocator) LowerContext {
        return .{
            .immutable_values = std.StringHashMap(*mir.Value).init(allocator),
            .promoted_values = std.StringHashMap(*mir.Value).init(allocator),
            .promoted_types = std.StringHashMap(types.Type).init(allocator),
            .storage_values = std.StringHashMap(types.Type).init(allocator),
        };
    }

    fn clone(self: *const LowerContext, allocator: std.mem.Allocator) !LowerContext {
        var cloned = LowerContext.init(allocator);

        var immutable_it = self.immutable_values.iterator();
        while (immutable_it.next()) |entry| {
            try cloned.immutable_values.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var promoted_value_it = self.promoted_values.iterator();
        while (promoted_value_it.next()) |entry| {
            try cloned.promoted_values.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var promoted_type_it = self.promoted_types.iterator();
        while (promoted_type_it.next()) |entry| {
            try cloned.promoted_types.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var storage_it = self.storage_values.iterator();
        while (storage_it.next()) |entry| {
            try cloned.storage_values.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        return cloned;
    }

    fn deinit(self: *LowerContext) void {
        self.immutable_values.deinit();
        self.promoted_values.deinit();
        self.promoted_types.deinit();
        self.storage_values.deinit();
    }
};

const PendingBlock = struct {
    label: []const u8,
    instructions: std.ArrayListUnmanaged(mir.Instruction) = .{},
    terminator: mir.Terminator = .{ .none = {} },
    source_line: ?u32 = null,
    source_column: ?u32 = null,
};

const LoweredBlock = struct {
    index: usize,
    reachable: bool = true,
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
