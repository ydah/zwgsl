struct VertexInput {
    @location(0) position: vec3f,
}

struct VertexOutput {
    @builtin(position) gl_Position: vec4f,
}

var<private> gl_Position: vec4f;
var<private> position: vec3f;

fn _zwgsl_vertex_main() {
    gl_Position = vec4f(position, 1.0);
}

@vertex
fn main(input: VertexInput) -> VertexOutput {
    position = input.position;
    _zwgsl_vertex_main();
    var output: VertexOutput;
    output.gl_Position = gl_Position;
    return output;
}
