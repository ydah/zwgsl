const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");

pub const TraitMethod = struct {
    name: []const u8,
    params: []const types.Type,
    return_type: types.Type,
};

pub const TraitDef = struct {
    name: []const u8,
    methods: []const TraitMethod,
};

pub const TraitImpl = struct {
    trait_name: []const u8,
    for_type: types.Type,
    methods: []const TraitImplMethod,
};

pub const TraitImplMethod = struct {
    name: []const u8,
    function: *ast.FunctionDef,
    mangled_name: []const u8,
    params: []const types.Type,
    return_type: types.Type,
};

pub const TraitRegistry = struct {
    allocator: std.mem.Allocator,
    traits: std.StringHashMap(TraitDef),
    impls: std.ArrayListUnmanaged(TraitImpl) = .{},

    pub fn init(allocator: std.mem.Allocator) TraitRegistry {
        return .{
            .allocator = allocator,
            .traits = std.StringHashMap(TraitDef).init(allocator),
        };
    }

    pub fn deinit(self: *TraitRegistry) void {
        self.traits.deinit();
        self.impls.deinit(self.allocator);
    }

    pub fn hasImpl(self: *const TraitRegistry, trait_name: []const u8, ty: types.Type) bool {
        return self.findImpl(trait_name, ty) != null;
    }

    pub fn findTrait(self: *const TraitRegistry, name: []const u8) ?TraitDef {
        return self.traits.get(name);
    }

    pub fn findTraitMethod(self: *const TraitRegistry, trait_name: []const u8, method_name: []const u8) ?TraitMethod {
        const trait_def = self.traits.get(trait_name) orelse return null;
        for (trait_def.methods) |method| {
            if (std.mem.eql(u8, method.name, method_name)) return method;
        }
        return null;
    }

    pub fn findImpl(self: *const TraitRegistry, trait_name: []const u8, ty: types.Type) ?TraitImpl {
        for (self.impls.items) |impl_info| {
            if (std.mem.eql(u8, impl_info.trait_name, trait_name) and impl_info.for_type.eql(ty)) {
                return impl_info;
            }
        }
        return null;
    }

    pub fn findImplMethod(
        self: *const TraitRegistry,
        trait_name: []const u8,
        ty: types.Type,
        method_name: []const u8,
    ) ?TraitImplMethod {
        const impl_info = self.findImpl(trait_name, ty) orelse return null;
        for (impl_info.methods) |method| {
            if (std.mem.eql(u8, method.name, method_name)) return method;
        }
        return null;
    }
};

pub fn mangleImplMethodName(
    allocator: std.mem.Allocator,
    trait_name: []const u8,
    receiver_type: types.Type,
    method_name: []const u8,
) ![]const u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer buffer.deinit(allocator);

    const writer = buffer.writer(allocator);
    try writer.print("__trait_{s}_", .{trait_name});
    try appendTypeMangle(writer, receiver_type);
    try writer.print("_{s}", .{method_name});
    return try buffer.toOwnedSlice(allocator);
}

fn appendTypeMangle(writer: anytype, ty: types.Type) !void {
    switch (ty) {
        .builtin => |builtin| try writer.writeAll(switch (builtin) {
            .float => "Float",
            .int => "Int",
            .uint => "UInt",
            .bool => "Bool",
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
