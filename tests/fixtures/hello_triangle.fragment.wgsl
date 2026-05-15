struct FragmentInput {
    @location(0) v_color: vec3f,
}

struct FragmentOutput {
    @location(0) frag_color: vec4f,
}

@group(0) @binding(0) var<uniform> mvp: mat4x4f;

var<private> v_color: vec3f;
var<private> frag_color: vec4f;

fn _zwgsl_fragment_main() {
    frag_color = vec4f(v_color, 1.0);
}

@fragment
fn main(input: FragmentInput) -> FragmentOutput {
    v_color = input.v_color;
    _zwgsl_fragment_main();
    var output: FragmentOutput;
    output.frag_color = frag_color;
    return output;
}
