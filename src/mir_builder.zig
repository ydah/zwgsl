const std = @import("std");
const hir = @import("hir.zig");
const mir = @import("mir.zig");

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
    blocks: std.ArrayListUnmanaged(PendingBlock) = .{},

    fn lower(self: *FunctionLowerer, function: hir.Function) !mir.Function {
        defer self.deinit();

        const entry_index = try self.newBlock("entry", function.source_line, function.source_column);
        _ = try self.lowerStatements(entry_index, function.body);

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
        for (self.blocks.items) |*block| {
            block.instructions.deinit(self.allocator);
        }
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

    fn lowerStatements(self: *FunctionLowerer, start_block: usize, statements: []const hir.Statement) anyerror!usize {
        var current = start_block;
        for (statements) |statement| {
            current = switch (statement.data) {
                .var_decl => blk: {
                    try self.blocks.items[current].instructions.append(self.allocator, .{
                        .source_line = statement.source_line,
                        .source_column = statement.source_column,
                        .data = .{
                            .var_decl = .{
                                .name = statement.data.var_decl.name,
                                .ty = statement.data.var_decl.ty,
                                .mutable = statement.data.var_decl.mutable,
                                .value = if (statement.data.var_decl.value) |value| try self.lowerExpr(value) else null,
                            },
                        },
                    });
                    break :blk current;
                },
                .assign => blk: {
                    try self.blocks.items[current].instructions.append(self.allocator, .{
                        .source_line = statement.source_line,
                        .source_column = statement.source_column,
                        .data = .{
                            .assign = .{
                                .target = try self.lowerExpr(statement.data.assign.target),
                                .operator = statement.data.assign.operator,
                                .value = try self.lowerExpr(statement.data.assign.value),
                            },
                        },
                    });
                    break :blk current;
                },
                .expr => blk: {
                    try self.blocks.items[current].instructions.append(self.allocator, .{
                        .source_line = statement.source_line,
                        .source_column = statement.source_column,
                        .data = .{ .expr = try self.lowerExpr(statement.data.expr) },
                    });
                    break :blk current;
                },
                .return_stmt => blk: {
                    self.blocks.items[current].source_line = statement.source_line;
                    self.blocks.items[current].source_column = statement.source_column;
                    self.blocks.items[current].terminator = .{
                        .return_stmt = if (statement.data.return_stmt) |value| try self.lowerExpr(value) else null,
                    };
                    break :blk current;
                },
                .discard => blk: {
                    self.blocks.items[current].source_line = statement.source_line;
                    self.blocks.items[current].source_column = statement.source_column;
                    self.blocks.items[current].terminator = .{ .discard = {} };
                    break :blk current;
                },
                .if_stmt => try self.lowerIf(current, statement),
                .switch_stmt => try self.lowerSwitch(current, statement),
            };
        }
        return current;
    }

    fn lowerIf(self: *FunctionLowerer, current: usize, statement: hir.Statement) anyerror!usize {
        const then_index = try self.newBlock("if_then", statement.source_line, statement.source_column);
        const else_index = try self.newBlock("if_else", statement.source_line, statement.source_column);
        const merge_index = try self.newBlock("if_merge", statement.source_line, statement.source_column);
        const if_stmt = statement.data.if_stmt;

        self.blocks.items[current].source_line = statement.source_line;
        self.blocks.items[current].source_column = statement.source_column;
        self.blocks.items[current].terminator = .{
            .if_term = .{
                .condition = try self.lowerExpr(if_stmt.condition),
                .then_block = self.blocks.items[then_index].label,
                .else_block = self.blocks.items[else_index].label,
                .merge_block = self.blocks.items[merge_index].label,
            },
        };

        const then_end = try self.lowerStatements(then_index, if_stmt.then_body);
        self.ensureJumpToMerge(then_end, merge_index);

        const else_end = try self.lowerStatements(else_index, if_stmt.else_body);
        self.ensureJumpToMerge(else_end, merge_index);

        return merge_index;
    }

    fn lowerSwitch(self: *FunctionLowerer, current: usize, statement: hir.Statement) anyerror!usize {
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

            const case_end = try self.lowerStatements(case_index, case_stmt.body);
            self.ensureJumpToMerge(case_end, merge_index);
        }

        const default_end = try self.lowerStatements(default_index, switch_stmt.default_body);
        self.ensureJumpToMerge(default_end, merge_index);

        self.blocks.items[current].source_line = statement.source_line;
        self.blocks.items[current].source_column = statement.source_column;
        self.blocks.items[current].terminator = .{
            .switch_term = .{
                .selector = try self.lowerExpr(switch_stmt.selector),
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

    fn lowerExpr(self: *FunctionLowerer, expr: *const hir.Expr) anyerror!*mir.Expr {
        const lowered = try self.allocator.create(mir.Expr);
        lowered.* = .{
            .ty = expr.ty,
            .source_line = expr.source_line,
            .source_column = expr.source_column,
            .data = switch (expr.data) {
                .integer => |value| .{ .integer = value },
                .float => |value| .{ .float = value },
                .bool => |value| .{ .bool = value },
                .identifier => |name| .{ .identifier = name },
                .unary => |unary| .{
                    .unary = .{
                        .operator = unary.operator,
                        .operand = try self.lowerExpr(unary.operand),
                    },
                },
                .binary => |binary| .{
                    .binary = .{
                        .operator = binary.operator,
                        .lhs = try self.lowerExpr(binary.lhs),
                        .rhs = try self.lowerExpr(binary.rhs),
                    },
                },
                .call => |call| .{
                    .call = .{
                        .name = call.name,
                        .args = try self.lowerExprSlice(call.args),
                    },
                },
                .field => |field| .{
                    .field = .{
                        .target = try self.lowerExpr(field.target),
                        .name = field.name,
                    },
                },
                .index => |index_expr| .{
                    .index = .{
                        .target = try self.lowerExpr(index_expr.target),
                        .index = try self.lowerExpr(index_expr.index),
                    },
                },
            },
        };
        return lowered;
    }

    fn lowerExprSlice(self: *FunctionLowerer, exprs: []const *hir.Expr) anyerror![]const *mir.Expr {
        const lowered = try self.allocator.alloc(*mir.Expr, exprs.len);
        for (exprs, 0..) |expr, index| {
            lowered[index] = try self.lowerExpr(expr);
        }
        return lowered;
    }
};

const PendingBlock = struct {
    label: []const u8,
    instructions: std.ArrayListUnmanaged(mir.Instruction) = .{},
    terminator: mir.Terminator = .{ .none = {} },
    source_line: ?u32 = null,
    source_column: ?u32 = null,
};
