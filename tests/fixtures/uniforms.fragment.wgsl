struct FragmentOutput {
    @location(0) frag_color: vec4f,
};

@group(0) @binding(0) var<uniform> mvp: mat4x4f;
@group(0) @binding(1) var<uniform> tint: vec4f;

var<private> frag_color: vec4f;

fn __zwgsl_fragment_main() {
    frag_color = tint;
}

@fragment
fn main() -> FragmentOutput {
    __zwgsl_fragment_main();
    var output: FragmentOutput;
    output.frag_color = frag_color;
    return output;
}
