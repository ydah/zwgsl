const std = @import("std");
const zwgsl = @import("zwgsl");

fn expectWgslFixture(source_path: []const u8, vertex_path: ?[]const u8, fragment_path: ?[]const u8, compute_path: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = try std.fs.cwd().readFileAlloc(arena.allocator(), source_path, 1 << 20);
    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);

    if (vertex_path) |path| {
        const expected = try std.fs.cwd().readFileAlloc(arena.allocator(), path, 1 << 20);
        try std.testing.expectEqualStrings(expected, output.vertex_source.?);
    } else {
        try std.testing.expect(output.vertex_source == null);
    }

    if (fragment_path) |path| {
        const expected = try std.fs.cwd().readFileAlloc(arena.allocator(), path, 1 << 20);
        try std.testing.expectEqualStrings(expected, output.fragment_source.?);
    } else {
        try std.testing.expect(output.fragment_source == null);
    }

    if (compute_path) |path| {
        const expected = try std.fs.cwd().readFileAlloc(arena.allocator(), path, 1 << 20);
        try std.testing.expectEqualStrings(expected, output.compute_source.?);
    } else {
        try std.testing.expect(output.compute_source == null);
    }
}

test "compiler emits WGSL for a basic vertex and fragment shader" {
    try expectWgslFixture(
        "tests/fixtures/basic_shader.zw",
        "tests/fixtures/basic_shader.vertex.wgsl",
        "tests/fixtures/basic_shader.fragment.wgsl",
        null,
    );
}

test "compiler emits WGSL for a basic vertex shader fixture" {
    try expectWgslFixture(
        "tests/fixtures/basic_vertex.zw",
        "tests/fixtures/basic_vertex.wgsl",
        null,
        null,
    );
}

test "compiler emits WGSL for a basic fragment shader fixture" {
    try expectWgslFixture(
        "tests/fixtures/basic_fragment.zw",
        null,
        "tests/fixtures/basic_fragment.wgsl",
        null,
    );
}

test "compiler emits WGSL for a shared uniform fixture" {
    try expectWgslFixture(
        "tests/fixtures/uniforms.zw",
        "tests/fixtures/uniforms.vertex.wgsl",
        "tests/fixtures/uniforms.fragment.wgsl",
        null,
    );
}

test "compiler wraps scalar and vec2 uniforms for WGSL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\uniform :time, Float
        \\uniform :resolution, Vec2
        \\
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  def main
        \\    gl_Position = vec4(position * time, 1.0)
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(output.vertex_source != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "struct _zwgsl_uniform_time") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "@align(16) value: f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "var<uniform> time: _zwgsl_uniform_time;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "struct _zwgsl_uniform_resolution") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "@align(16) value: vec2f") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "position * time.value") != null);
}

test "compiler emits WGSL compute output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\compute do
        \\  def main
        \\    id: UVec3 = global_invocation_id
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(output.vertex_source == null);
    try std.testing.expect(output.fragment_source == null);
    try std.testing.expect(output.compute_source != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "@compute @workgroup_size(1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "@builtin(global_invocation_id)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "let id: vec3u = global_invocation_id;") != null);
}

test "compiler lowers sampler uniforms and texture sampling for WGSL" {
    try expectWgslFixture(
        "examples/postprocess.zw",
        "tests/fixtures/postprocess.vertex.wgsl",
        "tests/fixtures/postprocess.fragment.wgsl",
        null,
    );
}

test "compiler lowers sampler parameters for WGSL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\uniform :scene_tex, Sampler2D
        \\
        \\def sample(scene: Sampler2D, uv: Vec2) -> Vec4
        \\  texture(scene, uv)
        \\end
        \\
        \\compute do
        \\  def main
        \\    uv: Vec2 = vec2(0.5, 0.25)
        \\    color: Vec4 = sample(scene_tex, uv)
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(output.compute_source != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "fn sample(scene_texture: texture_2d<f32>, scene_sampler: sampler, uv: vec2f) -> vec4f") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "return textureSample(scene_texture, scene_sampler, uv);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "sample(scene_tex_texture, scene_tex_sampler, uv)") != null);
}

test "compiler lowers immutable sampler aliases for WGSL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\uniform :scene_tex, Sampler2D
        \\
        \\compute do
        \\  def main
        \\    uv: Vec2 = vec2(0.5, 0.25)
        \\    let sampler = scene_tex
        \\    color: Vec4 = texture(sampler, uv)
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(output.compute_source != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "textureSample(scene_tex_texture, scene_tex_sampler, uv)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "let sampler") == null);
}

test "compiler lowers mod() calls to WGSL remainder operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\compute do
        \\  def main
        \\    value: Float = mod(5.0, 2.0)
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(output.compute_source != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "let value: f32 = 5.0 % 2.0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "mod(") == null);
}

test "compiler emits WGSL for the phong fixture" {
    try expectWgslFixture(
        "tests/fixtures/phong.zw",
        "tests/fixtures/phong.vertex.wgsl",
        "tests/fixtures/phong.fragment.wgsl",
        null,
    );
}

test "compiler omits fragment-only global helpers from vertex WGSL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\def vertex_scale(pos: Vec3) -> Vec4
        \\  vec4(pos * 0.5, 1.0)
        \\end
        \\
        \\def fragment_color(uv: Vec2) -> Vec4
        \\  vec4(uv, 0.0, 1.0)
        \\end
        \\
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  varying :v_uv, Vec2
        \\  def main
        \\    self.v_uv = vec2(0.5, 0.5)
        \\    gl_Position = vertex_scale(position)
        \\  end
        \\end
        \\
        \\fragment do
        \\  varying :v_uv, Vec2
        \\  output :frag_color, Vec4, location: 0
        \\  def main
        \\    frag_color = fragment_color(v_uv)
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(output.vertex_source != null);
    try std.testing.expect(output.fragment_source != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "fn vertex_scale") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "fn fragment_color") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.fragment_source.?, "fn fragment_color") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.fragment_source.?, "fn vertex_scale") == null);
}

test "compiler emits WGSL for dependent dimension fixtures" {
    try expectWgslFixture(
        "tests/fixtures/dependent_dim.zw",
        null,
        null,
        "tests/fixtures/dependent_dim.compute.wgsl",
    );
}

test "compiler emits WGSL for ADT match fixtures" {
    try expectWgslFixture(
        "tests/fixtures/match_shape.zw",
        null,
        null,
        "tests/fixtures/match_shape.compute.wgsl",
    );
}

test "compiler lowers symbol match patterns for WGSL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\compute do
        \\  def shade(mode: Symbol) -> Float
        \\    match mode
        \\    when :phong
        \\      1.0
        \\    when :flat
        \\      0.5
        \\    end
        \\  end
        \\
        \\  def main
        \\    let mode = :phong
        \\    value: Float = shade(mode)
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(output.compute_source != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "mode: i32 = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "if (_match_value ==") != null);
}

test "compiler rejects compute shaders for GLSL ES 3.00" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\compute do
        \\  def main
        \\    id: UVec3 = global_invocation_id
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{});
    try std.testing.expectEqual(@as(usize, 1), output.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(output.errors[0].message), "does not support compute shaders") != null);
}

test "compiler rejects mixing compute with render stages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\vertex do
        \\  def main
        \\    gl_Position = vec4(1.0)
        \\  end
        \\end
        \\
        \\compute do
        \\  def main
        \\    id: UVec3 = global_invocation_id
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });
    try std.testing.expect(output.errors.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(output.errors[0].message), "cannot be combined") != null);
}

test "compiler specializes constrained trait calls for WGSL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
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
        \\  def mul(other: Self) -> Self
        \\    self * other
        \\  end
        \\end
        \\
        \\def lerp(a: T, b: T, t: Float) -> T where T: Numeric
        \\  a.mul(1.0 - t).add(b.mul(t))
        \\end
        \\
        \\compute do
        \\  def main
        \\    value: Float = lerp(1.0, 2.0, 0.5)
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(output.compute_source != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "fn _trait_Numeric_Float_add") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "fn _trait_Numeric_Float_mul") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "fn _spec_lerp_Float_Float_Float") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "_spec_lerp_Float_Float_Float(1.0, 2.0, 0.5)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "_trait_Numeric_Float_") == null);
}

test "compiler lowers inout functions to WGSL pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\def increment(inout value: Float)
        \\  value += 1.0
        \\end
        \\
        \\def increment_twice(inout value: Float)
        \\  increment(value)
        \\  increment(value)
        \\end
        \\
        \\compute do
        \\  def main
        \\    total: Float = 1.0
        \\    increment_twice(total)
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(output.compute_source != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "fn increment(value: ptr<function, f32>)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "(*value) += 1.0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "fn increment_twice(value: ptr<function, f32>)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "increment(value);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "increment_twice(&total);") != null);
}
