const std = @import("std");

pub const StringPool = struct {
    allocator: std.mem.Allocator,
    strings: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) StringPool {
        return .{
            .allocator = allocator,
            .strings = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *StringPool) void {
        var iterator = self.strings.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.strings.deinit();
        self.* = undefined;
    }

    pub fn intern(self: *StringPool, value: []const u8) ![]const u8 {
        if (self.strings.get(value)) |existing| return existing;
        const duped = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(duped);

        try self.strings.put(duped, duped);
        return duped;
    }
};

test "string pool interns identical strings" {
    var pool = StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const a = try pool.intern("hello");
    const b = try pool.intern("hello");
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(a.ptr == b.ptr);
}
