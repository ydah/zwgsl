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
            .vertex = if (module.vertex) |stage| try self.lowerStage(stage) else null,
            .fragment = if (module.fragment) |stage| try self.lowerStage(stage) else null,
            .compute = if (module.compute) |stage| try self.lowerStage(stage) else null,
        };
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
        return .{
            .name = function.name,
            .return_type = function.return_type,
            .params = try self.lowerParams(function.params),
            .body = try self.lowerStatements(function.body),
            .stage = function.stage,
            .source_line = function.source_line,
            .source_column = function.source_column,
        };
    }

    fn lowerParams(self: *Builder, params: []const hir.Param) ![]const mir.Param {
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

    fn lowerStage(self: *Builder, stage: hir.Stage) !mir.Stage {
        return .{
            .stage = stage.stage,
            .precision = stage.precision,
            .inputs = try self.lowerGlobals(stage.inputs),
            .outputs = try self.lowerGlobals(stage.outputs),
            .varyings = try self.lowerGlobals(stage.varyings),
            .functions = try self.lowerFunctions(stage.functions),
            .source_line = stage.source_line,
            .source_column = stage.source_column,
        };
    }

    fn lowerStatements(self: *Builder, statements: []const hir.Statement) ![]const mir.Statement {
        const lowered = try self.allocator.alloc(mir.Statement, statements.len);
        for (statements, 0..) |statement, index| {
            lowered[index] = try self.lowerStatement(statement);
        }
        return lowered;
    }

    fn lowerStatement(self: *Builder, statement: hir.Statement) anyerror!mir.Statement {
        return .{
            .source_line = statement.source_line,
            .source_column = statement.source_column,
            .data = switch (statement.data) {
                .var_decl => |var_decl| .{
                    .var_decl = .{
                        .name = var_decl.name,
                        .ty = var_decl.ty,
                        .mutable = var_decl.mutable,
                        .value = if (var_decl.value) |value| try self.lowerExpr(value) else null,
                    },
                },
                .assign => |assign| .{
                    .assign = .{
                        .target = try self.lowerExpr(assign.target),
                        .operator = assign.operator,
                        .value = try self.lowerExpr(assign.value),
                    },
                },
                .expr => |expr| .{ .expr = try self.lowerExpr(expr) },
                .if_stmt => |if_stmt| .{
                    .if_stmt = .{
                        .condition = try self.lowerExpr(if_stmt.condition),
                        .then_body = try self.lowerStatements(if_stmt.then_body),
                        .else_body = try self.lowerStatements(if_stmt.else_body),
                    },
                },
                .switch_stmt => |switch_stmt| .{
                    .switch_stmt = .{
                        .selector = try self.lowerExpr(switch_stmt.selector),
                        .cases = try self.lowerSwitchCases(switch_stmt.cases),
                        .default_body = try self.lowerStatements(switch_stmt.default_body),
                    },
                },
                .return_stmt => |expr| .{ .return_stmt = if (expr) |value| try self.lowerExpr(value) else null },
                .discard => .{ .discard = {} },
            },
        };
    }

    fn lowerSwitchCases(self: *Builder, cases: []const hir.SwitchCase) ![]const mir.SwitchCase {
        const lowered = try self.allocator.alloc(mir.SwitchCase, cases.len);
        for (cases, 0..) |case_stmt, index| {
            lowered[index] = .{
                .value = case_stmt.value,
                .body = try self.lowerStatements(case_stmt.body),
                .source_line = case_stmt.source_line,
                .source_column = case_stmt.source_column,
            };
        }
        return lowered;
    }

    fn lowerExpr(self: *Builder, expr: *const hir.Expr) anyerror!*mir.Expr {
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

    fn lowerExprSlice(self: *Builder, exprs: []const *hir.Expr) anyerror![]const *mir.Expr {
        const lowered = try self.allocator.alloc(*mir.Expr, exprs.len);
        for (exprs, 0..) |expr, index| {
            lowered[index] = try self.lowerExpr(expr);
        }
        return lowered;
    }
};
