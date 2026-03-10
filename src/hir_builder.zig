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
        };
    }

    fn cloneParams(self: *Builder, params: []const ir.Param) ![]const hir.Param {
        const cloned = try self.allocator.alloc(hir.Param, params.len);
        for (params, 0..) |param, index| {
            cloned[index] = .{
                .name = param.name,
                .ty = param.ty,
                .is_inout = param.is_inout,
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
                .return_stmt => |expr| .{ .return_stmt = if (expr) |value| try self.cloneExpr(value) else null },
                .discard => .{ .discard = {} },
            },
        };
    }

    fn cloneExpr(self: *Builder, expr: *const ir.Expr) anyerror!*hir.Expr {
        const cloned = try self.allocator.create(hir.Expr);
        cloned.* = .{
            .ty = expr.ty,
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
