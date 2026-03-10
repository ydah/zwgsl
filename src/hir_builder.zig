const std = @import("std");
const hir = @import("hir.zig");
const ir = @import("ir.zig");
const ir_builder = @import("ir_builder.zig");
const sema = @import("sema.zig");

pub fn build(allocator: std.mem.Allocator, typed: *sema.TypedProgram) !*hir.Module {
    const lowered = try ir_builder.build(allocator, typed);
    var builder = Builder{ .allocator = allocator };
    return try builder.cloneModule(lowered);
}

const Builder = struct {
    allocator: std.mem.Allocator,

    fn cloneModule(self: *Builder, module: *const ir.Module) !*hir.Module {
        const cloned = try self.allocator.create(hir.Module);
        cloned.* = .{
            .version = module.version,
            .uniforms = try self.cloneGlobals(module.uniforms),
            .structs = try self.cloneStructs(module.structs),
            .global_functions = try self.cloneFunctions(module.global_functions),
            .vertex = if (module.vertex) |stage| try self.cloneStage(stage) else null,
            .fragment = if (module.fragment) |stage| try self.cloneStage(stage) else null,
            .compute = if (module.compute) |stage| try self.cloneStage(stage) else null,
        };
        return cloned;
    }

    fn cloneGlobals(self: *Builder, globals: []const ir.Global) ![]const hir.Global {
        const cloned = try self.allocator.alloc(hir.Global, globals.len);
        for (globals, 0..) |global, index| {
            cloned[index] = .{
                .name = global.name,
                .ty = global.ty,
                .location = global.location,
                .source_line = global.source_line,
                .source_column = global.source_column,
            };
        }
        return cloned;
    }

    fn cloneStructs(self: *Builder, structs: []const ir.StructDecl) ![]const hir.StructDecl {
        const cloned = try self.allocator.alloc(hir.StructDecl, structs.len);
        for (structs, 0..) |struct_decl, index| {
            cloned[index] = .{
                .name = struct_decl.name,
                .fields = try self.cloneStructFields(struct_decl.fields),
                .source_line = struct_decl.source_line,
                .source_column = struct_decl.source_column,
            };
        }
        return cloned;
    }

    fn cloneStructFields(self: *Builder, fields: []const ir.StructField) ![]const hir.StructField {
        const cloned = try self.allocator.alloc(hir.StructField, fields.len);
        for (fields, 0..) |field, index| {
            cloned[index] = .{
                .name = field.name,
                .ty = field.ty,
                .source_line = field.source_line,
                .source_column = field.source_column,
            };
        }
        return cloned;
    }

    fn cloneFunctions(self: *Builder, functions: []const ir.Function) ![]const hir.Function {
        const cloned = try self.allocator.alloc(hir.Function, functions.len);
        for (functions, 0..) |function, index| {
            cloned[index] = try self.cloneFunction(function);
        }
        return cloned;
    }

    fn cloneFunction(self: *Builder, function: ir.Function) !hir.Function {
        return .{
            .name = function.name,
            .return_type = function.return_type,
            .params = try self.cloneParams(function.params),
            .body = try self.cloneStatements(function.body),
            .stage = function.stage,
            .source_line = function.source_line,
            .source_column = function.source_column,
        };
    }

    fn cloneParams(self: *Builder, params: []const ir.Param) ![]const hir.Param {
        const cloned = try self.allocator.alloc(hir.Param, params.len);
        for (params, 0..) |param, index| {
            cloned[index] = .{
                .name = param.name,
                .ty = param.ty,
                .is_inout = param.is_inout,
                .source_line = param.source_line,
                .source_column = param.source_column,
            };
        }
        return cloned;
    }

    fn cloneStage(self: *Builder, stage: ir.Stage) !hir.Stage {
        return .{
            .stage = stage.stage,
            .precision = stage.precision,
            .inputs = try self.cloneGlobals(stage.inputs),
            .outputs = try self.cloneGlobals(stage.outputs),
            .varyings = try self.cloneGlobals(stage.varyings),
            .functions = try self.cloneFunctions(stage.functions),
            .source_line = stage.source_line,
            .source_column = stage.source_column,
        };
    }

    fn cloneStatements(self: *Builder, statements: []const ir.Statement) ![]const hir.Statement {
        const cloned = try self.allocator.alloc(hir.Statement, statements.len);
        for (statements, 0..) |statement, index| {
            cloned[index] = try self.cloneStatement(statement);
        }
        return cloned;
    }

    fn cloneStatement(self: *Builder, statement: ir.Statement) anyerror!hir.Statement {
        return .{
            .source_line = statement.source_line,
            .source_column = statement.source_column,
            .data = switch (statement.data) {
                .var_decl => |var_decl| .{
                    .var_decl = .{
                        .name = var_decl.name,
                        .ty = var_decl.ty,
                        .mutable = var_decl.mutable,
                        .value = if (var_decl.value) |value| try self.cloneExpr(value) else null,
                    },
                },
                .assign => |assign| .{
                    .assign = .{
                        .target = try self.cloneExpr(assign.target),
                        .operator = assign.operator,
                        .value = try self.cloneExpr(assign.value),
                    },
                },
                .expr => |expr| .{ .expr = try self.cloneExpr(expr) },
                .if_stmt => |if_stmt| .{
                    .if_stmt = .{
                        .condition = try self.cloneExpr(if_stmt.condition),
                        .then_body = try self.cloneStatements(if_stmt.then_body),
                        .else_body = try self.cloneStatements(if_stmt.else_body),
                    },
                },
                .switch_stmt => |switch_stmt| .{
                    .switch_stmt = .{
                        .selector = try self.cloneExpr(switch_stmt.selector),
                        .cases = try self.cloneSwitchCases(switch_stmt.cases),
                        .default_body = try self.cloneStatements(switch_stmt.default_body),
                    },
                },
                .return_stmt => |expr| .{ .return_stmt = if (expr) |value| try self.cloneExpr(value) else null },
                .discard => .{ .discard = {} },
            },
        };
    }

    fn cloneSwitchCases(self: *Builder, cases: []const ir.SwitchCase) ![]const hir.SwitchCase {
        const cloned = try self.allocator.alloc(hir.SwitchCase, cases.len);
        for (cases, 0..) |case_stmt, index| {
            cloned[index] = .{
                .value = case_stmt.value,
                .body = try self.cloneStatements(case_stmt.body),
                .source_line = case_stmt.source_line,
                .source_column = case_stmt.source_column,
            };
        }
        return cloned;
    }

    fn cloneExpr(self: *Builder, expr: *const ir.Expr) anyerror!*hir.Expr {
        const cloned = try self.allocator.create(hir.Expr);
        cloned.* = .{
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
                        .operand = try self.cloneExpr(unary.operand),
                    },
                },
                .binary => |binary| .{
                    .binary = .{
                        .operator = binary.operator,
                        .lhs = try self.cloneExpr(binary.lhs),
                        .rhs = try self.cloneExpr(binary.rhs),
                    },
                },
                .call => |call| .{
                    .call = .{
                        .name = call.name,
                        .args = try self.cloneExprSlice(call.args),
                    },
                },
                .field => |field| .{
                    .field = .{
                        .target = try self.cloneExpr(field.target),
                        .name = field.name,
                    },
                },
                .index => |index_expr| .{
                    .index = .{
                        .target = try self.cloneExpr(index_expr.target),
                        .index = try self.cloneExpr(index_expr.index),
                    },
                },
            },
        };
        return cloned;
    }

    fn cloneExprSlice(self: *Builder, exprs: []const *ir.Expr) anyerror![]const *hir.Expr {
        const cloned = try self.allocator.alloc(*hir.Expr, exprs.len);
        for (exprs, 0..) |expr, index| {
            cloned[index] = try self.cloneExpr(expr);
        }
        return cloned;
    }
};
