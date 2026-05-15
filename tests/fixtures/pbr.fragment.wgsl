struct FragmentInput {
    @location(0) v_normal: vec3f,
}

struct FragmentOutput {
    @location(0) frag_color: vec4f,
}

@group(0) @binding(0) var<uniform> mvp: mat4x4f;
struct _zwgsl_uniform_albedo {
    @align(16) value: vec3f,
}
@group(0) @binding(1) var<uniform> albedo: _zwgsl_uniform_albedo;
struct _zwgsl_uniform_metallic {
    @align(16) value: f32,
}
@group(0) @binding(2) var<uniform> metallic: _zwgsl_uniform_metallic;
struct _zwgsl_uniform_roughness {
    @align(16) value: f32,
}
@group(0) @binding(3) var<uniform> roughness: _zwgsl_uniform_roughness;

var<private> v_normal: vec3f;
var<private> frag_color: vec4f;

fn saturate(x: f32) -> f32 {
    return clamp(x, 0.0, 1.0);
}

fn _zwgsl_fragment_main() {
    let n_dot_up: f32 = saturate(dot(normalize(v_normal), vec3f(0.0, 1.0, 0.0)));
    let energy: f32 = mix(0.04, 1.0, metallic.value);
    let color: vec3f = albedo.value * (energy * (1.0 - roughness.value) * n_dot_up);
    frag_color = vec4f(color, 1.0);
}

@fragment
fn main(input: FragmentInput) -> FragmentOutput {
    v_normal = input.v_normal;
    _zwgsl_fragment_main();
    var output: FragmentOutput;
    output.frag_color = frag_color;
    return output;
}
