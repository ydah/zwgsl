struct VertexInput {
    @location(0) position: vec3f,
}

struct VertexOutput {
    @builtin(position) gl_Position: vec4f,
}

@group(0) @binding(0) var<uniform> mvp: mat4x4f;
@group(0) @binding(1) var<uniform> tint: vec4f;

var<private> gl_Position: vec4f;
var<private> position: vec3f;

fn __zwgsl_vertex_main() {
    gl_Position = mvp * vec4f(position, 1.0);
}

@vertex
fn main(input: VertexInput) -> VertexOutput {
    position = input.position;
    __zwgsl_vertex_main();
    var output: VertexOutput;
    output.gl_Position = gl_Position;
    return output;
}
