struct FragmentInput {
    @location(0) v_uv: vec2f,
};

struct FragmentOutput {
    @location(0) frag_color: vec4f,
};

@group(0) @binding(0) var scene_tex_texture: texture_2d<f32>;
@group(0) @binding(1) var scene_tex_sampler: sampler;

var<private> v_uv: vec2f;
var<private> frag_color: vec4f;

fn __zwgsl_fragment_main() {
    let color: vec4f = textureSample(scene_tex_texture, scene_tex_sampler, v_uv);
    frag_color = vec4f(color.rgb, 1.0);
}

@fragment
fn main(input: FragmentInput) -> FragmentOutput {
    v_uv = input.v_uv;
    __zwgsl_fragment_main();
    var output: FragmentOutput;
    output.frag_color = frag_color;
    return output;
}
