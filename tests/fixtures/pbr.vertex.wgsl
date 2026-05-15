struct VertexInput {
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
}

struct VertexOutput {
    @builtin(position) gl_Position: vec4f,
    @location(0) v_normal: vec3f,
}

@group(0) @binding(0) var<uniform> mvp: mat4x4f;
struct _zwgsl_uniform_albedo {
    @align(16) value: vec3f,
}
@group(0) @binding(1) var<uniform> albedo: _zwgsl_uniform_albedo;
struct _zwgsl_uniform_metallic {
    @align(16) value: f32,
}
@group(0) @binding(2) var<uniform> metallic: _zwgsl_uniform_metallic;
struct _zwgsl_uniform_roughness {
    @align(16) value: f32,
}
@group(0) @binding(3) var<uniform> roughness: _zwgsl_uniform_roughness;

var<private> gl_Position: vec4f;
var<private> position: vec3f;
var<private> normal: vec3f;
var<private> v_normal: vec3f;

fn _zwgsl_vertex_main() {
    v_normal = normal;
    gl_Position = mvp * vec4f(position, 1.0);
}

@vertex
fn main(input: VertexInput) -> VertexOutput {
    position = input.position;
    normal = input.normal;
    _zwgsl_vertex_main();
    var output: VertexOutput;
    output.gl_Position = gl_Position;
    output.v_normal = v_normal;
    return output;
}
