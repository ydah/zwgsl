const std = @import("std");
const code_actions = @import("code_actions.zig");
const completion = @import("completion.zig");
const diagnostics = @import("diagnostics.zig");
const document_symbols = @import("document_symbols.zig");
const document_store = @import("document_store.zig");
const goto_def = @import("goto_def.zig");
const hover = @import("hover.zig");
const semantic_tokens = @import("semantic_tokens.zig");
const signature_help = @import("signature_help.zig");

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
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return try errorResponse(allocator, null, -32700, "Parse error", null),
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return try errorResponse(allocator, null, -32600, "Invalid Request", "Request must be a JSON object"),
    };
    const id_value = root.get("id");
    const method = root.get("method") orelse return try errorResponse(allocator, id_value, -32600, "Invalid Request", "Missing method");
    const method_name = switch (method) {
        .string => |value| value,
        else => return try errorResponse(allocator, id_value, -32600, "Invalid Request", "Method must be a string"),
    };
    const params = root.get("params");

    if (std.mem.eql(u8, method_name, "initialize")) {
        return try response(allocator, id_value, "{\"capabilities\":{\"textDocumentSync\":2,\"hoverProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\".\"]},\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]},\"codeActionProvider\":true,\"definitionProvider\":true,\"documentSymbolProvider\":true,\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"keyword\",\"function\",\"variable\",\"parameter\",\"type\",\"number\",\"string\",\"comment\",\"operator\",\"property\"],\"tokenModifiers\":[]},\"full\":true}}}");
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
        const request_params = params orelse return try invalidParamsOrNull(allocator, id_value, "Missing params");
        const uri = nestedString(request_params, &.{ "textDocument", "uri" }) orelse return try invalidParamsOrNull(allocator, id_value, "Missing textDocument.uri");
        const text = nestedString(request_params, &.{ "textDocument", "text" }) orelse return try invalidParamsOrNull(allocator, id_value, "Missing textDocument.text");
        try state.store.put(uri, text);
        return try diagnostics.publish(allocator, uri, text);
    }
    if (std.mem.eql(u8, method_name, "textDocument/didChange")) {
        const request_params = params orelse return try invalidParamsOrNull(allocator, id_value, "Missing params");
        const uri = nestedString(request_params, &.{ "textDocument", "uri" }) orelse return try invalidParamsOrNull(allocator, id_value, "Missing textDocument.uri");
        const changes = switch (request_params) {
            .object => |object| object.get("contentChanges") orelse return try invalidParamsOrNull(allocator, id_value, "Missing contentChanges"),
            else => return try invalidParamsOrNull(allocator, id_value, "Params must be an object"),
        };
        const change_items = switch (changes) {
            .array => |array| blk: {
                if (array.items.len == 0) return try invalidParamsOrNull(allocator, id_value, "Missing contentChanges[0]");
                break :blk array.items;
            },
            else => return try invalidParamsOrNull(allocator, id_value, "contentChanges must be an array"),
        };
        const text = applyContentChanges(allocator, state.store.get(uri) orelse "", change_items) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return try invalidParamsOrNull(allocator, id_value, contentChangeErrorMessage(err)),
        };
        defer allocator.free(text);
        try state.store.put(uri, text);
        return try diagnostics.publish(allocator, uri, text);
    }
    if (std.mem.eql(u8, method_name, "textDocument/didClose")) {
        const request_params = params orelse return try invalidParamsOrNull(allocator, id_value, "Missing params");
        const uri = nestedString(request_params, &.{ "textDocument", "uri" }) orelse return try invalidParamsOrNull(allocator, id_value, "Missing textDocument.uri");
        state.store.remove(uri);
        return try diagnostics.clear(allocator, uri);
    }

    if (std.mem.eql(u8, method_name, "textDocument/hover")) {
        const request_params = params orelse return try invalidParamsOrNull(allocator, id_value, "Missing params");
        const uri = nestedString(request_params, &.{ "textDocument", "uri" }) orelse return try invalidParamsOrNull(allocator, id_value, "Missing textDocument.uri");
        const source = state.store.get(uri) orelse "";
        const line = nestedU32(request_params, &.{ "position", "line" }) orelse 0;
        const character = nestedU32(request_params, &.{ "position", "character" }) orelse 0;
        const result = try hover.response(allocator, source, line, character);
        return try responseOwned(allocator, id_value, result);
    }
    if (std.mem.eql(u8, method_name, "textDocument/completion")) {
        const request_params = params orelse return try invalidParamsOrNull(allocator, id_value, "Missing params");
        const uri = nestedString(request_params, &.{ "textDocument", "uri" }) orelse return try invalidParamsOrNull(allocator, id_value, "Missing textDocument.uri");
        const source = state.store.get(uri) orelse "";
        const line = nestedU32(request_params, &.{ "position", "line" }) orelse 0;
        const character = nestedU32(request_params, &.{ "position", "character" }) orelse 0;
        const result = try completion.response(allocator, source, line, character);
        return try responseOwned(allocator, id_value, result);
    }
    if (std.mem.eql(u8, method_name, "textDocument/signatureHelp")) {
        const request_params = params orelse return try invalidParamsOrNull(allocator, id_value, "Missing params");
        const uri = nestedString(request_params, &.{ "textDocument", "uri" }) orelse return try invalidParamsOrNull(allocator, id_value, "Missing textDocument.uri");
        const source = state.store.get(uri) orelse "";
        const line = nestedU32(request_params, &.{ "position", "line" }) orelse 0;
        const character = nestedU32(request_params, &.{ "position", "character" }) orelse 0;
        const result = try signature_help.response(allocator, source, line, character);
        return try responseOwned(allocator, id_value, result);
    }
    if (std.mem.eql(u8, method_name, "textDocument/codeAction")) {
        const request_params = params orelse return try invalidParamsOrNull(allocator, id_value, "Missing params");
        const uri = nestedString(request_params, &.{ "textDocument", "uri" }) orelse return try invalidParamsOrNull(allocator, id_value, "Missing textDocument.uri");
        const source = state.store.get(uri) orelse "";
        const result = try code_actions.response(allocator, uri, source);
        return try responseOwned(allocator, id_value, result);
    }
    if (std.mem.eql(u8, method_name, "textDocument/definition")) {
        const request_params = params orelse return try invalidParamsOrNull(allocator, id_value, "Missing params");
        const uri = nestedString(request_params, &.{ "textDocument", "uri" }) orelse return try invalidParamsOrNull(allocator, id_value, "Missing textDocument.uri");
        const source = state.store.get(uri) orelse "";
        const line = nestedU32(request_params, &.{ "position", "line" }) orelse 0;
        const character = nestedU32(request_params, &.{ "position", "character" }) orelse 0;
        const result = try goto_def.response(allocator, uri, source, line, character);
        return try responseOwned(allocator, id_value, result);
    }
    if (std.mem.eql(u8, method_name, "textDocument/documentSymbol")) {
        const request_params = params orelse return try invalidParamsOrNull(allocator, id_value, "Missing params");
        const uri = nestedString(request_params, &.{ "textDocument", "uri" }) orelse return try invalidParamsOrNull(allocator, id_value, "Missing textDocument.uri");
        const source = state.store.get(uri) orelse "";
        const result = try document_symbols.response(allocator, source);
        return try responseOwned(allocator, id_value, result);
    }
    if (std.mem.eql(u8, method_name, "textDocument/semanticTokens/full")) {
        const request_params = params orelse return try invalidParamsOrNull(allocator, id_value, "Missing params");
        const uri = nestedString(request_params, &.{ "textDocument", "uri" }) orelse return try invalidParamsOrNull(allocator, id_value, "Missing textDocument.uri");
        const source = state.store.get(uri) orelse "";
        const result = try semantic_tokens.response(allocator, source);
        return try responseOwned(allocator, id_value, result);
    }

    return if (id_value != null) try methodNotFoundResponse(allocator, id_value.?, method_name) else null;
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

fn methodNotFoundResponse(allocator: std.mem.Allocator, id_value: std.json.Value, method_name: []const u8) ![]u8 {
    return try errorResponse(allocator, id_value, -32601, "Method not found", method_name);
}

fn invalidParamsOrNull(allocator: std.mem.Allocator, id_value: ?std.json.Value, message: []const u8) !?[]u8 {
    return if (id_value) |id| try errorResponse(allocator, id, -32602, "Invalid params", message) else null;
}

fn errorResponse(allocator: std.mem.Allocator, id_value: ?std.json.Value, code: i32, message: []const u8, data: ?[]const u8) ![]u8 {
    const id_json = if (id_value) |id| try jsonValue(allocator, id) else try allocator.dupe(u8, "null");
    defer allocator.free(id_json);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":",
        .{ id_json, code },
    );
    try writeJsonString(writer, message);
    if (data) |value| {
        try writer.writeAll(",\"data\":");
        try writeJsonString(writer, value);
    }
    try writer.writeAll("}}");
    return try buffer.toOwnedSlice(allocator);
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

fn applyContentChanges(
    allocator: std.mem.Allocator,
    original: []const u8,
    changes: []const std.json.Value,
) ![]u8 {
    var current = try allocator.dupe(u8, original);
    errdefer allocator.free(current);

    for (changes) |change| {
        const object = switch (change) {
            .object => |value| value,
            else => return error.ChangeMustBeObject,
        };
        const text_value = object.get("text") orelse return error.MissingChangeText;
        const replacement = switch (text_value) {
            .string => |value| value,
            else => return error.ChangeTextMustBeString,
        };

        if (object.get("range")) |range| {
            const start_line = nestedU32(range, &.{ "start", "line" }) orelse return error.InvalidChangeRange;
            const start_character = nestedU32(range, &.{ "start", "character" }) orelse return error.InvalidChangeRange;
            const end_line = nestedU32(range, &.{ "end", "line" }) orelse return error.InvalidChangeRange;
            const end_character = nestedU32(range, &.{ "end", "character" }) orelse return error.InvalidChangeRange;
            const start_offset = offsetForPosition(current, start_line, start_character) orelse return error.ChangeRangeOutOfBounds;
            const end_offset = offsetForPosition(current, end_line, end_character) orelse return error.ChangeRangeOutOfBounds;
            if (end_offset < start_offset) return error.ChangeRangeOutOfBounds;

            var buffer = try std.ArrayList(u8).initCapacity(
                allocator,
                current.len - (end_offset - start_offset) + replacement.len,
            );
            errdefer buffer.deinit(allocator);
            try buffer.appendSlice(allocator, current[0..start_offset]);
            try buffer.appendSlice(allocator, replacement);
            try buffer.appendSlice(allocator, current[end_offset..]);

            const next = try buffer.toOwnedSlice(allocator);
            allocator.free(current);
            current = next;
            continue;
        }

        const next = try allocator.dupe(u8, replacement);
        allocator.free(current);
        current = next;
    }

    return current;
}

fn offsetForPosition(source: []const u8, target_line: u32, target_character: u32) ?usize {
    var line: u32 = 0;
    var character: u32 = 0;
    var index: usize = 0;

    while (index < source.len) : (index += 1) {
        if (line == target_line and character == target_character) return index;
        if (source[index] == '\n') {
            line += 1;
            character = 0;
        } else {
            character += 1;
        }
    }

    if (line == target_line and character == target_character) return source.len;
    return null;
}

fn contentChangeErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ChangeMustBeObject => "contentChanges[0] must be an object",
        error.MissingChangeText => "Missing contentChanges[0].text",
        error.ChangeTextMustBeString => "contentChanges[0].text must be a string",
        error.InvalidChangeRange => "contentChanges[0].range must include start and end positions",
        error.ChangeRangeOutOfBounds => "contentChanges[0].range is outside the document",
        else => "Invalid contentChanges",
    };
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
