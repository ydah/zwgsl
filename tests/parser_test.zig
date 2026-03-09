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
    const tokens = try zwgsl.lexer.Lexer.tokenize(allocator, source);
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
