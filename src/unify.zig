const std = @import("std");
const types = @import("types.zig");

pub const Substitution = struct {
    allocator: std.mem.Allocator,
    bindings: std.AutoHashMap(u32, types.Type),

    pub fn init(allocator: std.mem.Allocator) Substitution {
        return .{
            .allocator = allocator,
            .bindings = std.AutoHashMap(u32, types.Type).init(allocator),
        };
    }

    pub fn deinit(self: *Substitution) void {
        self.bindings.deinit();
    }

    pub fn apply(self: *Substitution, ty: types.Type) !types.Type {
        return switch (ty) {
            .type_var => |id| if (self.bindings.get(id)) |bound| try self.apply(bound) else ty,
            .function => |function| blk: {
                const params = try self.allocator.alloc(types.Type, function.params.len);
                for (function.params, 0..) |param, index| {
                    params[index] = try self.apply(param);
                }

                const return_type = try self.allocator.create(types.Type);
                return_type.* = try self.apply(function.return_type.*);
                break :blk .{
                    .function = .{
                        .params = params,
                        .return_type = return_type,
                    },
                };
            },
            else => ty,
        };
    }

    fn bind(self: *Substitution, id: u32, ty: types.Type) !void {
        try self.bindings.put(id, ty);
    }

    fn occurs(self: *Substitution, needle: u32, ty: types.Type) !bool {
        const applied = try self.apply(ty);
        return switch (applied) {
            .type_var => |id| id == needle,
            .function => |function| blk: {
                for (function.params) |param| {
                    if (try self.occurs(needle, param)) break :blk true;
                }
                break :blk try self.occurs(needle, function.return_type.*);
            },
            else => false,
        };
    }
};

pub fn unify(substitution: *Substitution, lhs: types.Type, rhs: types.Type) !void {
    const left = try substitution.apply(lhs);
    const right = try substitution.apply(rhs);

    if (left.eql(right)) return;

    switch (left) {
        .type_var => |id| return bindVar(substitution, id, right),
        .function => |left_function| switch (right) {
            .function => |right_function| {
                if (left_function.params.len != right_function.params.len) {
                    return error.TypeMismatch;
                }
                for (left_function.params, right_function.params) |left_param, right_param| {
                    try unify(substitution, left_param, right_param);
                }
                try unify(substitution, left_function.return_type.*, right_function.return_type.*);
            },
            .type_var => |id| return bindVar(substitution, id, left),
            else => return error.TypeMismatch,
        },
        else => switch (right) {
            .type_var => |id| return bindVar(substitution, id, left),
            else => return error.TypeMismatch,
        },
    }
}

fn bindVar(substitution: *Substitution, id: u32, ty: types.Type) !void {
    if (ty == .type_var and ty.type_var == id) return;
    if (try substitution.occurs(id, ty)) return error.OccursCheckFailed;
    try substitution.bind(id, ty);
}
