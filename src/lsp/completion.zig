const std = @import("std");

pub fn response(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "[{{\"label\":\"def\",\"kind\":14}},{{\"label\":\"let\",\"kind\":14}},{{\"label\":\"match\",\"kind\":14}},{{\"label\":\"Vec3\",\"kind\":7}},{{\"label\":\"normalize\",\"kind\":3}}]",
        .{},
    );
}
