const std = @import("std");
const token = @import("token.zig");

pub const Builtin = enum {
    float,
    int,
    uint,
    bool,
    vec2,
    vec3,
    vec4,
    ivec2,
    ivec3,
    ivec4,
    uvec2,
    uvec3,
    uvec4,
    bvec2,
    bvec3,
    bvec4,
    mat2,
    mat3,
    mat4,
    sampler2d,
    sampler_cube,
    sampler3d,
    void,
    error_type,
};

pub const Function = struct {
    params: []const Type,
    return_type: *const Type,
};

pub const Type = union(enum) {
    builtin: Builtin,
    struct_type: []const u8,
    function: Function,
    type_var: u32,

    pub fn eql(a: Type, b: Type) bool {
        return switch (a) {
            .builtin => |left| switch (b) {
                .builtin => |right| left == right,
                else => false,
            },
            .struct_type => |left| switch (b) {
                .struct_type => |right| std.mem.eql(u8, left, right),
                else => false,
            },
            .function => |left| switch (b) {
                .function => |right| blk: {
                    if (left.params.len != right.params.len) break :blk false;
                    for (left.params, right.params) |lhs_param, rhs_param| {
                        if (!lhs_param.eql(rhs_param)) break :blk false;
                    }
                    break :blk left.return_type.*.eql(right.return_type.*);
                },
                else => false,
            },
            .type_var => |left| switch (b) {
                .type_var => |right| left == right,
                else => false,
            },
        };
    }

    pub fn isBuiltin(self: Type, builtin: Builtin) bool {
        return switch (self) {
            .builtin => |value| value == builtin,
            else => false,
        };
    }

    pub fn isError(self: Type) bool {
        return self.isBuiltin(.error_type);
    }

    pub fn isVoid(self: Type) bool {
        return self.isBuiltin(.void);
    }

    pub fn glslName(self: Type) []const u8 {
        return switch (self) {
            .builtin => |builtin| switch (builtin) {
                .float => "float",
                .int => "int",
                .uint => "uint",
                .bool => "bool",
                .vec2 => "vec2",
                .vec3 => "vec3",
                .vec4 => "vec4",
                .ivec2 => "ivec2",
                .ivec3 => "ivec3",
                .ivec4 => "ivec4",
                .uvec2 => "uvec2",
                .uvec3 => "uvec3",
                .uvec4 => "uvec4",
                .bvec2 => "bvec2",
                .bvec3 => "bvec3",
                .bvec4 => "bvec4",
                .mat2 => "mat2",
                .mat3 => "mat3",
                .mat4 => "mat4",
                .sampler2d => "sampler2D",
                .sampler_cube => "samplerCube",
                .sampler3d => "sampler3D",
                .void => "void",
                .error_type => "__error__",
            },
            .struct_type => |name| name,
            .function => "__fn__",
            .type_var => "__tvar__",
        };
    }

    pub fn wgslName(self: Type) []const u8 {
        return switch (self) {
            .builtin => |builtin| switch (builtin) {
                .float => "f32",
                .int => "i32",
                .uint => "u32",
                .bool => "bool",
                .vec2 => "vec2f",
                .vec3 => "vec3f",
                .vec4 => "vec4f",
                .ivec2 => "vec2i",
                .ivec3 => "vec3i",
                .ivec4 => "vec4i",
                .uvec2 => "vec2u",
                .uvec3 => "vec3u",
                .uvec4 => "vec4u",
                .bvec2 => "vec2<bool>",
                .bvec3 => "vec3<bool>",
                .bvec4 => "vec4<bool>",
                .mat2 => "mat2x2f",
                .mat3 => "mat3x3f",
                .mat4 => "mat4x4f",
                .sampler2d => "texture_2d<f32>",
                .sampler_cube => "texture_cube<f32>",
                .sampler3d => "texture_3d<f32>",
                .void => "void",
                .error_type => "__error__",
            },
            .struct_type => |name| name,
            .function => "__fn__",
            .type_var => "__tvar__",
        };
    }

    pub fn componentType(self: Type) ?Type {
        return switch (self) {
            .builtin => |builtin| switch (builtin) {
                .float => builtinType(.float),
                .int => builtinType(.int),
                .uint => builtinType(.uint),
                .bool => builtinType(.bool),
                .vec2, .vec3, .vec4, .mat2, .mat3, .mat4 => builtinType(.float),
                .ivec2, .ivec3, .ivec4 => builtinType(.int),
                .uvec2, .uvec3, .uvec4 => builtinType(.uint),
                .bvec2, .bvec3, .bvec4 => builtinType(.bool),
                else => null,
            },
            else => null,
        };
    }

    pub fn vectorLen(self: Type) ?u8 {
        return switch (self) {
            .builtin => |builtin| switch (builtin) {
                .vec2, .ivec2, .uvec2, .bvec2 => 2,
                .vec3, .ivec3, .uvec3, .bvec3 => 3,
                .vec4, .ivec4, .uvec4, .bvec4 => 4,
                else => null,
            },
            else => null,
        };
    }

    pub fn matrixLen(self: Type) ?u8 {
        return switch (self) {
            .builtin => |builtin| switch (builtin) {
                .mat2 => 2,
                .mat3 => 3,
                .mat4 => 4,
                else => null,
            },
            else => null,
        };
    }

    pub fn isScalar(self: Type) bool {
        return switch (self) {
            .builtin => |builtin| switch (builtin) {
                .float, .int, .uint, .bool => true,
                else => false,
            },
            else => false,
        };
    }

    pub fn isFunction(self: Type) bool {
        return self == .function;
    }

    pub fn isVector(self: Type) bool {
        return self.vectorLen() != null;
    }

    pub fn isMatrix(self: Type) bool {
        return self.matrixLen() != null;
    }

    pub fn isSampler(self: Type) bool {
        return switch (self) {
            .builtin => |builtin| switch (builtin) {
                .sampler2d, .sampler_cube, .sampler3d => true,
                else => false,
            },
            else => false,
        };
    }

    pub fn isNumeric(self: Type) bool {
        return switch (self) {
            .builtin => |builtin| switch (builtin) {
                .float,
                .int,
                .uint,
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
                => true,
                else => false,
            },
            else => false,
        };
    }

    pub fn isFloatFamily(self: Type) bool {
        return switch (self) {
            .builtin => |builtin| switch (builtin) {
                .float, .vec2, .vec3, .vec4, .mat2, .mat3, .mat4 => true,
                else => false,
            },
            else => false,
        };
    }
};

pub fn builtinType(value: Builtin) Type {
    return .{ .builtin = value };
}

pub fn typeVar(id: u32) Type {
    return .{ .type_var = id };
}

pub fn fromName(name: []const u8) ?Type {
    return mapName(name, true);
}

pub fn fromConstructorName(name: []const u8) ?Type {
    return mapName(name, false);
}

fn mapName(name: []const u8, title_case: bool) ?Type {
    const map = if (title_case)
        std.StaticStringMap(Type).initComptime(.{
            .{ "Float", builtinType(.float) },
            .{ "Int", builtinType(.int) },
            .{ "UInt", builtinType(.uint) },
            .{ "Bool", builtinType(.bool) },
            .{ "Vec2", builtinType(.vec2) },
            .{ "Vec3", builtinType(.vec3) },
            .{ "Vec4", builtinType(.vec4) },
            .{ "IVec2", builtinType(.ivec2) },
            .{ "IVec3", builtinType(.ivec3) },
            .{ "IVec4", builtinType(.ivec4) },
            .{ "UVec2", builtinType(.uvec2) },
            .{ "UVec3", builtinType(.uvec3) },
            .{ "UVec4", builtinType(.uvec4) },
            .{ "BVec2", builtinType(.bvec2) },
            .{ "BVec3", builtinType(.bvec3) },
            .{ "BVec4", builtinType(.bvec4) },
            .{ "Mat2", builtinType(.mat2) },
            .{ "Mat3", builtinType(.mat3) },
            .{ "Mat4", builtinType(.mat4) },
            .{ "Sampler2D", builtinType(.sampler2d) },
            .{ "SamplerCube", builtinType(.sampler_cube) },
            .{ "Sampler3D", builtinType(.sampler3d) },
            .{ "Void", builtinType(.void) },
        })
    else
        std.StaticStringMap(Type).initComptime(.{
            .{ "float", builtinType(.float) },
            .{ "int", builtinType(.int) },
            .{ "uint", builtinType(.uint) },
            .{ "bool", builtinType(.bool) },
            .{ "vec2", builtinType(.vec2) },
            .{ "vec3", builtinType(.vec3) },
            .{ "vec4", builtinType(.vec4) },
            .{ "ivec2", builtinType(.ivec2) },
            .{ "ivec3", builtinType(.ivec3) },
            .{ "ivec4", builtinType(.ivec4) },
            .{ "uvec2", builtinType(.uvec2) },
            .{ "uvec3", builtinType(.uvec3) },
            .{ "uvec4", builtinType(.uvec4) },
            .{ "bvec2", builtinType(.bvec2) },
            .{ "bvec3", builtinType(.bvec3) },
            .{ "bvec4", builtinType(.bvec4) },
            .{ "mat2", builtinType(.mat2) },
            .{ "mat3", builtinType(.mat3) },
            .{ "mat4", builtinType(.mat4) },
        });
    return map.get(name);
}

pub fn isValidSwizzle(base_type: Type, swizzle: []const u8) ?Type {
    const length = base_type.vectorLen() orelse return null;
    if (swizzle.len == 0 or swizzle.len > 4) return null;

    var family: enum { xyzw, rgba, none } = .none;
    for (swizzle) |ch| {
        const index, const next_family = switch (ch) {
            'x' => .{ @as(u8, 0), @as(@TypeOf(family), .xyzw) },
            'y' => .{ @as(u8, 1), .xyzw },
            'z' => .{ @as(u8, 2), .xyzw },
            'w' => .{ @as(u8, 3), .xyzw },
            'r' => .{ @as(u8, 0), .rgba },
            'g' => .{ @as(u8, 1), .rgba },
            'b' => .{ @as(u8, 2), .rgba },
            'a' => .{ @as(u8, 3), .rgba },
            else => return null,
        };
        if (family != .none and family != next_family) return null;
        if (index >= length) return null;
        family = next_family;
    }

    if (swizzle.len == 1) return base_type.componentType();
    const component = base_type.componentType() orelse return null;
    return vectorTypeForComponent(component, @intCast(swizzle.len));
}

pub fn isAssignable(target: Type, source: Type) bool {
    if (target.isError() or source.isError()) return true;
    return target.eql(source);
}

pub fn resolveOp(op: token.TokenTag, lhs: Type, rhs: Type) ?Type {
    if (lhs.isError() or rhs.isError()) return builtinType(.error_type);

    switch (op) {
        .and_and, .or_or => {
            if (lhs.isBuiltin(.bool) and rhs.isBuiltin(.bool)) return builtinType(.bool);
            return null;
        },
        .eq, .neq => {
            if (lhs.eql(rhs)) return builtinType(.bool);
            return null;
        },
        .lt, .gt, .le, .ge => {
            if (lhs.isScalar() and rhs.isScalar() and lhs.isNumeric() and rhs.isNumeric() and lhs.eql(rhs)) {
                return builtinType(.bool);
            }
            return null;
        },
        .plus, .minus => {
            if (lhs.eql(rhs) and lhs.isNumeric()) return lhs;
            if (lhs.isVector() and rhs.isScalar() and lhs.componentType().?.eql(rhs)) return lhs;
            if (rhs.isVector() and lhs.isScalar() and rhs.componentType().?.eql(lhs)) return rhs;
            if (lhs.isMatrix() and rhs.isScalar() and lhs.componentType().?.eql(rhs)) return lhs;
            if (rhs.isMatrix() and lhs.isScalar() and rhs.componentType().?.eql(lhs)) return rhs;
            return null;
        },
        .star, .slash => {
            if (lhs.eql(rhs) and lhs.isNumeric()) return lhs;
            if (lhs.isVector() and rhs.isScalar() and lhs.componentType().?.eql(rhs)) return lhs;
            if (rhs.isVector() and lhs.isScalar() and rhs.componentType().?.eql(lhs)) return rhs;
            if (lhs.isMatrix() and rhs.isScalar() and lhs.componentType().?.eql(rhs)) return lhs;
            if (rhs.isMatrix() and lhs.isScalar() and rhs.componentType().?.eql(lhs)) return rhs;
            if (op == .star and lhs.isMatrix() and rhs.isVector() and lhs.componentType().?.eql(rhs.componentType().?) and lhs.matrixLen() == rhs.vectorLen()) {
                return rhs;
            }
            if (op == .star and lhs.isMatrix() and rhs.isMatrix() and lhs.eql(rhs)) return lhs;
            return null;
        },
        .percent => {
            if (lhs.eql(rhs) and lhs.isNumeric()) return lhs;
            return null;
        },
        else => return null,
    }
}

pub fn vectorTypeForComponent(component: Type, len: u8) ?Type {
    return switch (component) {
        .builtin => |builtin| switch (builtin) {
            .float => switch (len) {
                2 => builtinType(.vec2),
                3 => builtinType(.vec3),
                4 => builtinType(.vec4),
                else => null,
            },
            .int => switch (len) {
                2 => builtinType(.ivec2),
                3 => builtinType(.ivec3),
                4 => builtinType(.ivec4),
                else => null,
            },
            .uint => switch (len) {
                2 => builtinType(.uvec2),
                3 => builtinType(.uvec3),
                4 => builtinType(.uvec4),
                else => null,
            },
            .bool => switch (len) {
                2 => builtinType(.bvec2),
                3 => builtinType(.bvec3),
                4 => builtinType(.bvec4),
                else => null,
            },
            else => null,
        },
        else => null,
    };
}
