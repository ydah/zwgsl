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
    const tokens = try zwgsl.lexer.Lexer.tokenizeResolved(allocator, source);
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

test "sema accepts vector each loops" {
    var analyzed = try analyzeSource(
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  varying :v_sum, Float
        \\  def main
        \\    total: Float = 0.0
        \\    position.each do |component|
        \\      total += component
        \\    end
        \\    self.v_sum = total
        \\    gl_Position = vec4(position, 1.0)
        \\  end
        \\end
        \\
        \\fragment do
        \\  varying :v_sum, Float
        \\  output :frag_color, Vec4, location: 0
        \\  def main
        \\    frag_color = vec4(v_sum)
        \\  end
        \\end
    );
    defer analyzed.arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
}

test "sema rejects each loops on non-vectors" {
    var analyzed = try analyzeSource(
        \\def bad_loop
        \\  1.each do |item|
        \\    item
        \\  end
        \\end
    );
    defer analyzed.arena.deinit();
    try std.testing.expect(analyzed.diagnostics.items.items.len > 0);
}

test "sema rejects reassigning let bindings" {
    var analyzed = try analyzeSource(
        \\def main
        \\  let value = 1.0
        \\  value = 2.0
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expect(analyzed.diagnostics.items.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, analyzed.diagnostics.items.items[0].message, "immutable") != null);
}

test "sema resolves where bindings in dependency order" {
    var analyzed = try analyzeSource(
        \\def shade(n: Vec3) -> Float
        \\  ambient + diffuse
        \\where
        \\  diffuse = max(dot(n, light_dir), 0.0)
        \\  ambient = 0.1
        \\  light_dir = normalize(vec3(1.0, 1.0, 1.0))
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
}

test "sema reports circular where dependencies" {
    var analyzed = try analyzeSource(
        \\def broken -> Float
        \\  a
        \\where
        \\  a = b
        \\  b = a
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expect(analyzed.diagnostics.items.items.len > 0);

    var found_cycle = false;
    for (analyzed.diagnostics.items.items) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, "circular dependency") != null) {
            found_cycle = true;
            break;
        }
    }
    try std.testing.expect(found_cycle);
}

test "sema infers polymorphic let identity functions" {
    var analyzed = try analyzeSource(
        \\def main
        \\  let id = |x| x
        \\  a = id(1)
        \\  b = id(vec3(1.0))
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
}

test "sema infers lambda numeric arguments from use sites" {
    var analyzed = try analyzeSource(
        \\def main
        \\  let increment = |x| x + 1
        \\  value = increment(2)
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
}

test "sema registers algebraic data constructors" {
    var analyzed = try analyzeSource(
        \\type Shape
        \\  Circle(radius: Float)
        \\  Point
        \\end
        \\
        \\def main
        \\  let shape = Circle(1.0)
        \\  shape
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
    try std.testing.expect(analyzed.typed.constructor("Circle") != null);
}

test "sema accepts generic ADT constructors" {
    var analyzed = try analyzeSource(
        \\type Option(a)
        \\  Some(value: a)
        \\  None
        \\end
        \\
        \\def unwrap(value: Option(Float)) -> Float
        \\  match value
        \\  when Some(inner)
        \\    inner
        \\  when None
        \\    0.0
        \\  end
        \\end
        \\
        \\def main
        \\  let value = Some(1.0)
        \\  unwrap(value)
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
}

test "sema type-checks match expressions over ADTs" {
    var analyzed = try analyzeSource(
        \\type Shape
        \\  Circle(radius: Float)
        \\  Rect(width: Float, height: Float)
        \\  Point
        \\end
        \\
        \\def area(shape: Shape) -> Float
        \\  match shape
        \\  when Circle(radius)
        \\    radius * radius
        \\  when Rect(width, height)
        \\    width * height
        \\  when Point
        \\    0.0
        \\  end
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
}

test "sema warns about non-exhaustive matches" {
    var analyzed = try analyzeSource(
        \\type Shape
        \\  Circle(radius: Float)
        \\  Point
        \\end
        \\
        \\def area(shape: Shape) -> Float
        \\  match shape
        \\  when Circle(radius)
        \\    radius
        \\  end
        \\end
    );
    defer analyzed.arena.deinit();

    var found_warning = false;
    for (analyzed.diagnostics.items.items) |diagnostic| {
        if (diagnostic.kind == .warning and std.mem.indexOf(u8, diagnostic.message, "not exhaustive") != null) {
            found_warning = true;
            break;
        }
    }
    try std.testing.expect(found_warning);
}

test "sema type-checks symbol literals and symbol match patterns" {
    var analyzed = try analyzeSource(
        \\def shade(mode: Symbol) -> Float
        \\  match mode
        \\  when :phong
        \\    1.0
        \\  when :flat
        \\    0.5
        \\  end
        \\end
        \\
        \\def main
        \\  let mode = :phong
        \\  shade(mode)
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
    const function = analyzed.program.items[1].function;
    const let_expr = function.body[0].data.let_binding.value;
    try std.testing.expect(analyzed.typed.exprType(let_expr).eql(zwgsl.types.builtinType(.symbol)));
}

test "sema resolves dependent vector dimensions through function calls" {
    var analyzed = try analyzeSource(
        \\def same_dim(a: Vec(N), b: Vec(N)) -> Float
        \\  dot(a, b)
        \\end
        \\
        \\def main
        \\  left: Vec(3) = vec3(1.0)
        \\  right: Vec(3) = vec3(2.0)
        \\  same_dim(left, right)
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
}

test "sema reports dependent dimension mismatches" {
    var analyzed = try analyzeSource(
        \\def same_dim(a: Vec(N), b: Vec(N)) -> Float
        \\  dot(a, b)
        \\end
        \\
        \\def main
        \\  left: Vec(3) = vec3(1.0)
        \\  right: Vec(4) = vec4(2.0)
        \\  same_dim(left, right)
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expect(analyzed.diagnostics.items.items.len > 0);
}

test "sema resolves simple trait constraints" {
    var analyzed = try analyzeSource(
        \\trait Numeric
        \\  def zero -> Self end
        \\end
        \\
        \\impl Numeric for Float
        \\  def zero -> Float
        \\    0.0
        \\  end
        \\end
        \\
        \\def choose(a: T, b: T) -> T where T: Numeric
        \\  a
        \\end
        \\
        \\def run -> Float
        \\  choose(1.0, 2.0)
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
}

test "sema rejects unsatisfied trait constraints" {
    var analyzed = try analyzeSource(
        \\trait Numeric
        \\  def zero -> Self end
        \\end
        \\
        \\impl Numeric for Float
        \\  def zero -> Float
        \\    0.0
        \\  end
        \\end
        \\
        \\def choose(a: T, b: T) -> T where T: Numeric
        \\  a
        \\end
        \\
        \\def run
        \\  choose(vec3(1.0), vec3(2.0))
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expect(analyzed.diagnostics.items.items.len > 0);
}

test "sema type checks impl methods and constrained trait method calls" {
    var analyzed = try analyzeSource(
        \\trait Numeric
        \\  def add(other: Self) -> Self end
        \\  def mul(other: Self) -> Self end
        \\end
        \\
        \\impl Numeric for Float
        \\  def add(other: Self) -> Self
        \\    self + other
        \\  end
        \\
        \\  def mul(other: Float) -> Float
        \\    self * other
        \\  end
        \\end
        \\
        \\def lerp(a: T, b: T, t: Float) -> T where T: Numeric
        \\  a.mul(1.0 - t).add(b.mul(t))
        \\end
        \\
        \\def run -> Float
        \\  lerp(1.0, 2.0, 0.5)
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
}

test "sema rejects non-assignable inout call arguments" {
    var analyzed = try analyzeSource(
        \\def increment(inout value: Float)
        \\  value += 1.0
        \\end
        \\
        \\def run
        \\  increment(1.0)
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expect(analyzed.diagnostics.items.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, analyzed.diagnostics.items.items[0].message, "inout argument") != null);
}

test "sema infers generic struct constructors and field access" {
    var analyzed = try analyzeSource(
        \\struct Pair(a, b)
        \\  first: a
        \\  second: b
        \\end
        \\
        \\def first_value -> Vec3
        \\  let pair = Pair.new(vec3(1.0), 0.5)
        \\  pair.first
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
    const function = analyzed.program.items[1].function;
    const expr = function.body[1].data.expression;
    try std.testing.expect(analyzed.typed.exprType(expr).eql(zwgsl.types.builtinType(.vec3)));
}

test "sema supports explicit phantom struct parameters" {
    var analyzed = try analyzeSource(
        \\type Space
        \\  WorldSpace
        \\  ViewSpace
        \\end
        \\
        \\struct Tagged(space, value_type)
        \\  value: value_type
        \\end
        \\
        \\def world_to_view(pos: Tagged(WorldSpace, Vec3)) -> Tagged(ViewSpace, Vec3)
        \\  Tagged(ViewSpace, Vec3).new(pos.value)
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);
}

test "sema rejects phantom struct parameter mismatches" {
    var analyzed = try analyzeSource(
        \\type Space
        \\  WorldSpace
        \\  ViewSpace
        \\end
        \\
        \\struct Tagged(space, value_type)
        \\  value: value_type
        \\end
        \\
        \\def world_to_view(pos: Tagged(WorldSpace, Vec3)) -> Tagged(ViewSpace, Vec3)
        \\  Tagged(ViewSpace, Vec3).new(pos.value)
        \\end
        \\
        \\def main
        \\  let view_pos = Tagged(ViewSpace, Vec3).new(vec3(1.0))
        \\  world_to_view(view_pos)
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expect(analyzed.diagnostics.items.items.len > 0);
}

test "lowering preserves line and column metadata" {
    var analyzed = try analyzeSource(
        \\def area(x: Float) -> Float
        \\  x + 1.0
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);

    const allocator = analyzed.arena.allocator();
    const ir_module = try zwgsl.ir_builder.build(allocator, analyzed.typed);
    const hir_module = try zwgsl.hir_builder.build(allocator, analyzed.typed);
    const mir_module = try zwgsl.mir_builder.build(allocator, hir_module);

    const ir_function = ir_module.global_functions[0];
    try std.testing.expectEqual(@as(?u32, 1), ir_function.source_line);
    try std.testing.expectEqual(@as(?u32, 1), ir_function.source_column);
    try std.testing.expectEqual(@as(?u32, 10), ir_function.params[0].source_column);
    try std.testing.expectEqual(@as(?u32, 2), ir_function.body[0].source_line);
    try std.testing.expectEqual(@as(?u32, 5), ir_function.body[0].source_column);
    try std.testing.expectEqual(@as(?u32, 2), ir_function.body[0].data.return_stmt.?.source_line);
    try std.testing.expectEqual(@as(?u32, 5), ir_function.body[0].data.return_stmt.?.source_column);

    const hir_function = hir_module.global_functions[0];
    try std.testing.expectEqual(@as(?u32, 1), hir_function.source_line);
    try std.testing.expectEqual(@as(?u32, 1), hir_function.source_column);
    try std.testing.expectEqual(@as(?u32, 2), hir_function.body[0].source_line);
    try std.testing.expectEqual(@as(?u32, 5), hir_function.body[0].source_column);
    try std.testing.expectEqual(@as(?u32, 2), hir_function.body[0].data.return_stmt.?.source_line);
    try std.testing.expectEqual(@as(?u32, 5), hir_function.body[0].data.return_stmt.?.source_column);

    const mir_function = mir_module.global_functions[0];
    try std.testing.expectEqual(@as(?u32, 1), mir_function.source_line);
    try std.testing.expectEqual(@as(?u32, 1), mir_function.source_column);
    try std.testing.expectEqual(@as(usize, 1), mir_function.blocks.len);
    try std.testing.expect(std.mem.eql(u8, mir_function.entry_block, mir_function.blocks[0].label));
    try std.testing.expectEqual(@as(?u32, 2), mir_function.blocks[0].source_line);
    try std.testing.expectEqual(@as(?u32, 5), mir_function.blocks[0].source_column);
    try std.testing.expectEqual(@as(?u32, 2), mir_function.blocks[0].terminator.return_stmt.?.source_line);
    try std.testing.expectEqual(@as(?u32, 5), mir_function.blocks[0].terminator.return_stmt.?.source_column);
}

test "HIR and MIR preserve entry points and CFG structure" {
    var analyzed = try analyzeSource(
        \\def twice(x: Float) -> Float
        \\  x * 2.0
        \\end
        \\
        \\compute do
        \\  def main
        \\    value: Float = twice(1.0)
        \\    if value > 1.0
        \\      value = value + 1.0
        \\    end
        \\  end
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);

    const allocator = analyzed.arena.allocator();
    const hir_module = try zwgsl.hir_builder.build(allocator, analyzed.typed);
    const mir_module = try zwgsl.mir_builder.build(allocator, hir_module);

    try std.testing.expectEqual(@as(usize, 1), hir_module.entry_points.len);
    try std.testing.expectEqual(zwgsl.ast.Stage.compute, hir_module.entry_points[0].stage);
    try std.testing.expectEqual(@as(usize, 1), hir_module.entry_points[0].functions.len);

    try std.testing.expectEqual(@as(usize, 1), mir_module.entry_points.len);
    const compute_entry = mir_module.entryPoint(.compute).?;
    const main_function = compute_entry.mainFunction();
    try std.testing.expect(main_function.blocks.len >= 4);
    try std.testing.expect(std.mem.eql(u8, main_function.entry_block, main_function.blocks[0].label));

    var saw_if_term = false;
    for (main_function.blocks) |block| {
        if (block.terminator == .if_term) {
            saw_if_term = true;
            break;
        }
    }
    try std.testing.expect(saw_if_term);
}

test "MIR lowers expressions into SSA-style instructions" {
    var analyzed = try analyzeSource(
        \\compute do
        \\  def main
        \\    total: Float = 1.0
        \\    total += 2.0
        \\  end
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);

    const allocator = analyzed.arena.allocator();
    const hir_module = try zwgsl.hir_builder.build(allocator, analyzed.typed);
    const mir_module = try zwgsl.mir_builder.build(allocator, hir_module);

    const function = mir_module.entryPoint(.compute).?.mainFunction();
    try std.testing.expectEqual(@as(usize, 1), function.blocks.len);
    const block = function.blocks[0];
    try std.testing.expectEqual(@as(usize, 4), block.instructions.len);

    try std.testing.expectEqual(.local_alloc, std.meta.activeTag(block.instructions[0].data));
    try std.testing.expectEqual(.load, std.meta.activeTag(block.instructions[1].data));
    try std.testing.expectEqual(.binary, std.meta.activeTag(block.instructions[2].data));
    try std.testing.expectEqual(.store, std.meta.activeTag(block.instructions[3].data));

    const loaded_value = block.instructions[1].result.?;
    const binary_value = block.instructions[2].result.?;
    const binary = block.instructions[2].data.binary;
    const store = block.instructions[3].data.store;

    try std.testing.expect(store.target == block.instructions[1].data.load);
    try std.testing.expect(binary.lhs.data == .identifier);
    try std.testing.expect(store.value.data == .identifier);
    try std.testing.expect(std.mem.eql(u8, binary.lhs.data.identifier, loaded_value.name));
    try std.testing.expect(std.mem.eql(u8, store.value.data.identifier, binary_value.name));
}

test "HIR builder unrolls vector loops directly from typed AST" {
    var analyzed = try analyzeSource(
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  varying :v_sum, Float
        \\  def main
        \\    total: Float = 0.0
        \\    position.each do |component|
        \\      total += component
        \\    end
        \\    self.v_sum = total
        \\    gl_Position = vec4(position, 1.0)
        \\  end
        \\end
        \\
        \\fragment do
        \\  varying :v_sum, Float
        \\  output :frag_color, Vec4, location: 0
        \\  def main
        \\    frag_color = vec4(v_sum)
        \\  end
        \\end
    );
    defer analyzed.arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), analyzed.diagnostics.items.items.len);

    const hir_module = try zwgsl.hir_builder.build(analyzed.arena.allocator(), analyzed.typed);
    const vertex_entry = hir_module.entryPoint(.vertex).?;
    const function = vertex_entry.mainFunction();

    try std.testing.expectEqual(@as(usize, 6), function.body.len);
    try std.testing.expectEqual(.var_decl, std.meta.activeTag(function.body[0].data));
    try std.testing.expectEqual(.assign, std.meta.activeTag(function.body[1].data));
    try std.testing.expectEqual(.assign, std.meta.activeTag(function.body[2].data));
    try std.testing.expectEqual(.assign, std.meta.activeTag(function.body[3].data));
    try std.testing.expectEqual(.assign, std.meta.activeTag(function.body[4].data));
    try std.testing.expectEqual(.assign, std.meta.activeTag(function.body[5].data));
}
