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
