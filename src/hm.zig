const std = @import("std");
const ast = @import("ast.zig");
const builtins = @import("builtins.zig");
const token = @import("token.zig");
const types = @import("types.zig");
const unify = @import("unify.zig");

pub const TypeScheme = struct {
    quantified: []const u32 = &.{},
    ty: types.Type,
};

pub const TypeEnv = std.StringHashMap(TypeScheme);

pub const Engine = struct {
    allocator: std.mem.Allocator,
    next_type_var: u32 = 0,
    substitution: unify.Substitution,

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .allocator = allocator,
            .substitution = unify.Substitution.init(allocator),
        };
    }

    pub fn deinit(self: *Engine) void {
        self.substitution.deinit();
    }

    pub fn monomorphic(ty: types.Type) TypeScheme {
        return .{ .ty = ty };
    }

    pub fn freshTypeVar(self: *Engine) types.Type {
        const id = self.next_type_var;
        self.next_type_var += 1;
        return types.typeVar(id);
    }

    pub fn applyType(self: *Engine, ty: types.Type) !types.Type {
        return try self.substitution.apply(ty);
    }

    pub fn inferExpr(self: *Engine, env: *const TypeEnv, expr: *ast.Expr) !types.Type {
        return switch (expr.data) {
            .integer => types.builtinType(.int),
            .float => types.builtinType(.float),
            .bool => types.builtinType(.bool),
            .identifier => |name| blk: {
                const scheme = env.get(name) orelse return error.UnknownIdentifier;
                break :blk try self.instantiate(scheme);
            },
            .unary => |unary| blk: {
                const operand = try self.inferExpr(env, unary.operand);
                switch (unary.operator) {
                    .bang => {
                        try unify.unify(&self.substitution, operand, types.builtinType(.bool));
                        break :blk types.builtinType(.bool);
                    },
                    .minus => break :blk try self.applyType(operand),
                    else => return error.UnsupportedExpression,
                }
            },
            .binary => |binary| blk: {
                const lhs = try self.inferExpr(env, binary.lhs);
                const rhs = try self.inferExpr(env, binary.rhs);
                switch (binary.operator) {
                    .plus, .minus, .star, .slash, .percent => {
                        try unify.unify(&self.substitution, lhs, rhs);
                        break :blk try self.applyType(lhs);
                    },
                    .eq, .neq => {
                        try unify.unify(&self.substitution, lhs, rhs);
                        break :blk types.builtinType(.bool);
                    },
                    .and_and, .or_or => {
                        try unify.unify(&self.substitution, lhs, types.builtinType(.bool));
                        try unify.unify(&self.substitution, rhs, types.builtinType(.bool));
                        break :blk types.builtinType(.bool);
                    },
                    .lt, .gt, .le, .ge => {
                        try unify.unify(&self.substitution, lhs, rhs);
                        break :blk types.builtinType(.bool);
                    },
                    else => return error.UnsupportedExpression,
                }
            },
            .call => |call| blk: {
                const arg_types = try self.allocator.alloc(types.Type, call.args.len);
                for (call.args, 0..) |arg, index| {
                    arg_types[index] = try self.applyType(try self.inferExpr(env, arg));
                }

                if (call.callee.data == .identifier) {
                    const name = call.callee.data.identifier;
                    if (allConcrete(arg_types)) {
                        if (builtins.resolve(name, arg_types)) |resolution| {
                            break :blk resolution.return_type;
                        }
                    }
                }

                const callee = try self.inferExpr(env, call.callee);
                break :blk try self.resolveCallable(callee, arg_types);
            },
            .lambda => |lambda| {
                var scoped = try cloneEnv(self.allocator, env);
                defer scoped.deinit();

                const param_types = try self.allocator.alloc(types.Type, lambda.params.len);
                for (lambda.params, 0..) |name, index| {
                    const param_type = self.freshTypeVar();
                    param_types[index] = param_type;
                    try scoped.put(name, monomorphic(param_type));
                }

                const return_value = try self.inferExpr(&scoped, lambda.body);
                const return_type = try self.allocator.create(types.Type);
                return_type.* = try self.applyType(return_value);

                return .{
                    .function = .{
                        .params = param_types,
                        .return_type = return_type,
                    },
                };
            },
            else => return error.UnsupportedExpression,
        };
    }

    pub fn generalize(self: *Engine, env: *const TypeEnv, ty: types.Type) !TypeScheme {
        const applied = try self.applyType(ty);

        var type_vars = std.AutoHashMap(u32, void).init(self.allocator);
        defer type_vars.deinit();
        try collectFreeTypeVars(applied, &type_vars);

        var env_vars = std.AutoHashMap(u32, void).init(self.allocator);
        defer env_vars.deinit();
        var iterator = env.iterator();
        while (iterator.next()) |entry| {
            try collectFreeTypeVarsInScheme(self.allocator, entry.value_ptr.*, &env_vars);
        }

        var quantified = std.ArrayListUnmanaged(u32){};
        defer quantified.deinit(self.allocator);
        var type_iterator = type_vars.iterator();
        while (type_iterator.next()) |entry| {
            if (!env_vars.contains(entry.key_ptr.*)) {
                try quantified.append(self.allocator, entry.key_ptr.*);
            }
        }

        return .{
            .quantified = try quantified.toOwnedSlice(self.allocator),
            .ty = applied,
        };
    }

    pub fn instantiate(self: *Engine, scheme: TypeScheme) !types.Type {
        var replacements = std.AutoHashMap(u32, types.Type).init(self.allocator);
        defer replacements.deinit();

        for (scheme.quantified) |id| {
            try replacements.put(id, self.freshTypeVar());
        }

        return try instantiateType(self.allocator, scheme.ty, &replacements);
    }

    pub fn resolveCallable(self: *Engine, callable: types.Type, args: []const types.Type) !types.Type {
        const return_type = try self.allocator.create(types.Type);
        return_type.* = self.freshTypeVar();

        const expected: types.Type = .{
            .function = .{
                .params = args,
                .return_type = return_type,
            },
        };
        try unify.unify(&self.substitution, callable, expected);
        return try self.applyType(return_type.*);
    }
};

fn cloneEnv(allocator: std.mem.Allocator, env: *const TypeEnv) !TypeEnv {
    var cloned = TypeEnv.init(allocator);
    var iterator = env.iterator();
    while (iterator.next()) |entry| {
        try cloned.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return cloned;
}

fn allConcrete(items: []const types.Type) bool {
    for (items) |item| {
        if (containsTypeVar(item)) return false;
    }
    return true;
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

fn instantiateType(
    allocator: std.mem.Allocator,
    ty: types.Type,
    replacements: *const std.AutoHashMap(u32, types.Type),
) !types.Type {
    return switch (ty) {
        .type_var => |id| replacements.get(id) orelse ty,
        .function => |function| blk: {
            const params = try allocator.alloc(types.Type, function.params.len);
            for (function.params, 0..) |param, index| {
                params[index] = try instantiateType(allocator, param, replacements);
            }
            const return_type = try allocator.create(types.Type);
            return_type.* = try instantiateType(allocator, function.return_type.*, replacements);
            break :blk .{
                .function = .{
                    .params = params,
                    .return_type = return_type,
                },
            };
        },
        .type_app => |app_ty| blk: {
            const args = try allocator.alloc(types.Type, app_ty.args.len);
            for (app_ty.args, 0..) |arg, index| {
                args[index] = try instantiateType(allocator, arg, replacements);
            }
            break :blk .{
                .type_app = .{
                    .name = app_ty.name,
                    .args = args,
                },
            };
        },
        else => ty,
    };
}

fn collectFreeTypeVars(ty: types.Type, vars: *std.AutoHashMap(u32, void)) !void {
    switch (ty) {
        .type_var => |id| try vars.put(id, {}),
        .function => |function| {
            for (function.params) |param| {
                try collectFreeTypeVars(param, vars);
            }
            try collectFreeTypeVars(function.return_type.*, vars);
        },
        .type_app => |app_ty| {
            for (app_ty.args) |arg| {
                try collectFreeTypeVars(arg, vars);
            }
        },
        else => {},
    }
}

fn collectFreeTypeVarsInScheme(
    allocator: std.mem.Allocator,
    scheme: TypeScheme,
    vars: *std.AutoHashMap(u32, void),
) !void {
    var local = std.AutoHashMap(u32, void).init(allocator);
    defer local.deinit();
    try collectFreeTypeVars(scheme.ty, &local);

    var iterator = local.iterator();
    while (iterator.next()) |entry| {
        if (!containsU32(scheme.quantified, entry.key_ptr.*)) {
            try vars.put(entry.key_ptr.*, {});
        }
    }
}

fn containsU32(items: []const u32, needle: u32) bool {
    for (items) |item| {
        if (item == needle) return true;
    }
    return false;
}
