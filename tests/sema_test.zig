const std = @import("std");
const zwgsl = @import("zwgsl");

fn analyzeSource(source: []const u8) !struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: zwgsl.diagnostics.DiagnosticList,
    typed: *zwgsl.sema.TypedProgram,
    program: *zwgsl.ast.Program,
} {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();

    const allocator = arena.allocator();
    const tokens = try zwgsl.lexer.Lexer.tokenize(allocator, source);
    var diagnostic_list = zwgsl.diagnostics.DiagnosticList.init(allocator);
    var parser = zwgsl.parser.Parser.init(allocator, source, tokens, &diagnostic_list);
    const program = try parser.parseProgram();
    const typed = try zwgsl.sema.analyze(allocator, program, &diagnostic_list);
    return .{
        .arena = arena,
        .diagnostics = diagnostic_list,
        .typed = typed,
        .program = program,
    };
}

test "sema reports undeclared variables" {
    var analyzed = try analyzeSource(
        \\vertex do
        \\  def main
        \\    gl_Position = vec4(position, 1.0)
        \\  end
        \\end
    );
    defer analyzed.arena.deinit();
    try std.testing.expect(analyzed.diagnostics.items.items.len > 0);
}

test "sema reports type mismatches" {
    var analyzed = try analyzeSource(
        \\fragment do
        \\  output :frag_color, Vec4, location: 0
        \\  def main
        \\    frag_color = 1.0
        \\  end
        \\end
    );
    defer analyzed.arena.deinit();
    try std.testing.expect(analyzed.diagnostics.items.items.len > 0);
}

test "sema validates varying compatibility" {
    var analyzed = try analyzeSource(
        \\vertex do
        \\  varying :v_normal, Vec3
        \\  def main
        \\    self.v_normal = vec3(1.0)
        \\  end
        \\end
        \\
        \\fragment do
        \\  def main
        \\    discard
        \\  end
        \\end
    );
    defer analyzed.arena.deinit();
    try std.testing.expect(analyzed.diagnostics.items.items.len > 0);
}

test "sema accepts a valid shader" {
    var analyzed = try analyzeSource(
        \\version "300 es"
        \\uniform :mvp, Mat4
        \\uniform :base_color, Vec4
        \\
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  varying :v_pos, Vec3
        \\  def main
        \\    self.v_pos = position
        \\    gl_Position = mvp * vec4(position, 1.0)
        \\  end
        \\end
        \\
        \\fragment do
        \\  varying :v_pos, Vec3
        \\  output :frag_color, Vec4, location: 0
        \\  def main
        \\    frag_color = vec4(v_pos, base_color.a)
        \\  end
        \\end
    );
    defer analyzed.arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
}

test "sema checks implicit return types" {
    var analyzed = try analyzeSource(
        \\def normalize_value(x: Float) -> Vec3
        \\  x
        \\end
    );
    defer analyzed.arena.deinit();
    try std.testing.expect(analyzed.diagnostics.items.items.len > 0);
}

test "sema rejects invalid builtin calls" {
    var analyzed = try analyzeSource(
        \\def broken(x: Float) -> Float
        \\  normalize(1.0)
        \\end
    );
    defer analyzed.arena.deinit();
    try std.testing.expect(analyzed.diagnostics.items.items.len > 0);
}

test "sema rejects invalid swizzles" {
    var analyzed = try analyzeSource(
        \\def broken(v: Vec2) -> Float
        \\  v.xyz
        \\end
    );
    defer analyzed.arena.deinit();
    try std.testing.expect(analyzed.diagnostics.items.items.len > 0);
}

test "sema propagates method chain types" {
    var analyzed = try analyzeSource(
        \\def tone_map(v: Vec3) -> Vec3
        \\  v.normalize.clamp(0.0, 1.0)
        \\end
    );
    defer analyzed.arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
    const function = analyzed.program.items[0].function;
    const expr = function.body[0].data.expression;
    try std.testing.expect(analyzed.typed.exprType(expr).eql(zwgsl.types.builtinType(.vec3)));
}
