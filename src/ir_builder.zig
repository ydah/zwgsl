const std = @import("std");
const ast = @import("ast.zig");
const builtins = @import("builtins.zig");
const ir = @import("ir.zig");
const sema = @import("sema.zig");
const types = @import("types.zig");

pub fn build(allocator: std.mem.Allocator, typed: *sema.TypedProgram) anyerror!*ir.Module {
    var builder = Builder{
        .allocator = allocator,
        .typed = typed,
    };
    return try builder.run();
}

const Builder = struct {
    allocator: std.mem.Allocator,
    typed: *sema.TypedProgram,

    fn run(self: *Builder) anyerror!*ir.Module {
        const module = try self.allocator.create(ir.Module);
        module.* = .{};

        module.version = self.findVersion();
        module.uniforms = try self.collectUniforms();
        module.structs = try self.collectStructs();
        module.global_functions = try self.lowerFunctions(self.typed.global_functions, null, null);
        if (self.typed.vertex_block) |block| {
            module.vertex = try self.lowerStage(block, self.typed.vertex_functions);
        }
        if (self.typed.fragment_block) |block| {
            module.fragment = try self.lowerStage(block, self.typed.fragment_functions);
        }
        if (self.typed.compute_block) |block| {
            module.compute = try self.lowerStage(block, self.typed.compute_functions);
        }

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
                    });
                }
                try items.append(self.allocator, .{
                    .name = item.struct_def.name,
                    .fields = try fields.toOwnedSlice(self.allocator),
                });
            }
        }

        return try items.toOwnedSlice(self.allocator);
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
        };
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
        const signature = self.typed.functionSignature(function).?;

        var params = std.ArrayListUnmanaged(ir.Param){};
        defer params.deinit(self.allocator);
        var context = FunctionContext.init(self.allocator);
        defer context.deinit();

        for (signature.params) |param| {
            try params.append(self.allocator, .{
                .name = param.name,
                .ty = param.ty,
                .is_inout = param.is_inout,
            });
            try context.locals.put(param.name, param.ty);
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
                binding.*.position.line,
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
        if (!signature.return_type.isVoid() and lowered_body.len > 0 and lowered_body[lowered_body.len - 1].data == .expr) {
            var replaced = try self.allocator.dupe(ir.Statement, lowered_body);
            replaced[replaced.len - 1] = self.makeStatement(lowered_body[lowered_body.len - 1].source_line, .{
                .return_stmt = lowered_body[lowered_body.len - 1].data.expr,
            });
            final_body = replaced;
        }

        return .{
            .name = function.name,
            .return_type = signature.return_type,
            .params = try params.toOwnedSlice(self.allocator),
            .body = final_body,
            .stage = stage,
            .source_line = function.position.line,
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
                try list.append(self.allocator, self.makeStatement(statement.position.line, .{
                    .expr = try self.lowerExpr(expr, context),
                }));
            },
            .let_binding => |binding| {
                try self.appendLocalBinding(
                    list,
                    statement.position.line,
                    binding.name,
                    binding.value,
                    false,
                    context,
                );
            },
            .typed_assignment => |typed_assignment| {
                try self.appendLocalBinding(
                    list,
                    statement.position.line,
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
                        const ty = self.typed.exprType(assignment.value);
                        try context.locals.put(name, ty);
                        try list.append(self.allocator, self.makeStatement(statement.position.line, .{
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

                try list.append(self.allocator, self.makeStatement(statement.position.line, .{
                    .assign = .{
                        .target = try self.lowerExpr(assignment.target, context),
                        .operator = assignment.operator,
                        .value = try self.lowerExpr(assignment.value, context),
                    },
                }));
            },
            .return_stmt => |value| {
                try list.append(self.allocator, self.makeStatement(statement.position.line, .{
                    .return_stmt = if (value) |expr| try self.lowerExpr(expr, context) else null,
                }));
            },
            .discard => try list.append(self.allocator, self.makeStatement(statement.position.line, .{ .discard = {} })),
            .conditional => |conditional| {
                const lowered_body = try self.lowerSingleStatementSlice(conditional.body, context);
                const condition = try self.lowerExpr(conditional.condition, context);
                const then_body = if (conditional.negate) &.{} else lowered_body;
                const else_body = if (conditional.negate) lowered_body else &.{};
                try list.append(self.allocator, self.makeStatement(statement.position.line, .{
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
                const collection_type = self.typed.exprType(each_loop.collection);
                const vector_len = collection_type.vectorLen() orelse return error.UnsupportedLoop;
                const element_type = collection_type.componentType() orelse return error.UnsupportedLoop;

                var index: u8 = 0;
                while (index < vector_len) : (index += 1) {
                    var nested = try context.clone(self.allocator);
                    defer nested.deinit();
                    if (each_loop.binding) |binding| {
                        const collection = try self.lowerExpr(each_loop.collection, context);
                        const index_expr = try self.makeExpr(types.builtinType(.int), .{
                            .integer = index,
                        });
                        const element_expr = try self.makeExpr(element_type, .{
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
        source_line: u32,
        name: []const u8,
        value_expr: *ast.Expr,
        mutable: bool,
        context: *FunctionContext,
    ) anyerror!void {
        const ty = self.typed.exprType(value_expr);
        try context.locals.put(name, ty);
        try list.append(self.allocator, self.makeStatement(source_line, .{
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
            condition = try self.makeExpr(types.builtinType(.bool), .{
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

        return self.makeStatement(if_stmt.branches[index].condition.position.line, .{
            .if_stmt = .{
                .condition = condition,
                .then_body = then_body,
                .else_body = else_body,
            },
        });
    }

    fn lowerExpr(self: *Builder, expr: *ast.Expr, context: *FunctionContext) anyerror!*ir.Expr {
        return switch (expr.data) {
            .integer => |value| self.makeExpr(self.typed.exprType(expr), .{ .integer = value }),
            .float => |value| self.makeExpr(self.typed.exprType(expr), .{ .float = value }),
            .bool => |value| self.makeExpr(self.typed.exprType(expr), .{ .bool = value }),
            .identifier => |name| blk: {
                if (context.loop_bindings.get(name)) |binding| {
                    break :blk switch (binding) {
                        .const_int => |value| try self.makeExpr(types.builtinType(.int), .{ .integer = value }),
                        .expr => |value| value,
                    };
                }
                break :blk try self.makeExpr(self.typed.exprType(expr), .{ .identifier = name });
            },
            .self_ref => unreachable,
            .unary => |unary| self.makeExpr(self.typed.exprType(expr), .{
                .unary = .{
                    .operator = unary.operator,
                    .operand = try self.lowerExpr(unary.operand, context),
                },
            }),
            .binary => |binary| self.makeExpr(self.typed.exprType(expr), .{
                .binary = .{
                    .operator = binary.operator,
                    .lhs = try self.lowerExpr(binary.lhs, context),
                    .rhs = try self.lowerExpr(binary.rhs, context),
                },
            }),
            .member => |member| blk: {
                if (member.target.data == .self_ref) {
                    break :blk try self.makeExpr(self.typed.exprType(expr), .{ .identifier = member.name });
                }

                const target_type = self.typed.exprType(member.target);
                if (types.isValidSwizzle(target_type, member.name) != null or target_type == .struct_type) {
                    break :blk try self.makeExpr(self.typed.exprType(expr), .{
                        .field = .{
                            .target = try self.lowerExpr(member.target, context),
                            .name = member.name,
                        },
                    });
                }

                if (builtins.resolveMethod(member.name, target_type, &.{})) |_| {
                    const args = try self.allocator.alloc(*ir.Expr, 1);
                    args[0] = try self.lowerExpr(member.target, context);
                    break :blk try self.makeExpr(self.typed.exprType(expr), .{
                        .call = .{
                            .name = member.name,
                            .args = args,
                        },
                    });
                }

                break :blk try self.makeExpr(self.typed.exprType(expr), .{
                    .field = .{
                        .target = try self.lowerExpr(member.target, context),
                        .name = member.name,
                    },
                });
            },
            .call => |call| blk: {
                var args = std.ArrayListUnmanaged(*ir.Expr){};
                defer args.deinit(self.allocator);

                switch (call.callee.data) {
                    .identifier => |name| {
                        for (call.args) |arg| try args.append(self.allocator, try self.lowerExpr(arg, context));
                        break :blk try self.makeExpr(self.typed.exprType(expr), .{
                            .call = .{
                                .name = name,
                                .args = try args.toOwnedSlice(self.allocator),
                            },
                        });
                    },
                    .member => |member| {
                        try args.append(self.allocator, try self.lowerExpr(member.target, context));
                        for (call.args) |arg| try args.append(self.allocator, try self.lowerExpr(arg, context));
                        break :blk try self.makeExpr(self.typed.exprType(expr), .{
                            .call = .{
                                .name = member.name,
                                .args = try args.toOwnedSlice(self.allocator),
                            },
                        });
                    },
                    else => return error.UnsupportedCallTarget,
                }
            },
            .index => |index_expr| self.makeExpr(self.typed.exprType(expr), .{
                .index = .{
                    .target = try self.lowerExpr(index_expr.target, context),
                    .index = try self.lowerExpr(index_expr.index, context),
                },
            }),
            else => return error.UnsupportedExpression,
        };
    }

    fn makeExpr(self: *Builder, ty: types.Type, data: ir.Expr.Data) anyerror!*ir.Expr {
        const expr = try self.allocator.create(ir.Expr);
        expr.* = .{
            .ty = ty,
            .data = data,
        };
        return expr;
    }

    fn makeStatement(_: *Builder, source_line: ?u32, data: ir.Statement.Data) ir.Statement {
        return .{
            .source_line = source_line,
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

fn stageName(stage: ast.Stage) []const u8 {
    return switch (stage) {
        .vertex => "vertex",
        .fragment => "fragment",
        .compute => "compute",
    };
}
