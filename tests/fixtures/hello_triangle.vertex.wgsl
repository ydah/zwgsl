struct VertexInput {
    @location(0) position: vec3f,
    @location(1) color: vec3f,
}

struct VertexOutput {
    @builtin(position) gl_Position: vec4f,
    @location(0) v_color: vec3f,
}

@group(0) @binding(0) var<uniform> mvp: mat4x4f;

var<private> gl_Position: vec4f;
var<private> position: vec3f;
var<private> color: vec3f;
var<private> v_color: vec3f;

fn _zwgsl_vertex_main() {
    v_color = color;
    gl_Position = mvp * vec4f(position, 1.0);
}

@vertex
fn main(input: VertexInput) -> VertexOutput {
    position = input.position;
    color = input.color;
    _zwgsl_vertex_main();
    var output: VertexOutput;
    output.gl_Position = gl_Position;
    output.v_color = v_color;
    return output;
}
