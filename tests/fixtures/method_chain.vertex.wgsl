struct VertexInput {
    @location(0) position: vec3f,
}

struct VertexOutput {
    @builtin(position) gl_Position: vec4f,
    @location(0) v_color: vec3f,
}

@group(0) @binding(0) var<uniform> base_color: vec4f;

var<private> gl_Position: vec4f;
var<private> position: vec3f;
var<private> v_color: vec3f;

fn tone_map(color: vec3f) -> vec3f {
    return clamp(normalize(color), vec3f(0.0), vec3f(1.0));
}

fn _zwgsl_vertex_main() {
    v_color = tone_map(base_color.rgb);
    gl_Position = vec4f(position, 1.0);
}

@vertex
fn main(input: VertexInput) -> VertexOutput {
    position = input.position;
    _zwgsl_vertex_main();
    var output: VertexOutput;
    output.gl_Position = gl_Position;
    output.v_color = v_color;
    return output;
}
