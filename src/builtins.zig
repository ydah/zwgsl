const std = @import("std");
const types = @import("types.zig");

pub const Resolution = struct {
    return_type: types.Type,
    method_callable: bool = true,
};

pub fn resolve(name: []const u8, args: []const types.Type) ?Resolution {
    if (types.fromConstructorName(name)) |constructor_type| {
        return resolveConstructor(constructor_type, args);
    }

    if (std.mem.eql(u8, name, "normalize")) {
        if (args.len == 1 and args[0].isVector()) return .{ .return_type = args[0] };
        return null;
    }
    if (std.mem.eql(u8, name, "length")) {
        if (args.len == 1 and (args[0].isVector() or args[0].isScalar())) return .{ .return_type = types.builtinType(.float) };
        return null;
    }
    if (std.mem.eql(u8, name, "distance")) {
        if (args.len == 2 and args[0].eql(args[1]) and (args[0].isVector() or args[0].isScalar())) {
            return .{ .return_type = types.builtinType(.float) };
        }
        return null;
    }
    if (std.mem.eql(u8, name, "dot")) {
        if (args.len == 2 and args[0].eql(args[1]) and args[0].isVector()) {
            return .{ .return_type = types.builtinType(.float) };
        }
        return null;
    }
    if (std.mem.eql(u8, name, "cross")) {
        if (args.len == 2 and args[0].isBuiltin(.vec3) and args[1].isBuiltin(.vec3)) {
            return .{ .return_type = types.builtinType(.vec3) };
        }
        return null;
    }
    if (std.mem.eql(u8, name, "reflect")) {
        return resolveSameTypeVector(args);
    }
    if (std.mem.eql(u8, name, "refract")) {
        if (args.len == 3 and args[0].eql(args[1]) and args[0].isVector() and args[2].isBuiltin(.float)) {
            return .{ .return_type = args[0] };
        }
        return null;
    }
    if (std.mem.eql(u8, name, "mix")) {
        if (args.len == 3 and args[0].eql(args[1])) {
            if (args[2].eql(args[0]) or args[2].isScalar()) {
                return .{ .return_type = args[0] };
            }
        }
        return null;
    }
    if (std.mem.eql(u8, name, "clamp")) {
        if (args.len == 3 and args[0].eql(args[1]) and args[0].eql(args[2])) {
            return .{ .return_type = args[0] };
        }
        if (args.len == 3 and args[0].isVector() and args[1].isScalar() and args[2].isScalar() and args[0].componentType().?.eql(args[1]) and args[1].eql(args[2])) {
            return .{ .return_type = args[0] };
        }
        return null;
    }
    if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) {
        if (args.len == 2 and args[0].eql(args[1]) and args[0].isNumeric()) {
            return .{ .return_type = args[0] };
        }
        if (args.len == 2 and args[0].isVector() and args[1].isScalar() and args[0].componentType().?.eql(args[1])) {
            return .{ .return_type = args[0] };
        }
        return null;
    }
    if (std.mem.eql(u8, name, "abs") or
        std.mem.eql(u8, name, "sign") or
        std.mem.eql(u8, name, "floor") or
        std.mem.eql(u8, name, "ceil") or
        std.mem.eql(u8, name, "fract") or
        std.mem.eql(u8, name, "sqrt") or
        std.mem.eql(u8, name, "exp") or
        std.mem.eql(u8, name, "log") or
        std.mem.eql(u8, name, "sin") or
        std.mem.eql(u8, name, "cos") or
        std.mem.eql(u8, name, "tan") or
        std.mem.eql(u8, name, "asin") or
        std.mem.eql(u8, name, "acos"))
    {
        if (args.len == 1 and args[0].isNumeric()) return .{ .return_type = args[0] };
        return null;
    }
    if (std.mem.eql(u8, name, "mod") or std.mem.eql(u8, name, "pow") or std.mem.eql(u8, name, "step")) {
        if (args.len == 2 and args[0].eql(args[1]) and args[0].isNumeric()) return .{ .return_type = args[0] };
        if (args.len == 2 and args[0].isVector() and args[1].isScalar() and args[0].componentType().?.eql(args[1])) return .{ .return_type = args[0] };
        return null;
    }
    if (std.mem.eql(u8, name, "smoothstep")) {
        if (args.len == 3 and args[1].eql(args[2])) {
            if (args[0].eql(args[1])) return .{ .return_type = args[1] };
            if (args[1].isVector() and args[0].isScalar() and args[1].componentType().?.eql(args[0]) and args[0].eql(args[2].componentType().?)) {
                return .{ .return_type = args[1] };
            }
        }
        return null;
    }
    if (std.mem.eql(u8, name, "atan")) {
        if (args.len == 1 and args[0].isNumeric()) return .{ .return_type = args[0] };
        if (args.len == 2 and args[0].eql(args[1]) and args[0].isNumeric()) return .{ .return_type = args[0] };
        return null;
    }
    if (std.mem.eql(u8, name, "texture")) {
        if (args.len == 2 and args[0].isBuiltin(.sampler2d) and args[1].isBuiltin(.vec2)) {
            return .{ .return_type = types.builtinType(.vec4), .method_callable = false };
        }
        if (args.len == 2 and args[0].isBuiltin(.sampler_cube) and args[1].isBuiltin(.vec3)) {
            return .{ .return_type = types.builtinType(.vec4), .method_callable = false };
        }
        if (args.len == 2 and args[0].isBuiltin(.sampler3d) and args[1].isBuiltin(.vec3)) {
            return .{ .return_type = types.builtinType(.vec4), .method_callable = false };
        }
        return null;
    }

    return null;
}

pub fn resolveMethod(name: []const u8, receiver: types.Type, args: []const types.Type) ?Resolution {
    if (types.fromConstructorName(name) != null) return null;

    var buffer: [8]types.Type = undefined;
    if (args.len + 1 > buffer.len) return null;
    buffer[0] = receiver;
    @memcpy(buffer[1 .. args.len + 1], args);
    const resolved = resolve(name, buffer[0 .. args.len + 1]) orelse return null;
    if (!resolved.method_callable) return null;
    return resolved;
}

fn resolveSameTypeVector(args: []const types.Type) ?Resolution {
    if (args.len == 2 and args[0].eql(args[1]) and args[0].isVector()) {
        return .{ .return_type = args[0] };
    }
    return null;
}

fn resolveConstructor(target: types.Type, args: []const types.Type) ?Resolution {
    if (target.isVector()) {
        return resolveVectorConstructor(target, args);
    }
    if (target.isMatrix()) {
        return resolveMatrixConstructor(target, args);
    }
    if (target.isScalar()) {
        if (args.len == 1 and args[0].isScalar()) return .{ .return_type = target, .method_callable = false };
    }
    return null;
}

fn resolveVectorConstructor(target: types.Type, args: []const types.Type) ?Resolution {
    const target_component = target.componentType() orelse return null;
    const target_len = target.vectorLen() orelse return null;

    if (args.len == 1 and args[0].isScalar() and args[0].eql(target_component)) {
        return .{ .return_type = target, .method_callable = false };
    }

    var count: u8 = 0;
    for (args) |arg| {
        if (arg.isScalar()) {
            if (!arg.eql(target_component)) return null;
            count += 1;
            continue;
        }
        if (arg.isVector()) {
            if (!arg.componentType().?.eql(target_component)) return null;
            count += arg.vectorLen().?;
            continue;
        }
        return null;
    }

    if (count == target_len) {
        return .{ .return_type = target, .method_callable = false };
    }
    return null;
}

fn resolveMatrixConstructor(target: types.Type, args: []const types.Type) ?Resolution {
    const target_component = target.componentType() orelse return null;
    const target_len = target.matrixLen() orelse return null;

    if (args.len == 1) {
        if (args[0].isScalar() and args[0].eql(target_component)) return .{ .return_type = target, .method_callable = false };
        if (args[0].isMatrix() and args[0].componentType().?.eql(target_component)) return .{ .return_type = target, .method_callable = false };
    }

    var scalar_count: u8 = 0;
    for (args) |arg| {
        if (!arg.isScalar() or !arg.eql(target_component)) return null;
        scalar_count += 1;
    }

    if (scalar_count == target_len * target_len) {
        return .{ .return_type = target, .method_callable = false };
    }
    return null;
}
