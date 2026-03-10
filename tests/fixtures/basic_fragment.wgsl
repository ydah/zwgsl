struct FragmentOutput {
    @location(0) frag_color: vec4f,
};

var<private> frag_color: vec4f;

fn __zwgsl_fragment_main() {
    frag_color = vec4f(0.2, 0.4, 0.8, 1.0);
}

@fragment
fn main() -> FragmentOutput {
    __zwgsl_fragment_main();
    var output: FragmentOutput;
    output.frag_color = frag_color;
    return output;
}
