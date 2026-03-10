const std = @import("std");
const completion = @import("completion.zig");
const diagnostics = @import("diagnostics.zig");
const document_store = @import("document_store.zig");
const goto_def = @import("goto_def.zig");
const hover = @import("hover.zig");
const semantic_tokens = @import("semantic_tokens.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    store: document_store.DocumentStore,
    shutdown_requested: bool = false,
    should_exit: bool = false,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .allocator = allocator,
            .store = document_store.DocumentStore.init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.store.deinit();
    }
};

pub fn handle(allocator: std.mem.Allocator, state: *State, message: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, message, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const method = root.get("method") orelse return null;
    const method_name = method.string;
    const id_value = root.get("id");
    const params = root.get("params");

    if (std.mem.eql(u8, method_name, "initialize")) {
        return try response(allocator, id_value, "{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\".\"]},\"definitionProvider\":true,\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"keyword\",\"function\",\"variable\",\"parameter\",\"type\",\"number\",\"string\",\"comment\",\"operator\",\"property\"],\"tokenModifiers\":[]},\"full\":true}}}");
    }
    if (std.mem.eql(u8, method_name, "shutdown")) {
        state.shutdown_requested = true;
        return try response(allocator, id_value, "null");
    }
    if (std.mem.eql(u8, method_name, "exit")) {
        state.should_exit = true;
        return null;
    }
    if (std.mem.eql(u8, method_name, "initialized")) return null;

    if (std.mem.eql(u8, method_name, "textDocument/didOpen")) {
        const uri = nestedString(params.?, &.{ "textDocument", "uri" }) orelse return null;
        const text = nestedString(params.?, &.{ "textDocument", "text" }) orelse return null;
        try state.store.put(uri, text);
        return try diagnostics.publish(allocator, uri, text);
    }
    if (std.mem.eql(u8, method_name, "textDocument/didChange")) {
        const uri = nestedString(params.?, &.{ "textDocument", "uri" }) orelse return null;
        const changes = params.?.object.get("contentChanges") orelse return null;
        const change_text = changes.array.items[0].object.get("text") orelse return null;
        try state.store.put(uri, change_text.string);
        return try diagnostics.publish(allocator, uri, change_text.string);
    }
    if (std.mem.eql(u8, method_name, "textDocument/didClose")) {
        const uri = nestedString(params.?, &.{ "textDocument", "uri" }) orelse return null;
        state.store.remove(uri);
        return try diagnostics.clear(allocator, uri);
    }

    const uri = nestedString(params orelse return null, &.{ "textDocument", "uri" }) orelse return null;
    const source = state.store.get(uri) orelse "";

    if (std.mem.eql(u8, method_name, "textDocument/hover")) {
        const line = nestedU32(params.?, &.{ "position", "line" }) orelse 0;
        const character = nestedU32(params.?, &.{ "position", "character" }) orelse 0;
        const result = try hover.response(allocator, source, line, character);
        return try responseOwned(allocator, id_value, result);
    }
    if (std.mem.eql(u8, method_name, "textDocument/completion")) {
        const line = nestedU32(params.?, &.{ "position", "line" }) orelse 0;
        const character = nestedU32(params.?, &.{ "position", "character" }) orelse 0;
        const result = try completion.response(allocator, source, line, character);
        return try responseOwned(allocator, id_value, result);
    }
    if (std.mem.eql(u8, method_name, "textDocument/definition")) {
        const line = nestedU32(params.?, &.{ "position", "line" }) orelse 0;
        const character = nestedU32(params.?, &.{ "position", "character" }) orelse 0;
        const result = try goto_def.response(allocator, uri, source, line, character);
        return try responseOwned(allocator, id_value, result);
    }
    if (std.mem.eql(u8, method_name, "textDocument/semanticTokens/full")) {
        const result = try semantic_tokens.response(allocator, source);
        return try responseOwned(allocator, id_value, result);
    }

    return if (id_value != null) try response(allocator, id_value, "null") else null;
}

fn response(allocator: std.mem.Allocator, id_value: ?std.json.Value, result_json: []const u8) ![]u8 {
    if (id_value == null) return try allocator.dupe(u8, result_json);
    const id_json = try jsonValue(allocator, id_value.?);
    defer allocator.free(id_json);
    return try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id_json, result_json },
    );
}

fn responseOwned(allocator: std.mem.Allocator, id_value: ?std.json.Value, result_json: []u8) ![]u8 {
    defer allocator.free(result_json);
    return try response(allocator, id_value, result_json);
}

fn jsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);
    switch (value) {
        .string => |item| try writeJsonString(writer, item),
        .integer => |item| try writer.print("{d}", .{item}),
        .float => |item| try writer.print("{d}", .{item}),
        .bool => |item| try writer.writeAll(if (item) "true" else "false"),
        .null => try writer.writeAll("null"),
        else => try writer.writeAll("null"),
    }
    return try buffer.toOwnedSlice(allocator);
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| switch (ch) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(ch),
    };
    try writer.writeByte('"');
}

fn nestedString(root: std.json.Value, path: []const []const u8) ?[]const u8 {
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

fn nestedU32(root: std.json.Value, path: []const []const u8) ?u32 {
    var current = root;
    for (path) |segment| {
        current = switch (current) {
            .object => |object| object.get(segment) orelse return null,
            else => return null,
        };
    }
    return switch (current) {
        .integer => |value| @intCast(value),
        else => null,
    };
}
