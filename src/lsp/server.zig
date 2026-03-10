const std = @import("std");
const handler = @import("handler.zig");
const protocol = @import("protocol.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    var state = handler.State.init(allocator);
    defer state.deinit();

    var stdin_buffer: [4096]u8 = undefined;
    var stdout_buffer: [4096]u8 = undefined;
    var reader = std.fs.File.stdin().reader(&stdin_buffer).interface;
    var writer = std.fs.File.stdout().writer(&stdout_buffer).interface;

    while (!state.should_exit) {
        const body = protocol.readMessage(allocator, &reader) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        defer allocator.free(body);

        if (try handler.handle(allocator, &state, body)) |response| {
            defer allocator.free(response);
            try protocol.writeMessage(&writer, response);
            try writer.flush();
        }
    }
}
