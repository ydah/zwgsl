const std = @import("std");
const ast = @import("ast.zig");
const builtins = @import("builtins.zig");
const ir = @import("ir.zig");
const sema = @import("sema.zig");
const types = @import("types.zig");
const unify = @import("unify.zig");

pub fn build(allocator: std.mem.Allocator, typed: *sema.TypedProgram) anyerror!*ir.Module {
    var builder = Builder{
        .allocator = allocator,
        .typed = typed,
        .lowered_specializations = std.StringHashMap(void).init(allocator),
    };
    return try builder.run();
}

const Builder = struct {
    allocator: std.mem.Allocator,
    typed: *sema.TypedProgram,
    lowered_globals: std.ArrayListUnmanaged(ir.Function) = .{},
    lowered_specializations: std.StringHashMap(void),
    match_helper_index: usize = 0,

    fn run(self: *Builder) anyerror!*ir.Module {
        const module = try self.allocator.create(ir.Module);
        module.* = .{};
        defer self.lowered_globals.deinit(self.allocator);
        defer self.lowered_specializations.deinit();

        module.version = self.findVersion();
        module.uniforms = try self.collectUniforms();
        module.structs = try self.collectStructs();
        try self.lowerAdtConstructors();
        try self.lowerGlobalFunctions();
        try self.lowerImplMethods();
        if (self.typed.vertex_block) |block| {
            module.vertex = try self.lowerStage(block, self.typed.vertex_functions);
        }
        if (self.typed.fragment_block) |block| {
            module.fragment = try self.lowerStage(block, self.typed.fragment_functions);
        }
        if (self.typed.compute_block) |block| {
            module.compute = try self.lowerStage(block, self.typed.compute_functions);
        }
        module.global_functions = try self.lowered_globals.toOwnedSlice(self.allocator);

        return module;
    }

    fn findVersion(self: *Builder) []const u8 {
        for (self.typed.program.items) |item| {
            if (item == .version) return item.version.value;
        }
        return "300 es";
    }

    fn collectUniforms(self: *Builder) anyerror![]const ir.Global {
        var items = std.ArrayListUnmanaged(ir.Global){};
        defer items.deinit(self.allocator);

        for (self.typed.program.items) |item| {
            if (item == .uniform) {
                try items.append(self.allocator, .{
                    .name = item.uniform.name,
                    .ty = types.fromName(item.uniform.type_name) orelse .{ .struct_type = item.uniform.type_name },
                    .source_line = item.uniform.position.line,
                    .source_column = item.uniform.position.column,
                });
            }
        }

        return try items.toOwnedSlice(self.allocator);
    }

    fn collectStructs(self: *Builder) anyerror![]const ir.StructDecl {
        var items = std.ArrayListUnmanaged(ir.StructDecl){};
        defer items.deinit(self.allocator);

        for (self.typed.program.items) |item| {
            if (item == .struct_def) {
                var fields = std.ArrayListUnmanaged(ir.StructField){};
                defer fields.deinit(self.allocator);
                for (item.struct_def.fields) |field| {
                    try fields.append(self.allocator, .{
                        .name = field.name,
                        .ty = types.fromName(field.type_name) orelse .{ .struct_type = field.type_name },
                        .source_line = field.position.line,
                        .source_column = field.position.column,
                    });
                }
                try items.append(self.allocator, .{
                    .name = item.struct_def.name,
                    .fields = try fields.toOwnedSlice(self.allocator),
                    .source_line = item.struct_def.position.line,
                    .source_column = item.struct_def.position.column,
                });
            }
        }

        for (self.typed.program.items) |item| {
            if (item != .type_def) continue;
            const type_info = self.typed.typeDef(item.type_def.name) orelse continue;
            if (type_info.params.len > 0) continue;

            var fields = std.ArrayListUnmanaged(ir.StructField){};
            defer fields.deinit(self.allocator);

            try fields.append(self.allocator, .{
                .name = "tag",
                .ty = types.builtinType(.int),
            });
            for (type_info.variants) |variant| {
                for (variant.field_names, variant.field_types, 0..) |field_name, field_type, index| {
                    try fields.append(self.allocator, .{
                        .name = try self.adtFieldName(variant.name, field_name, index),
                        .ty = field_type,
                    });
                }
            }

            try items.append(self.allocator, .{
                .name = type_info.name,
                .fields = try fields.toOwnedSlice(self.allocator),
                .source_line = item.type_def.position.line,
                .source_column = item.type_def.position.column,
            });
        }

        return try items.toOwnedSlice(self.allocator);
    }

    fn lowerAdtConstructors(self: *Builder) anyerror!void {
        for (self.typed.program.items) |item| {
            if (item != .type_def) continue;
            for (item.type_def.variants) |variant| {
                const info = self.typed.constructor(variant.name) orelse continue;
                if (containsTypeVar(info.return_type)) continue;

                var params = std.ArrayListUnmanaged(ir.Param){};
                defer params.deinit(self.allocator);
                var body = std.ArrayListUnmanaged(ir.Statement){};
                defer body.deinit(self.allocator);

                const result_name = "__result";
                try body.append(self.allocator, self.makeStatementAt(null, .{
                    .var_decl = .{
                        .name = result_name,
                        .ty = info.return_type,
                        .mutable = true,
                        .value = null,
                    },
                }));
                try body.append(self.allocator, self.makeStatementAt(variant.position, .{
                    .assign = .{
                        .target = try self.makeExprAt(variant.position, types.builtinType(.int), .{
                            .field = .{
                                .target = try self.makeExprAt(variant.position, info.return_type, .{ .identifier = result_name }),
                                .name = "tag",
                            },
                        }),
                        .operator = .assign,
                        .value = try self.makeExprAt(variant.position, types.builtinType(.int), .{ .integer = @as(i64, @intCast(info.tag)) }),
                    },
                }));

                for (info.field_names, info.field_types, 0..) |field_name, field_type, index| {
                    const param_name = try std.fmt.allocPrint(self.allocator, "arg_{d}", .{index});
                    try params.append(self.allocator, .{
                        .name = param_name,
                        .ty = field_type,
                        .is_inout = false,
                        .source_line = variant.position.line,
                        .source_column = variant.position.column,
                    });
                    try body.append(self.allocator, self.makeStatementAt(variant.position, .{
                        .assign = .{
                            .target = try self.makeExprAt(variant.position, field_type, .{
                                .field = .{
                                    .target = try self.makeExprAt(variant.position, info.return_type, .{ .identifier = result_name }),
                                    .name = try self.adtFieldName(info.name, field_name, index),
                                },
                            }),
                            .operator = .assign,
                            .value = try self.makeExprAt(variant.position, field_type, .{ .identifier = param_name }),
                        },
                    }));
                }

                try body.append(self.allocator, self.makeStatementAt(variant.position, .{
                    .return_stmt = try self.makeExprAt(variant.position, info.return_type, .{ .identifier = result_name }),
                }));

                try self.lowered_globals.append(self.allocator, .{
                    .name = info.name,
                    .return_type = info.return_type,
                    .params = try params.toOwnedSlice(self.allocator),
                    .body = try body.toOwnedSlice(self.allocator),
                    .stage = null,
                    .source_line = variant.position.line,
                    .source_column = variant.position.column,
                });
            }
        }
    }

    fn lowerStage(self: *Builder, block: *ast.ShaderBlock, functions: []const *ast.FunctionDef) anyerror!ir.Stage {
        var inputs = std.ArrayListUnmanaged(ir.Global){};
        var outputs = std.ArrayListUnmanaged(ir.Global){};
        var varyings = std.ArrayListUnmanaged(ir.Global){};
        defer inputs.deinit(self.allocator);
        defer outputs.deinit(self.allocator);
        defer varyings.deinit(self.allocator);

        var precision: ?[]const u8 = self.findPrecision(block.stage);

        for (block.items) |item| {
            switch (item) {
                .input => |decl| try inputs.append(self.allocator, try self.lowerIo(decl)),
                .output => |decl| try outputs.append(self.allocator, try self.lowerIo(decl)),
                .varying => |decl| try varyings.append(self.allocator, try self.lowerIo(decl)),
                .precision => |decl| if (std.mem.eql(u8, decl.stage, stageName(block.stage))) {
                    precision = decl.precision;
                },
                else => {},
            }
        }

        const input_slice = try inputs.toOwnedSlice(self.allocator);
        const output_slice = try outputs.toOwnedSlice(self.allocator);
        const varying_slice = try varyings.toOwnedSlice(self.allocator);
        const stage_io = [3][]const ir.Global{ input_slice, output_slice, varying_slice };

        return .{
            .stage = block.stage,
            .precision = precision,
            .inputs = input_slice,
            .outputs = output_slice,
            .varyings = varying_slice,
            .functions = try self.lowerFunctions(functions, block.stage, &stage_io),
            .source_line = block.position.line,
            .source_column = block.position.column,
        };
    }

    fn lowerGlobalFunctions(self: *Builder) anyerror!void {
        for (self.typed.global_functions) |function| {
            if (self.functionNeedsSpecialization(function)) continue;
            try self.lowered_globals.append(self.allocator, try self.lowerFunction(function, null, null));
        }
    }

    fn lowerImplMethods(self: *Builder) anyerror!void {
        for (self.typed.traits.impls.items) |impl_info| {
            for (impl_info.methods) |method| {
                try self.lowered_globals.append(
                    self.allocator,
                    try self.lowerFunctionWithOptions(method.function, null, null, .{
                        .name = method.mangled_name,
                        .self_type = impl_info.for_type,
                    }),
                );
            }
        }
    }

    fn lowerFunctions(
        self: *Builder,
        functions: []const *ast.FunctionDef,
        stage: ?ast.Stage,
        stage_io_sets: ?*const [3][]const ir.Global,
    ) anyerror![]const ir.Function {
        var lowered = std.ArrayListUnmanaged(ir.Function){};
        defer lowered.deinit(self.allocator);

        for (functions) |function| {
            if (self.functionNeedsSpecialization(function)) continue;
            try lowered.append(self.allocator, try self.lowerFunction(function, stage, stage_io_sets));
        }

        return try lowered.toOwnedSlice(self.allocator);
    }

    fn lowerFunction(
        self: *Builder,
        function: *ast.FunctionDef,
        stage: ?ast.Stage,
        stage_io_sets: ?*const [3][]const ir.Global,
    ) anyerror!ir.Function {
        return self.lowerFunctionWithOptions(function, stage, stage_io_sets, .{});
    }

    fn lowerFunctionWithOptions(
        self: *Builder,
        function: *ast.FunctionDef,
        stage: ?ast.Stage,
        stage_io_sets: ?*const [3][]const ir.Global,
        options: LowerOptions,
    ) anyerror!ir.Function {
        const signature = self.typed.functionSignature(function).?;

        var params = std.ArrayListUnmanaged(ir.Param){};
        defer params.deinit(self.allocator);
        var context = FunctionContext.init(self.allocator);
        defer context.deinit();
        context.stage = stage;
        context.stage_functions = if (stage) |resolved_stage| self.stageFunctionSlice(resolved_stage) else &.{};
        context.substitution = options.substitution;
        context.self_type = options.self_type;

        for (signature.params, 0..) |param, index| {
            const param_type = try self.applyType(param.ty, &context);
            const param_position = if (index < function.params.len) function.params[index].position else function.position;
            try params.append(self.allocator, .{
                .name = param.name,
                .ty = param_type,
                .is_inout = param.is_inout,
                .source_line = param_position.line,
                .source_column = param_position.column,
            });
            try context.locals.put(param.name, param_type);
        }

        try self.registerUniforms(&context);
        if (stage_io_sets) |sets| {
            for (sets[0]) |decl| try context.nonlocals.put(decl.name, {});
            for (sets[1]) |decl| try context.nonlocals.put(decl.name, {});
            for (sets[2]) |decl| try context.nonlocals.put(decl.name, {});
        }
        if (stage == .vertex) try context.nonlocals.put("gl_Position", {});
        if (stage == .compute) {
            try context.nonlocals.put("global_invocation_id", {});
            try context.nonlocals.put("local_invocation_id", {});
            try context.nonlocals.put("workgroup_id", {});
            try context.nonlocals.put("num_workgroups", {});
            try context.nonlocals.put("local_invocation_index", {});
        }

        var lowered_statements = std.ArrayListUnmanaged(ir.Statement){};
        defer lowered_statements.deinit(self.allocator);

        for (self.typed.whereBindings(function)) |binding| {
            try self.appendLocalBinding(
                &lowered_statements,
                binding.*.position,
                binding.*.name,
                binding.*.value,
                false,
                &context,
            );
        }

        const body = try self.lowerStatementList(function.body, &context);
        for (body) |statement| {
            try lowered_statements.append(self.allocator, statement);
        }

        const lowered_body = try lowered_statements.toOwnedSlice(self.allocator);
        var final_body = lowered_body;
        const return_type = try self.applyType(signature.return_type, &context);
        if (!return_type.isVoid() and lowered_body.len > 0 and lowered_body[lowered_body.len - 1].data == .expr) {
            var replaced = try self.allocator.dupe(ir.Statement, lowered_body);
            replaced[replaced.len - 1] = Builder.makeStatementWithColumn(
                lowered_body[lowered_body.len - 1].source_line,
                lowered_body[lowered_body.len - 1].source_column,
                .{
                    .return_stmt = lowered_body[lowered_body.len - 1].data.expr,
                },
            );
            final_body = replaced;
        }

        return .{
            .name = options.name orelse function.name,
            .return_type = return_type,
            .params = try params.toOwnedSlice(self.allocator),
            .body = final_body,
            .stage = stage,
            .source_line = function.position.line,
            .source_column = function.position.column,
        };
    }

    fn lowerStatementList(self: *Builder, statements: []const *ast.Stmt, context: *FunctionContext) anyerror![]const ir.Statement {
        var items = std.ArrayListUnmanaged(ir.Statement){};
        defer items.deinit(self.allocator);

        for (statements) |statement| {
            try self.lowerStmtInto(&items, statement, context);
        }

        return try items.toOwnedSlice(self.allocator);
    }

    fn lowerStmtInto(
        self: *Builder,
        list: *std.ArrayListUnmanaged(ir.Statement),
        statement: *ast.Stmt,
        context: *FunctionContext,
    ) anyerror!void {
        switch (statement.data) {
            .expression => |expr| {
                try list.append(self.allocator, self.makeStatementAt(statement.position, .{
                    .expr = try self.lowerExpr(expr, context),
                }));
            },
            .let_binding => |binding| {
                try self.appendLocalBinding(
                    list,
                    statement.position,
                    binding.name,
                    binding.value,
                    false,
                    context,
                );
            },
            .typed_assignment => |typed_assignment| {
                try self.appendLocalBinding(
                    list,
                    statement.position,
                    typed_assignment.name,
                    typed_assignment.value,
                    true,
                    context,
                );
            },
            .assignment => |assignment| {
                if (assignment.target.data == .identifier and assignment.operator == .assign) {
                    const name = assignment.target.data.identifier;
                    if (!context.locals.contains(name) and !context.nonlocals.contains(name)) {
                        const value = try self.lowerExpr(assignment.value, context);
                        const ty = try self.resolvedExprType(assignment.value, context);
                        try context.locals.put(name, ty);
                        try list.append(self.allocator, self.makeStatementAt(statement.position, .{
                            .var_decl = .{
                                .name = name,
                                .ty = ty,
                                .mutable = true,
                                .value = value,
                            },
                        }));
                        return;
                    }
                }

                try list.append(self.allocator, self.makeStatementAt(statement.position, .{
                    .assign = .{
                        .target = try self.lowerExpr(assignment.target, context),
                        .operator = assignment.operator,
                        .value = try self.lowerExpr(assignment.value, context),
                    },
                }));
            },
            .return_stmt => |value| {
                try list.append(self.allocator, self.makeStatementAt(statement.position, .{
                    .return_stmt = if (value) |expr| try self.lowerExpr(expr, context) else null,
                }));
            },
            .discard => try list.append(self.allocator, self.makeStatementAt(statement.position, .{ .discard = {} })),
            .conditional => |conditional| {
                const lowered_body = try self.lowerSingleStatementSlice(conditional.body, context);
                const condition = try self.lowerExpr(conditional.condition, context);
                const then_body = if (conditional.negate) &.{} else lowered_body;
                const else_body = if (conditional.negate) lowered_body else &.{};
                try list.append(self.allocator, self.makeStatementAt(statement.position, .{
                    .if_stmt = .{
                        .condition = condition,
                        .then_body = then_body,
                        .else_body = else_body,
                    },
                }));
            },
            .if_stmt => |if_stmt| try list.append(self.allocator, try self.lowerIf(if_stmt, context, 0)),
            .times_loop => |times_loop| {
                const count = self.resolveConstInt(times_loop.count, context) orelse return error.NonConstantLoop;
                var index: i64 = 0;
                while (index < count) : (index += 1) {
                    var nested = try context.clone(self.allocator);
                    defer nested.deinit();
                    if (times_loop.binding) |binding| {
                        try nested.loop_bindings.put(binding, .{ .const_int = index });
                    }
                    const body = try self.lowerStatementList(times_loop.body, &nested);
                    for (body) |lowered_stmt| {
                        try list.append(self.allocator, lowered_stmt);
                    }
                }
            },
            .each_loop => |each_loop| {
                const collection_type = try self.resolvedExprType(each_loop.collection, context);
                const vector_len = collection_type.vectorLen() orelse return error.UnsupportedLoop;
                const element_type = collection_type.componentType() orelse return error.UnsupportedLoop;

                var index: u8 = 0;
                while (index < vector_len) : (index += 1) {
                    var nested = try context.clone(self.allocator);
                    defer nested.deinit();
                    if (each_loop.binding) |binding| {
                        const collection = try self.lowerExpr(each_loop.collection, context);
                        const index_expr = try self.makeExprAt(statement.position, types.builtinType(.int), .{
                            .integer = index,
                        });
                        const element_expr = try self.makeExprAt(statement.position, element_type, .{
                            .index = .{
                                .target = collection,
                                .index = index_expr,
                            },
                        });
                        try nested.loop_bindings.put(binding, .{ .expr = element_expr });
                    }
                    const body = try self.lowerStatementList(each_loop.body, &nested);
                    for (body) |lowered_stmt| {
                        try list.append(self.allocator, lowered_stmt);
                    }
                }
            },
        }
    }

    fn appendLocalBinding(
        self: *Builder,
        list: *std.ArrayListUnmanaged(ir.Statement),
        position: ast.Position,
        name: []const u8,
        value_expr: *ast.Expr,
        mutable: bool,
        context: *FunctionContext,
    ) anyerror!void {
        const ty = try self.resolvedExprType(value_expr, context);
        try context.locals.put(name, ty);
        try list.append(self.allocator, self.makeStatementAt(position, .{
            .var_decl = .{
                .name = name,
                .ty = ty,
                .mutable = mutable,
                .value = try self.lowerExpr(value_expr, context),
            },
        }));
    }

    fn lowerSingleStatementSlice(self: *Builder, statement: *ast.Stmt, context: *FunctionContext) anyerror![]const ir.Statement {
        var nested = try context.clone(self.allocator);
        defer nested.deinit();
        var items = std.ArrayListUnmanaged(ir.Statement){};
        defer items.deinit(self.allocator);
        try self.lowerStmtInto(&items, statement, &nested);
        return try items.toOwnedSlice(self.allocator);
    }

    fn lowerIf(self: *Builder, if_stmt: ast.IfStmt, context: *FunctionContext, index: usize) anyerror!ir.Statement {
        var branch_context = try context.clone(self.allocator);
        defer branch_context.deinit();

        var condition = try self.lowerExpr(if_stmt.branches[index].condition, &branch_context);
        if (index == 0 and if_stmt.negate_first) {
            condition = try self.makeExprAt(if_stmt.branches[index].condition.position, types.builtinType(.bool), .{
                .unary = .{
                    .operator = .bang,
                    .operand = condition,
                },
            });
        }

        const then_body = try self.lowerStatementList(if_stmt.branches[index].body, &branch_context);
        const else_body = if (index + 1 < if_stmt.branches.len) blk: {
            const nested_if = try self.lowerIf(if_stmt, context, index + 1);
            const items = try self.allocator.alloc(ir.Statement, 1);
            items[0] = nested_if;
            break :blk items;
        } else try self.lowerStatementList(if_stmt.else_body, context);

        return self.makeStatementAt(if_stmt.branches[index].condition.position, .{
            .if_stmt = .{
                .condition = condition,
                .then_body = then_body,
                .else_body = else_body,
            },
        });
    }

    fn lowerExpr(self: *Builder, expr: *ast.Expr, context: *FunctionContext) anyerror!*ir.Expr {
        return switch (expr.data) {
            .integer => |value| self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{ .integer = value }),
            .float => |value| self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{ .float = value }),
            .bool => |value| self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{ .bool = value }),
            .symbol => |value| self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{ .integer = symbolId(value) }),
            .identifier => |name| blk: {
                if (context.loop_bindings.get(name)) |binding| {
                    break :blk switch (binding) {
                        .const_int => |value| try self.makeExprAt(expr.position, types.builtinType(.int), .{ .integer = value }),
                        .expr => |value| value,
                    };
                }
                break :blk try self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{ .identifier = name });
            },
            .self_ref => blk: {
                if (context.self_type != null) {
                    break :blk try self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{ .identifier = "self" });
                }
                return error.UnsupportedSelfReference;
            },
            .unary => |unary| self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{
                .unary = .{
                    .operator = unary.operator,
                    .operand = try self.lowerExpr(unary.operand, context),
                },
            }),
            .binary => |binary| self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{
                .binary = .{
                    .operator = binary.operator,
                    .lhs = try self.lowerExpr(binary.lhs, context),
                    .rhs = try self.lowerExpr(binary.rhs, context),
                },
            }),
            .member => |member| blk: {
                if (member.target.data == .self_ref) {
                    if (context.self_type != null) {
                        const self_expr = try self.makeExprAt(member.target.position, context.self_type.?, .{ .identifier = "self" });
                        const self_type = context.self_type.?;
                        if (types.isValidSwizzle(self_type, member.name) != null or self_type == .struct_type) {
                            break :blk try self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{
                                .field = .{
                                    .target = self_expr,
                                    .name = member.name,
                                },
                            });
                        }
                        if (builtins.resolveMethod(member.name, self_type, &.{})) |_| {
                            const args = try self.allocator.alloc(*ir.Expr, 1);
                            args[0] = self_expr;
                            break :blk try self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{
                                .call = .{
                                    .name = member.name,
                                    .args = args,
                                },
                            });
                        }
                    }
                    break :blk try self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{ .identifier = member.name });
                }

                const target_type = try self.resolvedExprType(member.target, context);
                if (types.isValidSwizzle(target_type, member.name) != null or target_type == .struct_type) {
                    break :blk try self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{
                        .field = .{
                            .target = try self.lowerExpr(member.target, context),
                            .name = member.name,
                        },
                    });
                }

                if (builtins.resolveMethod(member.name, target_type, &.{})) |_| {
                    const args = try self.allocator.alloc(*ir.Expr, 1);
                    args[0] = try self.lowerExpr(member.target, context);
                    break :blk try self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{
                        .call = .{
                            .name = member.name,
                            .args = args,
                        },
                    });
                }

                break :blk try self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{
                    .field = .{
                        .target = try self.lowerExpr(member.target, context),
                        .name = member.name,
                    },
                });
            },
            .call => |call| blk: {
                var args = std.ArrayListUnmanaged(*ir.Expr){};
                defer args.deinit(self.allocator);
                var arg_types = std.ArrayListUnmanaged(types.Type){};
                defer arg_types.deinit(self.allocator);

                for (call.args) |arg| {
                    try args.append(self.allocator, try self.lowerExpr(arg, context));
                    try arg_types.append(self.allocator, try self.resolvedExprType(arg, context));
                }

                switch (call.callee.data) {
                    .identifier => |name| {
                        break :blk try self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{
                            .call = .{
                                .name = try self.resolveUserCallName(name, arg_types.items, context),
                                .args = try args.toOwnedSlice(self.allocator),
                            },
                        });
                    },
                    .member => |member| {
                        const receiver_expr = try self.lowerExpr(member.target, context);
                        const receiver_type = try self.resolvedExprType(member.target, context);
                        try args.insert(self.allocator, 0, receiver_expr);

                        const call_name = if (builtins.resolveMethod(member.name, receiver_type, arg_types.items)) |_|
                            member.name
                        else if (try self.resolveTraitMethodName(receiver_type, member.name)) |resolved_name|
                            resolved_name
                        else
                            member.name;

                        break :blk try self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{
                            .call = .{
                                .name = call_name,
                                .args = try args.toOwnedSlice(self.allocator),
                            },
                        });
                    },
                    else => return error.UnsupportedCallTarget,
                }
            },
            .index => |index_expr| self.makeExprAt(expr.position, try self.resolvedExprType(expr, context), .{
                .index = .{
                    .target = try self.lowerExpr(index_expr.target, context),
                    .index = try self.lowerExpr(index_expr.index, context),
                },
            }),
            .match_expr => |match_expr| try self.lowerMatchExpr(expr, match_expr, context),
            else => return error.UnsupportedExpression,
        };
    }

    fn lowerMatchExpr(
        self: *Builder,
        expr: *ast.Expr,
        match_expr: ast.Expr.MatchExpr,
        context: *FunctionContext,
    ) anyerror!*ir.Expr {
        const helper_name = try std.fmt.allocPrint(self.allocator, "__match_{d}", .{self.match_helper_index});
        self.match_helper_index += 1;

        const value_type = try self.resolvedExprType(match_expr.value, context);
        const result_type = try self.resolvedExprType(expr, context);

        var helper_context = FunctionContext.init(self.allocator);
        helper_context.stage = null;
        helper_context.stage_functions = self.typed.global_functions;
        defer helper_context.deinit();
        try helper_context.locals.put("__match_value", value_type);
        try self.registerUniforms(&helper_context);

        var body = std.ArrayListUnmanaged(ir.Statement){};
        defer body.deinit(self.allocator);

        if (try self.lowerMatchSwitch(match_expr.arms, value_type, result_type, &helper_context)) |helper_switch| {
            try body.append(self.allocator, helper_switch);
        } else {
            const helper_if = try self.lowerMatchArms(match_expr.arms, 0, value_type, result_type, &helper_context);
            try body.append(self.allocator, helper_if);
        }
        if (!result_type.isVoid()) {
            try body.append(self.allocator, self.makeStatementAt(expr.position, .{
                .return_stmt = try self.defaultValueExpr(result_type),
            }));
        }

        try self.lowered_globals.append(self.allocator, .{
            .name = helper_name,
            .return_type = result_type,
            .params = try self.allocator.dupe(ir.Param, &.{
                .{
                    .name = "__match_value",
                    .ty = value_type,
                    .is_inout = false,
                    .source_line = expr.position.line,
                    .source_column = expr.position.column,
                },
            }),
            .body = try body.toOwnedSlice(self.allocator),
            .stage = null,
            .source_line = expr.position.line,
            .source_column = expr.position.column,
        });

        const args = try self.allocator.alloc(*ir.Expr, 1);
        args[0] = try self.lowerExpr(match_expr.value, context);
        return try self.makeExprAt(expr.position, result_type, .{
            .call = .{
                .name = helper_name,
                .args = args,
            },
        });
    }

    fn lowerMatchSwitch(
        self: *Builder,
        arms: []const ast.MatchArm,
        value_type: types.Type,
        result_type: types.Type,
        context: *FunctionContext,
    ) anyerror!?ir.Statement {
        const type_info = self.typeInfoFor(value_type) orelse return null;

        for (arms) |arm| {
            if (!self.patternCanUseSwitch(arm.pattern, type_info.name)) return null;
        }

        const selector = try self.makeExprAt(arms[0].position, types.builtinType(.int), .{
            .field = .{
                .target = try self.makeExprAt(arms[0].position, value_type, .{ .identifier = "__match_value" }),
                .name = "tag",
            },
        });

        var cases = std.ArrayListUnmanaged(ir.SwitchCase){};
        defer cases.deinit(self.allocator);
        for (type_info.variants) |variant| {
            try cases.append(self.allocator, .{
                .value = @intCast(variant.tag),
                .body = try self.lowerMatchCaseBody(arms, type_info.name, variant.tag, value_type, result_type, context),
                .source_line = arms[0].position.line,
                .source_column = arms[0].position.column,
            });
        }

        return self.makeStatementAt(arms[0].position, .{
            .switch_stmt = .{
                .selector = selector,
                .cases = try cases.toOwnedSlice(self.allocator),
                .default_body = try self.matchDefaultBody(result_type),
            },
        });
    }

    fn lowerMatchArms(
        self: *Builder,
        arms: []const ast.MatchArm,
        index: usize,
        value_type: types.Type,
        result_type: types.Type,
        context: *FunctionContext,
    ) anyerror!ir.Statement {
        var arm_context = try context.clone(self.allocator);
        defer arm_context.deinit();

        const match_value = try self.makeExprAt(arms[index].position, value_type, .{ .identifier = "__match_value" });
        var condition = try self.patternCondition(arms[index].pattern, match_value, value_type, &arm_context);
        if (arms[index].guard) |guard| {
            const guard_expr = try self.lowerExpr(guard, &arm_context);
            condition = try self.makeExprAt(guard.position, types.builtinType(.bool), .{
                .binary = .{
                    .operator = .and_and,
                    .lhs = condition,
                    .rhs = guard_expr,
                },
            });
        }

        var then_body = std.ArrayListUnmanaged(ir.Statement){};
        defer then_body.deinit(self.allocator);
        const lowered_body = try self.lowerStatementList(arms[index].body, &arm_context);
        for (lowered_body) |statement| {
            try then_body.append(self.allocator, statement);
        }
        try self.finalizeImplicitReturn(&then_body, result_type, arms[index].body[arms[index].body.len - 1].position.line);

        const else_body = if (index + 1 < arms.len) blk: {
            const nested = try self.lowerMatchArms(arms, index + 1, value_type, result_type, context);
            const items = try self.allocator.alloc(ir.Statement, 1);
            items[0] = nested;
            break :blk items;
        } else if (result_type.isVoid()) &.{} else blk: {
            const items = try self.allocator.alloc(ir.Statement, 1);
            items[0] = self.makeStatementAt(arms[index].position, .{
                .return_stmt = try self.defaultValueExpr(result_type),
            });
            break :blk items;
        };

        return self.makeStatementAt(arms[index].position, .{
            .if_stmt = .{
                .condition = condition,
                .then_body = try then_body.toOwnedSlice(self.allocator),
                .else_body = else_body,
            },
        });
    }

    fn lowerMatchCaseBody(
        self: *Builder,
        arms: []const ast.MatchArm,
        parent_name: []const u8,
        tag: u32,
        value_type: types.Type,
        result_type: types.Type,
        context: *FunctionContext,
    ) anyerror![]const ir.Statement {
        var filtered = std.ArrayListUnmanaged(ast.MatchArm){};
        defer filtered.deinit(self.allocator);
        for (arms) |arm| {
            if (self.patternMatchesTag(arm.pattern, parent_name, tag)) {
                try filtered.append(self.allocator, arm);
            }
        }

        if (filtered.items.len == 0) return try self.matchDefaultBody(result_type);

        const statement = try self.lowerMatchArms(filtered.items, 0, value_type, result_type, context);
        const body = try self.allocator.alloc(ir.Statement, 1);
        body[0] = statement;
        return body;
    }

    fn matchDefaultBody(self: *Builder, result_type: types.Type) anyerror![]const ir.Statement {
        if (result_type.isVoid()) return &.{};

        const body = try self.allocator.alloc(ir.Statement, 1);
        body[0] = self.makeStatementAt(null, .{
            .return_stmt = try self.defaultValueExpr(result_type),
        });
        return body;
    }

    fn patternCanUseSwitch(self: *Builder, pattern: ast.Pattern, parent_name: []const u8) bool {
        return switch (pattern.data) {
            .wildcard, .binding => true,
            .constructor => |constructor| blk: {
                const info = self.typed.constructor(constructor.name) orelse break :blk false;
                break :blk std.mem.eql(u8, info.parent_name, parent_name);
            },
            else => false,
        };
    }

    fn patternMatchesTag(self: *Builder, pattern: ast.Pattern, parent_name: []const u8, tag: u32) bool {
        return switch (pattern.data) {
            .wildcard, .binding => true,
            .constructor => |constructor| blk: {
                const info = self.typed.constructor(constructor.name) orelse break :blk false;
                break :blk std.mem.eql(u8, info.parent_name, parent_name) and info.tag == tag;
            },
            else => false,
        };
    }

    fn finalizeImplicitReturn(
        _: *Builder,
        body: *std.ArrayListUnmanaged(ir.Statement),
        result_type: types.Type,
        source_line: u32,
    ) anyerror!void {
        if (result_type.isVoid() or body.items.len == 0) return;
        if (body.items[body.items.len - 1].data != .expr) return;

        body.items[body.items.len - 1] = Builder.makeStatementWithColumn(source_line, body.items[body.items.len - 1].source_column, .{
            .return_stmt = body.items[body.items.len - 1].data.expr,
        });
    }

    fn patternCondition(
        self: *Builder,
        pattern: ast.Pattern,
        target: *ir.Expr,
        target_type: types.Type,
        context: *FunctionContext,
    ) anyerror!*ir.Expr {
        return switch (pattern.data) {
            .wildcard => try self.makeExprAt(pattern.position, types.builtinType(.bool), .{ .bool = true }),
            .binding => |name| blk: {
                try context.loop_bindings.put(name, .{ .expr = target });
                break :blk try self.makeExprAt(pattern.position, types.builtinType(.bool), .{ .bool = true });
            },
            .integer => |value| try self.makeExprAt(pattern.position, types.builtinType(.bool), .{
                .binary = .{
                    .operator = .eq,
                    .lhs = target,
                    .rhs = try self.makeExprAt(pattern.position, types.builtinType(.int), .{ .integer = value }),
                },
            }),
            .float => |value| try self.makeExprAt(pattern.position, types.builtinType(.bool), .{
                .binary = .{
                    .operator = .eq,
                    .lhs = target,
                    .rhs = try self.makeExprAt(pattern.position, types.builtinType(.float), .{ .float = value }),
                },
            }),
            .bool => |value| try self.makeExprAt(pattern.position, types.builtinType(.bool), .{
                .binary = .{
                    .operator = .eq,
                    .lhs = target,
                    .rhs = try self.makeExprAt(pattern.position, types.builtinType(.bool), .{ .bool = value }),
                },
            }),
            .symbol => |value| try self.makeExprAt(pattern.position, types.builtinType(.bool), .{
                .binary = .{
                    .operator = .eq,
                    .lhs = target,
                    .rhs = try self.makeExprAt(pattern.position, types.builtinType(.symbol), .{ .integer = symbolId(value) }),
                },
            }),
            .constructor => |constructor| blk: {
                const info = self.typed.constructor(constructor.name) orelse return error.UnknownConstructor;

                var substitution = unify.Substitution.init(self.allocator);
                defer substitution.deinit();
                try unify.unify(&substitution, info.return_type, target_type);

                var condition = try self.makeExprAt(pattern.position, types.builtinType(.bool), .{
                    .binary = .{
                        .operator = .eq,
                        .lhs = try self.makeExprAt(pattern.position, types.builtinType(.int), .{
                            .field = .{
                                .target = target,
                                .name = "tag",
                            },
                        }),
                        .rhs = try self.makeExprAt(pattern.position, types.builtinType(.int), .{ .integer = @as(i64, @intCast(info.tag)) }),
                    },
                });

                for (constructor.args, info.field_names, info.field_types, 0..) |arg_pattern, field_name, field_type, field_index| {
                    const resolved_field_type = try substitution.apply(field_type);
                    const field_expr = try self.makeExprAt(arg_pattern.position, resolved_field_type, .{
                        .field = .{
                            .target = target,
                            .name = try self.adtFieldName(constructor.name, field_name, field_index),
                        },
                    });
                    const nested_condition = try self.patternCondition(arg_pattern, field_expr, resolved_field_type, context);
                    condition = try self.makeExprAt(arg_pattern.position, types.builtinType(.bool), .{
                        .binary = .{
                            .operator = .and_and,
                            .lhs = condition,
                            .rhs = nested_condition,
                        },
                    });
                }

                break :blk condition;
            },
        };
    }

    fn defaultValueExpr(self: *Builder, ty: types.Type) anyerror!*ir.Expr {
        return switch (ty) {
            .builtin => |builtin| switch (builtin) {
                .float => try self.makeExpr(ty, .{ .float = 0.0 }),
                .int => try self.makeExpr(ty, .{ .integer = 0 }),
                .uint => try self.makeExpr(ty, .{ .integer = 0 }),
                .bool => try self.makeExpr(ty, .{ .bool = false }),
                .symbol => try self.makeExpr(ty, .{ .integer = 0 }),
                .vec2,
                .vec3,
                .vec4,
                .ivec2,
                .ivec3,
                .ivec4,
                .uvec2,
                .uvec3,
                .uvec4,
                .mat2,
                .mat3,
                .mat4,
                => blk: {
                    const name = constructorNameForType(ty) orelse return error.UnsupportedDefaultValue;
                    const args = try self.allocator.alloc(*ir.Expr, 1);
                    args[0] = try self.defaultValueExpr(ty.componentType() orelse types.builtinType(.float));
                    break :blk try self.makeExpr(ty, .{
                        .call = .{
                            .name = name,
                            .args = args,
                        },
                    });
                },
                else => return error.UnsupportedDefaultValue,
            },
            .type_app => blk: {
                const name = constructorNameForType(ty) orelse return error.UnsupportedDefaultValue;
                const args = try self.allocator.alloc(*ir.Expr, 1);
                args[0] = try self.defaultValueExpr(ty.componentType() orelse types.builtinType(.float));
                break :blk try self.makeExpr(ty, .{
                    .call = .{
                        .name = name,
                        .args = args,
                    },
                });
            },
            else => return error.UnsupportedDefaultValue,
        };
    }

    fn resolvedExprType(self: *Builder, expr: *ast.Expr, context: *const FunctionContext) anyerror!types.Type {
        return self.applyType(self.typed.exprType(expr), context);
    }

    fn applyType(self: *Builder, ty: types.Type, context: *const FunctionContext) anyerror!types.Type {
        _ = self;
        if (context.substitution) |substitution| {
            return substitution.apply(ty);
        }
        return ty;
    }

    fn resolveUserCallName(
        self: *Builder,
        name: []const u8,
        arg_types: []const types.Type,
        context: *FunctionContext,
    ) anyerror![]const u8 {
        if (try self.resolveCallInFunctions(name, arg_types, context.stage_functions, true)) |resolved_name| {
            return resolved_name;
        }
        if (try self.resolveCallInFunctions(name, arg_types, self.typed.global_functions, false)) |resolved_name| {
            return resolved_name;
        }
        return name;
    }

    fn resolveCallInFunctions(
        self: *Builder,
        name: []const u8,
        arg_types: []const types.Type,
        functions: []const *ast.FunctionDef,
        is_stage_local: bool,
    ) anyerror!?[]const u8 {
        function_loop: for (functions) |function| {
            const signature = self.typed.functionSignature(function) orelse continue;
            if (!sameName(signature.name, name)) continue;
            if (signature.params.len != arg_types.len) continue;

            var substitution = unify.Substitution.init(self.allocator);
            defer substitution.deinit();

            for (signature.params, arg_types) |param, arg_type| {
                unify.unify(&substitution, param.ty, arg_type) catch continue :function_loop;
            }
            for (signature.constraints) |constraint| {
                const constrained_type = substitution.apply(types.typeVar(constraint.type_var)) catch continue :function_loop;
                if (!self.typed.traits.hasImpl(constraint.trait_name, constrained_type)) {
                    continue :function_loop;
                }
            }

            if (!self.functionNeedsSpecialization(function)) {
                return signature.name;
            }
            if (is_stage_local) return error.UnsupportedGenericStageFunction;
            return try self.ensureGlobalSpecialization(function, &substitution);
        }
        return null;
    }

    fn resolveTraitMethodName(
        self: *Builder,
        receiver_type: types.Type,
        method_name: []const u8,
    ) anyerror!?[]const u8 {
        if (receiver_type == .type_var) return null;

        var resolved_name: ?[]const u8 = null;
        var match_count: usize = 0;
        for (self.typed.traits.impls.items) |impl_info| {
            if (!impl_info.for_type.eql(receiver_type)) continue;
            const impl_method = self.typed.traits.findImplMethod(impl_info.trait_name, receiver_type, method_name) orelse continue;
            resolved_name = impl_method.mangled_name;
            match_count += 1;
        }
        if (match_count > 1) return error.AmbiguousTraitMethod;
        return resolved_name;
    }

    fn ensureGlobalSpecialization(
        self: *Builder,
        function: *ast.FunctionDef,
        substitution: *unify.Substitution,
    ) anyerror![]const u8 {
        const name = try self.specializationName(function, substitution);
        if (self.lowered_specializations.contains(name)) return name;

        try self.lowered_specializations.put(name, {});
        try self.lowered_globals.append(
            self.allocator,
            try self.lowerFunctionWithOptions(function, null, null, .{
                .name = name,
                .substitution = substitution,
            }),
        );
        return name;
    }

    fn specializationName(
        self: *Builder,
        function: *ast.FunctionDef,
        substitution: *unify.Substitution,
    ) anyerror![]const u8 {
        const signature = self.typed.functionSignature(function).?;
        var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer buffer.deinit(self.allocator);

        const writer = buffer.writer(self.allocator);
        try writer.print("__spec_{s}", .{function.name});
        for (signature.params) |param| {
            try writer.writeByte('_');
            try appendTypeMangle(writer, try substitution.apply(param.ty));
        }
        return try buffer.toOwnedSlice(self.allocator);
    }

    fn functionNeedsSpecialization(self: *Builder, function: *ast.FunctionDef) bool {
        const signature = self.typed.functionSignature(function) orelse return false;
        if (signature.constraints.len > 0) return true;
        for (signature.params) |param| {
            if (containsTypeVar(param.ty)) return true;
        }
        return containsTypeVar(signature.return_type);
    }

    fn stageFunctionSlice(self: *Builder, stage: ast.Stage) []const *ast.FunctionDef {
        return switch (stage) {
            .vertex => self.typed.vertex_functions,
            .fragment => self.typed.fragment_functions,
            .compute => self.typed.compute_functions,
        };
    }

    fn makeExpr(self: *Builder, ty: types.Type, data: ir.Expr.Data) anyerror!*ir.Expr {
        return self.makeExprAt(null, ty, data);
    }

    fn makeExprAt(self: *Builder, position: ?ast.Position, ty: types.Type, data: ir.Expr.Data) anyerror!*ir.Expr {
        const expr = try self.allocator.create(ir.Expr);
        expr.* = .{
            .ty = ty,
            .source_line = if (position) |pos| pos.line else null,
            .source_column = if (position) |pos| pos.column else null,
            .data = data,
        };
        return expr;
    }

    fn makeStatement(_: *Builder, source_line: ?u32, data: ir.Statement.Data) ir.Statement {
        return Builder.makeStatementWithColumn(source_line, null, data);
    }

    fn makeStatementAt(_: *Builder, position: ?ast.Position, data: ir.Statement.Data) ir.Statement {
        return Builder.makeStatementWithColumn(
            if (position) |pos| pos.line else null,
            if (position) |pos| pos.column else null,
            data,
        );
    }

    fn makeStatementWithColumn(source_line: ?u32, source_column: ?u32, data: ir.Statement.Data) ir.Statement {
        return .{
            .source_line = source_line,
            .source_column = source_column,
            .data = data,
        };
    }

    fn registerUniforms(self: *Builder, context: *FunctionContext) anyerror!void {
        for (self.typed.program.items) |item| {
            if (item == .uniform) {
                try context.nonlocals.put(item.uniform.name, {});
            }
        }
    }

    fn lowerIo(_: *Builder, decl: ast.IoDecl) anyerror!ir.Global {
        return .{
            .name = decl.name,
            .ty = types.fromName(decl.type_name) orelse .{ .struct_type = decl.type_name },
            .location = decl.location,
            .source_line = decl.position.line,
            .source_column = decl.position.column,
        };
    }

    fn adtFieldName(self: *Builder, variant_name: []const u8, field_name: []const u8, index: usize) anyerror![]const u8 {
        if (field_name.len > 0) {
            return try std.fmt.allocPrint(self.allocator, "__{s}_{s}", .{ variant_name, field_name });
        }
        return try std.fmt.allocPrint(self.allocator, "__{s}_{d}", .{ variant_name, index });
    }

    fn typeInfoFor(self: *Builder, ty: types.Type) ?sema.TypeDefInfo {
        return switch (ty) {
            .struct_type => |name| self.typed.typeDef(name),
            .type_app => |app_ty| self.typed.typeDef(app_ty.name),
            else => null,
        };
    }

    fn findPrecision(self: *Builder, stage: ast.Stage) ?[]const u8 {
        for (self.typed.program.items) |item| {
            if (item == .precision and std.mem.eql(u8, item.precision.stage, stageName(stage))) {
                return item.precision.precision;
            }
        }
        return null;
    }

    fn resolveConstInt(self: *Builder, expr: *ast.Expr, context: *FunctionContext) ?i64 {
        return switch (expr.data) {
            .integer => |value| value,
            .identifier => |name| if (context.loop_bindings.get(name)) |binding|
                switch (binding) {
                    .const_int => |value| value,
                    .expr => null,
                }
            else
                null,
            .unary => |unary| if (unary.operator == .minus)
                if (self.resolveConstInt(unary.operand, context)) |value|
                    -value
                else
                    null
            else
                null,
            else => null,
        };
    }
};

const FunctionContext = struct {
    stage: ?ast.Stage = null,
    stage_functions: []const *ast.FunctionDef = &.{},
    substitution: ?*unify.Substitution = null,
    self_type: ?types.Type = null,
    locals: std.StringHashMap(types.Type),
    nonlocals: std.StringHashMap(void),
    loop_bindings: std.StringHashMap(LoopBinding),

    fn init(allocator: std.mem.Allocator) FunctionContext {
        return .{
            .locals = std.StringHashMap(types.Type).init(allocator),
            .nonlocals = std.StringHashMap(void).init(allocator),
            .loop_bindings = std.StringHashMap(LoopBinding).init(allocator),
        };
    }

    fn clone(self: *const FunctionContext, allocator: std.mem.Allocator) anyerror!FunctionContext {
        var cloned = FunctionContext.init(allocator);
        cloned.stage = self.stage;
        cloned.stage_functions = self.stage_functions;
        cloned.substitution = self.substitution;
        cloned.self_type = self.self_type;

        var locals_it = self.locals.iterator();
        while (locals_it.next()) |entry| {
            try cloned.locals.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var nonlocals_it = self.nonlocals.iterator();
        while (nonlocals_it.next()) |entry| {
            try cloned.nonlocals.put(entry.key_ptr.*, {});
        }

        var bindings_it = self.loop_bindings.iterator();
        while (bindings_it.next()) |entry| {
            try cloned.loop_bindings.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        return cloned;
    }

    fn deinit(self: *FunctionContext) void {
        self.locals.deinit();
        self.nonlocals.deinit();
        self.loop_bindings.deinit();
    }
};

const LoopBinding = union(enum) {
    const_int: i64,
    expr: *ir.Expr,
};

const LowerOptions = struct {
    name: ?[]const u8 = null,
    substitution: ?*unify.Substitution = null,
    self_type: ?types.Type = null,
};

fn stageName(stage: ast.Stage) []const u8 {
    return switch (stage) {
        .vertex => "vertex",
        .fragment => "fragment",
        .compute => "compute",
    };
}

fn sameName(lhs: []const u8, rhs: []const u8) bool {
    return (lhs.len == rhs.len and lhs.ptr == rhs.ptr) or std.mem.eql(u8, lhs, rhs);
}

fn containsTypeVar(ty: types.Type) bool {
    return switch (ty) {
        .type_var => true,
        .function => |function| blk: {
            for (function.params) |param| {
                if (containsTypeVar(param)) break :blk true;
            }
            break :blk containsTypeVar(function.return_type.*);
        },
        .type_app => |app_ty| blk: {
            for (app_ty.args) |arg| {
                if (containsTypeVar(arg)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn appendTypeMangle(writer: anytype, ty: types.Type) !void {
    switch (ty) {
        .builtin => |builtin| try writer.writeAll(switch (builtin) {
            .float => "Float",
            .int => "Int",
            .uint => "UInt",
            .bool => "Bool",
            .symbol => "Symbol",
            .vec2 => "Vec2",
            .vec3 => "Vec3",
            .vec4 => "Vec4",
            .ivec2 => "IVec2",
            .ivec3 => "IVec3",
            .ivec4 => "IVec4",
            .uvec2 => "UVec2",
            .uvec3 => "UVec3",
            .uvec4 => "UVec4",
            .bvec2 => "BVec2",
            .bvec3 => "BVec3",
            .bvec4 => "BVec4",
            .mat2 => "Mat2",
            .mat3 => "Mat3",
            .mat4 => "Mat4",
            .sampler2d => "Sampler2D",
            .sampler_cube => "SamplerCube",
            .sampler3d => "Sampler3D",
            .void => "Void",
            .error_type => "Error",
        }),
        .struct_type => |name| try writer.writeAll(name),
        .type_var => |id| try writer.print("T{d}", .{id}),
        .nat => |value| try writer.print("{d}", .{value}),
        .type_app => |app_ty| {
            try writer.writeAll(app_ty.name);
            for (app_ty.args) |arg| {
                try writer.writeByte('_');
                try appendTypeMangle(writer, arg);
            }
        },
        .function => |function| {
            try writer.writeAll("Fn");
            for (function.params) |param| {
                try writer.writeByte('_');
                try appendTypeMangle(writer, param);
            }
            try writer.writeAll("_to_");
            try appendTypeMangle(writer, function.return_type.*);
        },
    }
}

fn constructorNameForType(ty: types.Type) ?[]const u8 {
    return switch (ty) {
        .builtin => |builtin| switch (builtin) {
            .float => "float",
            .int => "int",
            .uint => "uint",
            .bool => "bool",
            .symbol => "int",
            .vec2 => "vec2",
            .vec3 => "vec3",
            .vec4 => "vec4",
            .ivec2 => "ivec2",
            .ivec3 => "ivec3",
            .ivec4 => "ivec4",
            .uvec2 => "uvec2",
            .uvec3 => "uvec3",
            .uvec4 => "uvec4",
            .mat2 => "mat2",
            .mat3 => "mat3",
            .mat4 => "mat4",
            else => null,
        },
        .type_app => |app_ty| if (std.mem.eql(u8, app_ty.name, "Vec")) switch (app_ty.args[0]) {
            .nat => |len| switch (len) {
                2 => "vec2",
                3 => "vec3",
                4 => "vec4",
                else => null,
            },
            else => null,
        } else if (std.mem.eql(u8, app_ty.name, "Mat") and app_ty.args.len == 2) switch (app_ty.args[0]) {
            .nat => |rows| switch (app_ty.args[1]) {
                .nat => |cols| if (rows == cols) switch (rows) {
                    2 => "mat2",
                    3 => "mat3",
                    4 => "mat4",
                    else => null,
                } else null,
                else => null,
            },
            else => null,
        } else null,
        else => null,
    };
}

fn symbolId(name: []const u8) i64 {
    return @intCast(std.hash.Fnv1a_32.hash(name) & 0x7fff_ffff);
}
