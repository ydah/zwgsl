struct VertexInput {
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
}

struct VertexOutput {
    @builtin(position) gl_Position: vec4f,
    @location(0) v_normal: vec3f,
    @location(1) v_world_pos: vec3f,
}

@group(0) @binding(0) var<uniform> model_matrix: mat4x4f;
@group(0) @binding(1) var<uniform> view_matrix: mat4x4f;
@group(0) @binding(2) var<uniform> projection_matrix: mat4x4f;
@group(0) @binding(3) var<uniform> light_pos: vec3f;
@group(0) @binding(4) var<uniform> base_color: vec4f;

var<private> gl_Position: vec4f;
var<private> position: vec3f;
var<private> normal: vec3f;
var<private> v_normal: vec3f;
var<private> v_world_pos: vec3f;

fn phong_strength(normal: vec3f, light_dir: vec3f) -> f32 {
    return max(dot(normalize(normal), normalize(light_dir)), 0.0);
}

fn __zwgsl_vertex_main() {
    let world_pos: vec4f = model_matrix * vec4f(position, 1.0);
    v_normal = mat3x3f(model_matrix) * normal;
    v_world_pos = world_pos.xyz;
    gl_Position = projection_matrix * view_matrix * world_pos;
}

@vertex
fn main(input: VertexInput) -> VertexOutput {
    position = input.position;
    normal = input.normal;
    __zwgsl_vertex_main();
    var output: VertexOutput;
    output.gl_Position = gl_Position;
    output.v_normal = v_normal;
    output.v_world_pos = v_world_pos;
    return output;
}
