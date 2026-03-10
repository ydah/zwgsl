struct FragmentInput {
    @location(0) v_pos: vec3f,
}

struct FragmentOutput {
    @location(0) frag_color: vec4f,
}

@group(0) @binding(0) var<uniform> mvp: mat4x4f;
@group(0) @binding(1) var<uniform> base_color: vec4f;

var<private> v_pos: vec3f;
var<private> frag_color: vec4f;

fn __zwgsl_fragment_main() {
    frag_color = vec4f(v_pos, base_color.a);
}

@fragment
fn main(input: FragmentInput) -> FragmentOutput {
    v_pos = input.v_pos;
    __zwgsl_fragment_main();
    var output: FragmentOutput;
    output.frag_color = frag_color;
    return output;
}
