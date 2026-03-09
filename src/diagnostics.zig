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
};
