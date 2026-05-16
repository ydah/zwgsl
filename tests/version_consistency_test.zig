const std = @import("std");
const zwgsl = @import("zwgsl");

const BuildZon = struct {
    version: []const u8,
};

const PackageJson = struct {
    version: []const u8,
};

test "package manifests match zwgsl_version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const expected = std.mem.span(zwgsl.zwgsl_version());

    try expectBuildZonVersion(allocator, expected);
    try expectPackageVersion(allocator, "playground/package.json", expected);
    try expectPackageVersion(allocator, "editors/vscode/package.json", expected);
    try expectPackageVersion(allocator, "packages/compiler/package.json", expected);
    try expectPackageLockVersion(allocator, "playground/package-lock.json", expected);
}

fn expectBuildZonVersion(allocator: std.mem.Allocator, expected: []const u8) !void {
    const source = try std.fs.cwd().readFileAlloc(allocator, "build.zig.zon", 1 << 20);
    const source_z = try allocator.dupeZ(u8, source);
    const parsed = try std.zon.parse.fromSlice(BuildZon, allocator, source_z, null, .{
        .ignore_unknown_fields = true,
    });

    try std.testing.expectEqualStrings(expected, parsed.version);
}

fn expectPackageVersion(allocator: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    var parsed = try std.json.parseFromSlice(PackageJson, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings(expected, parsed.value.version);
}

fn expectPackageLockVersion(allocator: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();

    const top_level = jsonStringAt(parsed.value, &.{"version"}) orelse return error.MissingPackageLockVersion;
    try std.testing.expectEqualStrings(expected, top_level);

    const root_package = jsonStringAt(parsed.value, &.{ "packages", "", "version" }) orelse return error.MissingPackageLockRootVersion;
    try std.testing.expectEqualStrings(expected, root_package);
}

fn jsonStringAt(root: std.json.Value, path: []const []const u8) ?[]const u8 {
    var current = root;
    for (path) |segment| {
        current = switch (current) {
            .object => |object| object.get(segment) orelse return null,
            else => return null,
        };
    }
    return switch (current) {
        .string => |value| value,
        else => null,
    };
}
