const std = @import("std");
const lsp = @import("zwgsl").lsp;

const analysis = lsp.analysis;
const code_actions = lsp.code_actions;
const completion = lsp.completion;
const document_symbols = lsp.document_symbols;
const goto_def = lsp.goto_def;
const handler = lsp.handler;
const hover = lsp.hover;
const protocol = lsp.protocol;
const rename = lsp.rename;
const semantic_tokens = lsp.semantic_tokens;
const signature_help = lsp.signature_help;

test "lsp protocol writes content length framed messages" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    try protocol.writeMessage(buffer.writer(std.testing.allocator), "{\"jsonrpc\":\"2.0\"}");
    const framed = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(framed);

    try std.testing.expect(std.mem.startsWith(u8, framed, "Content-Length: 17\r\n\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, framed, "{\"jsonrpc\":\"2.0\"}"));
}

test "lsp initialize advertises editor-facing capabilities" {
    var state = handler.State.init(std.testing.allocator);
    defer state.deinit();

    const response = (try handler.handle(
        std.testing.allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
    )).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"hoverProvider\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"textDocumentSync\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"completionProvider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"signatureHelpProvider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"codeActionProvider\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"definitionProvider\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"documentSymbolProvider\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"renameProvider\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"semanticTokensProvider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"uniform\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"builtin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"constructor\"") != null);
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

test "lsp unknown request returns method-not-found error" {
    var state = handler.State.init(std.testing.allocator);
    defer state.deinit();

    const response = (try handler.handle(
        std.testing.allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"workspace/unknown\",\"params\":{}}",
    )).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"data\":\"workspace/unknown\"") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response, .{});
    defer parsed.deinit();
}

test "lsp unknown notification is ignored" {
    var state = handler.State.init(std.testing.allocator);
    defer state.deinit();

    const response = try handler.handle(
        std.testing.allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"method\":\"workspace/unknown\",\"params\":{}}",
    );

    try std.testing.expect(response == null);
}

test "lsp malformed json returns parse error" {
    var state = handler.State.init(std.testing.allocator);
    defer state.deinit();

    const response = (try handler.handle(
        std.testing.allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"",
    )).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":-32700") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"message\":\"Parse error\"") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response, .{});
    defer parsed.deinit();
}

test "lsp invalid request returns invalid request error" {
    var state = handler.State.init(std.testing.allocator);
    defer state.deinit();

    const response = (try handler.handle(
        std.testing.allocator,
        &state,
        "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}]",
    )).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"data\":\"Request must be a JSON object\"") != null);
}

test "lsp invalid params returns error instead of trapping" {
    var state = handler.State.init(std.testing.allocator);
    defer state.deinit();

    const response = (try handler.handle(
        std.testing.allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///shader.zw\"},\"contentChanges\":[]}}",
    )).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":-32602") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"data\":\"Missing contentChanges[0]\"") != null);
}

test "lsp didChange applies incremental and full text changes" {
    var state = handler.State.init(std.testing.allocator);
    defer state.deinit();

    const source = "uniform :mvp, Mat4\n";
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

    const incremental_response = (try handler.handle(
        std.testing.allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///shader.zw\"},\"contentChanges\":[{\"range\":{\"start\":{\"line\":0,\"character\":9},\"end\":{\"line\":0,\"character\":12}},\"text\":\"model\"}]}}",
    )).?;
    defer std.testing.allocator.free(incremental_response);
    try std.testing.expectEqualStrings("uniform :model, Mat4\n", state.store.get("file:///shader.zw").?);

    const full_response = (try handler.handle(
        std.testing.allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///shader.zw\"},\"contentChanges\":[{\"text\":\"uniform :view, Mat4\\n\"}]}}",
    )).?;
    defer std.testing.allocator.free(full_response);
    try std.testing.expectEqualStrings("uniform :view, Mat4\n", state.store.get("file:///shader.zw").?);
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
    try std.testing.expect(std.mem.indexOf(u8, root, "\"vec4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, root, "fn vec4(x: Float, y: Float, z: Float, w: Float) -> Vec4") != null);
}

test "lsp completion and hover expose stage builtins in stage scope" {
    const vertex_source =
        \\vertex do
        \\  def main
        \\    gl_Position = vec4(0.0, 0.0, 0.0, 1.0)
        \\  end
        \\end
    ;
    const vertex_completion = try completion.response(std.testing.allocator, vertex_source, 2, 4);
    defer std.testing.allocator.free(vertex_completion);
    try std.testing.expect(std.mem.indexOf(u8, vertex_completion, "\"gl_Position\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, vertex_completion, "gl_Position: Vec4") != null);

    const compute_source =
        \\compute do
        \\  def main
        \\    id: UVec3 = global_invocation_id
        \\  end
        \\end
    ;
    const compute_completion = try completion.response(std.testing.allocator, compute_source, 2, 16);
    defer std.testing.allocator.free(compute_completion);
    try std.testing.expect(std.mem.indexOf(u8, compute_completion, "\"global_invocation_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compute_completion, "\"local_invocation_index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compute_completion, "\"gl_Position\"") == null);

    const compute_hover = try hover.response(std.testing.allocator, compute_source, 2, 18);
    defer std.testing.allocator.free(compute_hover);
    try std.testing.expect(std.mem.indexOf(u8, compute_hover, "UVec3") != null);
    try std.testing.expect(std.mem.indexOf(u8, compute_hover, "Global invocation id for compute shaders.") != null);
}

test "lsp signature help returns user function and builtin constructor signatures" {
    const source =
        \\def shade(pos: Vec3, amount: Float) -> Vec3
        \\  pos
        \\end
        \\
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  def main
        \\    color = shade(position, 0.5)
        \\    gl_Position = vec4(position, 1.0)
        \\  end
        \\end
    ;

    const user_signature = try signature_help.response(std.testing.allocator, source, 7, 28);
    defer std.testing.allocator.free(user_signature);
    try std.testing.expect(std.mem.indexOf(u8, user_signature, "def shade(pos: Vec3, amount: Float) -> Vec3") != null);
    try std.testing.expect(std.mem.indexOf(u8, user_signature, "\"activeParameter\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, user_signature, "\"label\":\"amount: Float\"") != null);

    const constructor_signature = try signature_help.response(std.testing.allocator, source, 8, 23);
    defer std.testing.allocator.free(constructor_signature);
    try std.testing.expect(std.mem.indexOf(u8, constructor_signature, "fn vec4(x: Float, y: Float, z: Float, w: Float) -> Vec4") != null);
    try std.testing.expect(std.mem.indexOf(u8, constructor_signature, "\"activeParameter\":0") != null);
}

test "lsp handler serves signature help from open documents" {
    var state = handler.State.init(std.testing.allocator);
    defer state.deinit();

    const source =
        \\def shade(pos: Vec3, amount: Float) -> Vec3
        \\  pos
        \\end
        \\
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  def main
        \\    color = shade(position, 0.5)
        \\  end
        \\end
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

    const response = (try handler.handle(
        std.testing.allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"textDocument/signatureHelp\",\"params\":{\"textDocument\":{\"uri\":\"file:///shader.zw\"},\"position\":{\"line\":7,\"character\":28}}}",
    )).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":11") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "def shade(pos: Vec3, amount: Float) -> Vec3") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"activeParameter\":1") != null);
}

test "lsp code actions add missing vertex position input" {
    const source =
        \\vertex do
        \\  def main
        \\    gl_Position = vec4(position, 1.0)
        \\  end
        \\end
    ;

    const response = try code_actions.response(std.testing.allocator, "file:///shader.zw", source);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"title\":\"Add vertex position input\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"line\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"newText\":\"  input :position, Vec3, location: 0\\n\"") != null);
}

test "lsp code actions fix type and constructor casing" {
    const source =
        \\vertex do
        \\  input :position, vec3, location: 0
        \\  def main
        \\    gl_Position = Vec4(position, 1.0)
        \\  end
        \\end
    ;

    const response = try code_actions.response(std.testing.allocator, "file:///shader.zw", source);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"title\":\"Use uppercase type name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"line\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"character\":19") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"newText\":\"Vec3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"title\":\"Use lowercase constructor name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"line\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"character\":18") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"newText\":\"vec4\"") != null);
}

test "lsp code actions remove unused uniforms" {
    const source =
        \\uniform :unused, Mat4
        \\uniform :mvp, Mat4
        \\
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  def main
        \\    gl_Position = mvp * vec4(position, 1.0)
        \\  end
        \\end
    ;

    const response = try code_actions.response(std.testing.allocator, "file:///shader.zw", source);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, response, "\"title\":\"Remove unused uniform\""),
    );
    try std.testing.expect(std.mem.indexOf(u8, response, "\"start\":{\"line\":0,\"character\":0}") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"end\":{\"line\":1,\"character\":0}") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"newText\":\"\"") != null);
}

test "lsp handler serves code actions from open documents" {
    var state = handler.State.init(std.testing.allocator);
    defer state.deinit();

    const source =
        \\vertex do
        \\  def main
        \\    gl_Position = vec4(position, 1.0)
        \\  end
        \\end
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

    const response = (try handler.handle(
        std.testing.allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"textDocument/codeAction\",\"params\":{\"textDocument\":{\"uri\":\"file:///shader.zw\"},\"range\":{\"start\":{\"line\":2,\"character\":25},\"end\":{\"line\":2,\"character\":33}},\"context\":{\"diagnostics\":[]}}}",
    )).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"title\":\"Add vertex position input\"") != null);
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

test "lsp document symbols outline stages declarations and functions" {
    const source =
        \\uniform :mvp, Mat4
        \\
        \\type Shape
        \\  Point
        \\end
        \\
        \\trait Numeric
        \\  def add(other: Self) -> Self end
        \\end
        \\
        \\impl Numeric for Float
        \\  def add(other: Self) -> Self
        \\    self + other
        \\  end
        \\end
        \\
        \\def helper(v: Vec3) -> Vec3
        \\  normalize(v)
        \\end
        \\
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  varying :v_pos, Vec3
        \\  def main
        \\    self.v_pos = position
        \\    gl_Position = mvp * vec4(position, 1.0)
        \\  end
        \\end
    ;

    const response = try document_symbols.response(std.testing.allocator, source);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"mvp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"Shape\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"Point\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"Numeric\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"impl Numeric for Float\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"helper\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"vertex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"vertex.position\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"vertex.main\"") != null);
}

test "lsp handler serves document symbols from open documents" {
    var state = handler.State.init(std.testing.allocator);
    defer state.deinit();

    const source =
        \\uniform :mvp, Mat4
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  def main
        \\    gl_Position = mvp * vec4(position, 1.0)
        \\  end
        \\end
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

    const response = (try handler.handle(
        std.testing.allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file:///shader.zw\"}}}",
    )).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"mvp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"vertex.main\"") != null);
}

test "lsp rename returns workspace edits for resolved symbols" {
    const source =
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  def shade(pos: Vec3) -> Vec4
        \\    normal = pos
        \\    vec4(position + normal, 1.0)
        \\  end
        \\end
    ;

    const response = try rename.response(std.testing.allocator, "file:///shader.zw", source, 4, 10, "vertex_position");
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"changes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"line\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"character\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"line\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"newText\":\"vertex_position\"") != null);
}

test "lsp handler serves rename from open documents" {
    var state = handler.State.init(std.testing.allocator);
    defer state.deinit();

    const source =
        \\uniform :mvp, Mat4
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  def main
        \\    gl_Position = mvp * vec4(position, 1.0)
        \\  end
        \\end
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

    const response = (try handler.handle(
        std.testing.allocator,
        &state,
        "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///shader.zw\"},\"position\":{\"line\":4,\"character\":20},\"newName\":\"model_view_projection\"}}",
    )).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"newText\":\"model_view_projection\"") != null);
}

test "lsp semantic tokens classify keywords comments and properties" {
    const source =
        \\# comment
        \\uniform :mvp, Mat4
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  varying :v_pos, Vec3
        \\  def shade(pos: Vec3) -> Vec3
        \\    v_pos = pos
        \\    gl_Position = mvp * vec4(position, 1.0)
        \\    pos.xyz
        \\  end
        \\end
    ;

    const response = try semantic_tokens.response(std.testing.allocator, source);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, ",7,0") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, ",9,0") != null);

    var document = try analysis.Document.init(std.testing.allocator, source);
    defer document.deinit();

    try expectSemanticClass(&document, 1, 9, .uniform);
    try expectSemanticClass(&document, 2, 1, .stage);
    try expectSemanticClass(&document, 4, 11, .varying);
    try expectSemanticClass(&document, 7, 4, .builtin);
    try expectSemanticClass(&document, 7, 18, .uniform);
    try expectSemanticClass(&document, 7, 24, .constructor);
    try expectSemanticClass(&document, 8, 8, .property);
}

fn expectSemanticClass(
    document: *const analysis.Document,
    line: u32,
    character: u32,
    expected: analysis.LspTokenType,
) !void {
    const item = document.tokenAt(line, character) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected, document.semanticClass(item.tok, item.index));
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
