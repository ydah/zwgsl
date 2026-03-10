struct VertexInput {
    @location(0) position: vec3f,
    @location(1) uv: vec2f,
}

struct VertexOutput {
    @builtin(position) gl_Position: vec4f,
    @location(0) v_uv: vec2f,
}

@group(0) @binding(0) var scene_tex_texture: texture_2d<f32>;
@group(0) @binding(1) var scene_tex_sampler: sampler;

var<private> gl_Position: vec4f;
var<private> position: vec3f;
var<private> uv: vec2f;
var<private> v_uv: vec2f;

fn __zwgsl_vertex_main() {
    v_uv = uv;
    gl_Position = vec4f(position, 1.0);
}

@vertex
fn main(input: VertexInput) -> VertexOutput {
    position = input.position;
    uv = input.uv;
    __zwgsl_vertex_main();
    var output: VertexOutput;
    output.gl_Position = gl_Position;
    output.v_uv = v_uv;
    return output;
}
