const std = @import("std");
const zwgsl = @import("zwgsl");

fn parseProgram(source: []const u8) !struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: zwgsl.diagnostics.DiagnosticList,
    program: *zwgsl.ast.Program,
} {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();

    const allocator = arena.allocator();
    const tokens = try zwgsl.lexer.Lexer.tokenizeResolved(allocator, source);
    var diagnostic_list = zwgsl.diagnostics.DiagnosticList.init(allocator);
    errdefer diagnostic_list.deinit();

    var parser = zwgsl.parser.Parser.init(allocator, source, tokens, &diagnostic_list);
    const program = try parser.parseProgram();
    return .{
        .arena = arena,
        .diagnostics = diagnostic_list,
        .program = program,
    };
}

fn parseProgramWithPool(source: []const u8) !struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: zwgsl.diagnostics.DiagnosticList,
    program: *zwgsl.ast.Program,
} {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();

    const allocator = arena.allocator();
    var pool = zwgsl.string_pool.StringPool.init(allocator);

    const tokens = try zwgsl.lexer.Lexer.tokenizeResolvedWithPool(allocator, &pool, source);
    var diagnostic_list = zwgsl.diagnostics.DiagnosticList.init(allocator);
    errdefer diagnostic_list.deinit();

    var parser = zwgsl.parser.Parser.initWithPool(allocator, &pool, source, tokens, &diagnostic_list);
    const program = try parser.parseProgram();
    return .{
        .arena = arena,
        .diagnostics = diagnostic_list,
        .program = program,
    };
}

test "parser handles version declarations" {
    var parsed = try parseProgram("version \"300 es\"");
    defer parsed.arena.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.program.items.len);
    try std.testing.expectEqualStrings("300 es", parsed.program.items[0].version.value);
}

test "parser handles uniform declarations" {
    var parsed = try parseProgram("uniform :mvp, Mat4");
    defer parsed.arena.deinit();
    const uniform = parsed.program.items[0].uniform;
    try std.testing.expectEqualStrings("mvp", uniform.name);
    try std.testing.expectEqualStrings("Mat4", uniform.type_name);
}

test "parser handles struct definitions" {
    var parsed = try parseProgram(
        \\struct Light
        \\  color: Vec3
        \\  intensity: Float
        \\end
    );
    defer parsed.arena.deinit();
    const definition = parsed.program.items[0].struct_def;
    try std.testing.expectEqualStrings("Light", definition.name);
    try std.testing.expectEqual(@as(usize, 2), definition.fields.len);
}

test "parser handles shader blocks" {
    var parsed = try parseProgram(
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  varying :v_normal, Vec3
        \\
        \\  def main
        \\    self.v_normal = position
        \\  end
        \\end
    );
    defer parsed.arena.deinit();
    const block = parsed.program.items[0].shader_block;
    try std.testing.expectEqual(zwgsl.ast.Stage.vertex, block.stage);
    try std.testing.expectEqual(@as(usize, 3), block.items.len);
}

test "parser handles function definitions" {
    var parsed = try parseProgram(
        \\def main
        \\  gl_Position = vec4(1.0)
        \\end
    );
    defer parsed.arena.deinit();
    const function = parsed.program.items[0].function;
    try std.testing.expectEqualStrings("main", function.name);
    try std.testing.expectEqual(@as(usize, 1), function.body.len);
}

test "parser respects operator precedence" {
    var parsed = try parseProgram(
        \\def main
        \\  x = a + b * c
        \\end
    );
    defer parsed.arena.deinit();
    const function = parsed.program.items[0].function;
    const stmt = function.body[0].data.assignment;
    const binary = stmt.value.data.binary;
    try std.testing.expectEqual(zwgsl.token.TokenTag.plus, binary.operator);
    try std.testing.expectEqual(zwgsl.token.TokenTag.star, binary.rhs.data.binary.operator);
}

test "parser keeps chained calls as member and call expressions" {
    var parsed = try parseProgram(
        \\def main
        \\  v.normalize.clamp(0.0, 1.0)
        \\end
    );
    defer parsed.arena.deinit();
    const expr_stmt = parsed.program.items[0].function.body[0].data.expression;
    try std.testing.expectEqual(.call, std.meta.activeTag(expr_stmt.data));
    const call = expr_stmt.data.call;
    try std.testing.expectEqual(.member, std.meta.activeTag(call.callee.data));
}

test "parser handles postfix if" {
    var parsed = try parseProgram(
        \\def main
        \\  frag_color = vec4(1.0) if debug
        \\end
    );
    defer parsed.arena.deinit();
    const stmt = parsed.program.items[0].function.body[0];
    try std.testing.expectEqual(.conditional, std.meta.activeTag(stmt.data));
}

test "parser handles postfix unless" {
    var parsed = try parseProgram(
        \\def main
        \\  discard unless alpha > 0.01
        \\end
    );
    defer parsed.arena.deinit();
    const stmt = parsed.program.items[0].function.body[0];
    try std.testing.expect(stmt.data.conditional.negate);
}

test "parser handles self access" {
    var parsed = try parseProgram(
        \\def main
        \\  self.v_normal = normal
        \\end
    );
    defer parsed.arena.deinit();
    const assignment = parsed.program.items[0].function.body[0].data.assignment;
    try std.testing.expectEqual(.member, std.meta.activeTag(assignment.target.data));
    try std.testing.expectEqual(.self_ref, std.meta.activeTag(assignment.target.data.member.target.data));
}

test "parser handles times loops" {
    var parsed = try parseProgram(
        \\def main
        \\  3.times do |i|
        \\    total += lights[i]
        \\  end
        \\end
    );
    defer parsed.arena.deinit();
    const stmt = parsed.program.items[0].function.body[0];
    try std.testing.expectEqual(.times_loop, std.meta.activeTag(stmt.data));
    try std.testing.expectEqualStrings("i", stmt.data.times_loop.binding.?);
}

test "parser handles function return types" {
    var parsed = try parseProgram(
        \\def f(x: Float) -> Vec3
        \\  x.xxx
        \\end
    );
    defer parsed.arena.deinit();
    const function = parsed.program.items[0].function;
    try std.testing.expectEqualStrings("Vec3", function.return_type.?);
    try std.testing.expectEqual(@as(usize, 1), function.params.len);
}

test "parser handles let bindings" {
    var parsed = try parseProgram(
        \\def main
        \\  let color: Vec3 = vec3(1.0, 0.0, 0.0)
        \\end
    );
    defer parsed.arena.deinit();

    const stmt = parsed.program.items[0].function.body[0];
    try std.testing.expectEqual(.let_binding, std.meta.activeTag(stmt.data));
    try std.testing.expectEqualStrings("color", stmt.data.let_binding.name);
    try std.testing.expectEqualStrings("Vec3", stmt.data.let_binding.type_name.?);
}

test "parser handles where clauses" {
    var parsed = try parseProgram(
        \\def lighting(n: Vec3) -> Float
        \\  ambient + diffuse
        \\where
        \\  diffuse = max(n.x, 0.0)
        \\  ambient = 0.1
        \\end
    );
    defer parsed.arena.deinit();

    const function = parsed.program.items[0].function;
    try std.testing.expect(function.where_clause != null);
    try std.testing.expectEqual(@as(usize, 2), function.where_clause.?.bindings.len);
    try std.testing.expectEqualStrings("diffuse", function.where_clause.?.bindings[0].name);
    try std.testing.expectEqualStrings("ambient", function.where_clause.?.bindings[1].name);
}

test "parser handles lambda expressions" {
    var parsed = try parseProgram(
        \\def main
        \\  let id = |x| x
        \\end
    );
    defer parsed.arena.deinit();

    const stmt = parsed.program.items[0].function.body[0];
    try std.testing.expectEqual(.let_binding, std.meta.activeTag(stmt.data));
    try std.testing.expectEqual(.lambda, std.meta.activeTag(stmt.data.let_binding.value.data));
    try std.testing.expectEqual(@as(usize, 1), stmt.data.let_binding.value.data.lambda.params.len);
    try std.testing.expectEqualStrings("x", stmt.data.let_binding.value.data.lambda.params[0]);
}

test "parser handles algebraic type definitions" {
    var parsed = try parseProgram(
        \\type Shape
        \\  Circle(radius: Float)
        \\  Point
        \\end
    );
    defer parsed.arena.deinit();

    const definition = parsed.program.items[0].type_def;
    try std.testing.expectEqualStrings("Shape", definition.name);
    try std.testing.expectEqual(@as(usize, 2), definition.variants.len);
    try std.testing.expectEqualStrings("Circle", definition.variants[0].name);
    try std.testing.expectEqual(@as(usize, 1), definition.variants[0].fields.len);
    try std.testing.expectEqualStrings("Point", definition.variants[1].name);
}

test "parser handles generic struct definitions" {
    var parsed = try parseProgram(
        \\struct Pair(a, b)
        \\  first: a
        \\  second: b
        \\end
    );
    defer parsed.arena.deinit();

    const definition = parsed.program.items[0].struct_def;
    try std.testing.expectEqualStrings("Pair", definition.name);
    try std.testing.expectEqual(@as(usize, 2), definition.params.len);
    try std.testing.expectEqualStrings("a", definition.params[0]);
    try std.testing.expectEqualStrings("b", definition.params[1]);
}

test "parser handles match expressions" {
    var parsed = try parseProgram(
        \\def classify(value: Float) -> Float
        \\  match value
        \\  when positive if value > 0.0
        \\    value
        \\  when _
        \\    0.0
        \\  end
        \\end
    );
    defer parsed.arena.deinit();

    const expr = parsed.program.items[0].function.body[0].data.expression;
    try std.testing.expectEqual(.match_expr, std.meta.activeTag(expr.data));
    try std.testing.expectEqual(@as(usize, 2), expr.data.match_expr.arms.len);
    try std.testing.expect(expr.data.match_expr.arms[0].guard != null);
    try std.testing.expectEqual(@as(u32, 3), expr.data.match_expr.arms[0].position.line);
    try std.testing.expectEqual(.wildcard, std.meta.activeTag(expr.data.match_expr.arms[1].pattern.data));
    try std.testing.expectEqual(@as(u32, 5), expr.data.match_expr.arms[1].pattern.position.line);
}

test "parser records nested pattern positions" {
    var parsed = try parseProgram(
        \\def area(shape: Shape) -> Float
        \\  match shape
        \\  when Some(Circle(radius))
        \\    radius
        \\  when _
        \\    0.0
        \\  end
        \\end
    );
    defer parsed.arena.deinit();

    const match_expr = parsed.program.items[0].function.body[0].data.expression.data.match_expr;
    const constructor = match_expr.arms[0].pattern.data.constructor;
    const nested = constructor.args[0].data.constructor;
    try std.testing.expectEqualStrings("Some", constructor.name);
    try std.testing.expectEqual(@as(u32, 3), constructor.position.line);
    try std.testing.expectEqualStrings("Circle", nested.name);
    try std.testing.expectEqual(@as(u32, 3), nested.position.line);
    try std.testing.expectEqualStrings("radius", nested.args[0].data.binding);
}

test "parser handles trait and impl definitions" {
    var parsed = try parseProgram(
        \\trait Numeric
        \\  def zero -> Self end
        \\end
        \\
        \\impl Numeric for Float
        \\  def zero -> Float
        \\    0.0
        \\  end
        \\end
    );
    defer parsed.arena.deinit();

    try std.testing.expectEqual(.trait_def, std.meta.activeTag(parsed.program.items[0]));
    try std.testing.expectEqual(.impl_def, std.meta.activeTag(parsed.program.items[1]));
}

test "parser reuses interned identifier slices with a shared string pool" {
    var parsed = try parseProgramWithPool(
        \\def main(value: Float) -> Float
        \\  value + value
        \\end
    );
    defer parsed.arena.deinit();

    const function = parsed.program.items[0].function;
    const lhs = function.body[0].data.expression.data.binary.lhs.data.identifier;
    const rhs = function.body[0].data.expression.data.binary.rhs.data.identifier;
    try std.testing.expect(function.params[0].name.ptr == lhs.ptr);
    try std.testing.expect(lhs.ptr == rhs.ptr);
}
