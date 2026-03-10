const std = @import("std");

pub fn response(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var token_count: usize = 0;
    var iterator = std.mem.tokenizeAny(u8, source, " \n\r\t");
    while (iterator.next()) |_| token_count += 1;

    return try std.fmt.allocPrint(allocator, "{{\"data\":[0,0,0,0,{d}]}}", .{token_count});
}
