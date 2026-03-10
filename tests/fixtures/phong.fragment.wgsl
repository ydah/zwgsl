struct FragmentInput {
    @location(0) v_normal: vec3f,
    @location(1) v_world_pos: vec3f,
};

struct FragmentOutput {
    @location(0) frag_color: vec4f,
};

@group(0) @binding(0) var<uniform> model_matrix: mat4x4f;
@group(0) @binding(1) var<uniform> view_matrix: mat4x4f;
@group(0) @binding(2) var<uniform> projection_matrix: mat4x4f;
@group(0) @binding(3) var<uniform> light_pos: vec3f;
@group(0) @binding(4) var<uniform> base_color: vec4f;

var<private> v_normal: vec3f;
var<private> v_world_pos: vec3f;
var<private> frag_color: vec4f;

fn phong_strength(normal: vec3f, light_dir: vec3f) -> f32 {
    return max(dot(normalize(normal), normalize(light_dir)), 0.0);
}

fn __zwgsl_fragment_main() {
    let light_dir: vec3f = light_pos - v_world_pos;
    let light: f32 = phong_strength(v_normal, light_dir);
    frag_color = vec4f(base_color.rgb * (0.2 + 0.8 * light), base_color.a);
}

@fragment
fn main(input: FragmentInput) -> FragmentOutput {
    v_normal = input.v_normal;
    v_world_pos = input.v_world_pos;
    __zwgsl_fragment_main();
    var output: FragmentOutput;
    output.frag_color = frag_color;
    return output;
}
