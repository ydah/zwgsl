const std = @import("std");

pub const Kind = enum {
    @"error",
    warning,
};

pub const Diagnostic = struct {
    kind: Kind,
    message: []const u8,
    line: u32,
    column: u32,

    pub fn formatOwned(
        self: Diagnostic,
        allocator: std.mem.Allocator,
        source: []const u8,
    ) ![]u8 {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(allocator);

        try self.write(buffer.writer(allocator), source);
        return try buffer.toOwnedSlice(allocator);
    }

    pub fn write(self: Diagnostic, writer: anytype, source: []const u8) !void {
        try writer.print("{s}: {s}\n", .{ @tagName(self.kind), self.message });

        if (self.line == 0 or self.column == 0) return;
        const line_text = sourceLine(source, self.line) orelse return;

        try writer.print("  --> {d}:{d}\n", .{ self.line, self.column });
        try writer.writeAll("   |\n");
        try writer.print("{d} | {s}\n", .{ self.line, line_text });
        try writer.writeAll("   | ");

        const caret_offset = @min(columnOffset(line_text, self.column), line_text.len);
        for (0..caret_offset) |index| {
            try writer.writeByte(if (line_text[index] == '\t') '\t' else ' ');
        }
        try writer.writeAll("^\n");
    }
};

pub const DiagnosticList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Diagnostic) = .{},

    pub fn init(allocator: std.mem.Allocator) DiagnosticList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DiagnosticList) void {
        self.items.deinit(self.allocator);
    }

    pub fn append(self: *DiagnosticList, diagnostic: Diagnostic) !void {
        try self.items.append(self.allocator, diagnostic);
    }

    pub fn appendMessage(
        self: *DiagnosticList,
        kind: Kind,
        line: u32,
        column: u32,
        message: []const u8,
    ) !void {
        try self.append(.{
            .kind = kind,
            .message = message,
            .line = line,
            .column = column,
        });
    }

    pub fn appendFmt(
        self: *DiagnosticList,
        kind: Kind,
        line: u32,
        column: u32,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.appendMessage(kind, line, column, message);
    }

    pub fn toOwnedSlice(self: *DiagnosticList) ![]Diagnostic {
        return try self.items.toOwnedSlice(self.allocator);
    }

    pub fn formatAllOwned(self: *const DiagnosticList, source: []const u8) ![]u8 {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(self.allocator);

        for (self.items.items, 0..) |item, index| {
            if (index != 0) try buffer.append(self.allocator, '\n');
            try item.write(buffer.writer(self.allocator), source);
        }

        return try buffer.toOwnedSlice(self.allocator);
    }
};

fn sourceLine(source: []const u8, line_number: u32) ?[]const u8 {
    if (line_number == 0) return null;

    var current_line: u32 = 1;
    var start: usize = 0;
    var index: usize = 0;

    while (index <= source.len) : (index += 1) {
        if (index == source.len or source[index] == '\n') {
            if (current_line == line_number) {
                var end = index;
                if (end > start and source[end - 1] == '\r') end -= 1;
                return source[start..end];
            }

            current_line += 1;
            start = index + 1;
        }
    }

    return null;
}

fn columnOffset(line_text: []const u8, column: u32) usize {
    if (column <= 1) return 0;
    return @min(@as(usize, column - 1), line_text.len);
}
