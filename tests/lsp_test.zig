const std = @import("std");
const lsp = @import("zwgsl_lsp");

const completion = lsp.completion;
const goto_def = lsp.goto_def;
const handler = lsp.handler;
const hover = lsp.hover;
const protocol = lsp.protocol;
const semantic_tokens = lsp.semantic_tokens;

test "lsp protocol writes content length framed messages" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    try protocol.writeMessage(buffer.writer(std.testing.allocator), "{\"jsonrpc\":\"2.0\"}");
    const framed = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(framed);

    try std.testing.expect(std.mem.startsWith(u8, framed, "Content-Length: 17\r\n\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, framed, "{\"jsonrpc\":\"2.0\"}"));
}

test "lsp initialize advertises hover completion definition and semantic tokens" {
    var state = handler.State.init(std.testing.allocator);
    defer state.deinit();

    const response = (try handler.handle(
        std.testing.allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
    )).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"hoverProvider\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"completionProvider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"definitionProvider\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"semanticTokensProvider\"") != null);
}

test "lsp didOpen publishes diagnostics" {
    var state = handler.State.init(std.testing.allocator);
    defer state.deinit();

    const source =
        \\vertex do
        \\  def main
        \\    gl_Position = vec4(position, 1.0)
        \\  end
    ;
    const escaped_source = try jsonString(std.testing.allocator, source);
    defer std.testing.allocator.free(escaped_source);
    const message = try std.mem.concat(
        std.testing.allocator,
        u8,
        &.{
            "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///shader.zw\",\"text\":",
            escaped_source,
            "}}}",
        },
    );
    defer std.testing.allocator.free(message);

    const response = (try handler.handle(std.testing.allocator, &state, message)).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"textDocument/publishDiagnostics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "expected 'end'") != null);
}

test "lsp didClose clears published diagnostics" {
    var state = handler.State.init(std.testing.allocator);
    defer state.deinit();

    const source =
        \\vertex do
        \\  def main
        \\    gl_Position = vec4(position, 1.0)
        \\  end
    ;
    const escaped_source = try jsonString(std.testing.allocator, source);
    defer std.testing.allocator.free(escaped_source);

    const open_message = try std.mem.concat(
        std.testing.allocator,
        u8,
        &.{
            "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///shader.zw\",\"text\":",
            escaped_source,
            "}}}",
        },
    );
    defer std.testing.allocator.free(open_message);

    const open_response = (try handler.handle(std.testing.allocator, &state, open_message)).?;
    defer std.testing.allocator.free(open_response);
    try std.testing.expect(std.mem.indexOf(u8, open_response, "\"diagnostics\":[") != null);

    const close_response = (try handler.handle(
        std.testing.allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///shader.zw\"}}}",
    )).?;
    defer std.testing.allocator.free(close_response);

    try std.testing.expect(std.mem.indexOf(u8, close_response, "\"textDocument/publishDiagnostics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, close_response, "\"diagnostics\":[]") != null);
}

test "lsp hover returns builtin and inferred type information" {
    const source =
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\
        \\  def shade(pos: Vec3) -> Vec3
        \\    let normal = normalize(pos)
        \\    normal
        \\  end
        \\end
    ;

    const builtin_hover = try hover.response(std.testing.allocator, source, 4, 18);
    defer std.testing.allocator.free(builtin_hover);
    try std.testing.expect(std.mem.indexOf(u8, builtin_hover, "normalize") != null);
    try std.testing.expect(std.mem.indexOf(u8, builtin_hover, "Vec(N)") != null);

    const local_hover = try hover.response(std.testing.allocator, source, 5, 6);
    defer std.testing.allocator.free(local_hover);
    try std.testing.expect(std.mem.indexOf(u8, local_hover, "Vec3") != null);
}

test "lsp completion offers member and root suggestions" {
    const source =
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\
        \\  def shade(pos: Vec3) -> Vec3
        \\    let normal = normalize(pos)
        \\    normal.
        \\  end
        \\end
    ;

    const member = try completion.response(std.testing.allocator, source, 5, 11);
    defer std.testing.allocator.free(member);
    try std.testing.expect(std.mem.indexOf(u8, member, "\"xyz\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, member, "\"normalize\"") != null);

    const root = try completion.response(std.testing.allocator, source, 4, 8);
    defer std.testing.allocator.free(root);
    try std.testing.expect(std.mem.indexOf(u8, root, "\"position\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, root, "\"normalize\"") != null);
}

test "lsp definition jumps to local function definitions" {
    const source =
        \\def helper(v: Vec3) -> Vec3
        \\  normalize(v)
        \\end
        \\
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\
        \\  def shade(pos: Vec3) -> Vec3
        \\    helper(pos)
        \\  end
        \\end
    ;

    const response = try goto_def.response(std.testing.allocator, "file:///shader.zw", source, 8, 7);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"line\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"uri\":\"file:///shader.zw\"") != null);
}

test "lsp semantic tokens classify keywords comments and properties" {
    const source =
        \\# comment
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  def shade(pos: Vec3) -> Vec3
        \\    pos.xyz
        \\  end
        \\end
    ;

    const response = try semantic_tokens.response(std.testing.allocator, source);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, ",7,0") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, ",9,0") != null);
}

fn jsonString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    try buffer.append(allocator, '"');
    for (value) |ch| switch (ch) {
        '\\' => try buffer.appendSlice(allocator, "\\\\"),
        '"' => try buffer.appendSlice(allocator, "\\\""),
        '\n' => try buffer.appendSlice(allocator, "\\n"),
        '\r' => try buffer.appendSlice(allocator, "\\r"),
        '\t' => try buffer.appendSlice(allocator, "\\t"),
        else => try buffer.append(allocator, ch),
    };
    try buffer.append(allocator, '"');
    return try buffer.toOwnedSlice(allocator);
}
