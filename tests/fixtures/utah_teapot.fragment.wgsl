struct FragmentInput {
    @location(0) v_uv: vec2f,
}

struct FragmentOutput {
    @location(0) frag_color: vec4f,
}

struct _zwgsl_uniform_time {
    @align(16) value: f32,
}
@group(0) @binding(0) var<uniform> time: _zwgsl_uniform_time;
struct _zwgsl_uniform_resolution {
    @align(16) value: vec2f,
}
@group(0) @binding(1) var<uniform> resolution: _zwgsl_uniform_resolution;

var<private> v_uv: vec2f;
var<private> frag_color: vec4f;

fn cross2(a: vec2f, b: vec2f) -> f32 {
    return a.x * b.y - b.x * a.y;
}

fn bezier_distance(m: vec2f, n: vec2f, o: vec2f, p: vec3f) -> vec2f {
    let q: vec2f = p.xy;
    let m0: vec2f = m - q;
    let n0: vec2f = n - q;
    let o0: vec2f = o - q;
    let x: f32 = cross2(m0, o0);
    let y: f32 = 2.0 * cross2(n0, m0);
    let z: f32 = 2.0 * cross2(o0, n0);
    let i: vec2f = o0 - m0;
    let j: vec2f = o0 - n0;
    let k: vec2f = n0 - m0;
    let s: vec2f = 2.0 * (x * i + y * j + z * k);
    let r: vec2f = m0 + (y * z - x * x) * vec2f(s.y, -s.x) / dot(s, s);
    let t: f32 = clamp((cross2(r, i) + 2.0 * cross2(k, r)) / (x + x + y + z), 0.0, 1.0);
    let curve: vec2f = m0 + t * (k + k + t * (j - k));
    return vec2f(sqrt(dot(curve, curve) + p.z * p.z), t);
}

fn smooth_min(a: f32, b: f32, k: f32) -> f32 {
    let h: f32 = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

fn body_segment(a: vec2f, b: vec2f, c: vec2f, profile: vec3f) -> f32 {
    return (bezier_distance(a, b, c, profile).x - 0.015) * 0.7;
}

fn teapot_body_distance(p: vec3f) -> f32 {
    let profile: vec3f = vec3f(sqrt(max(dot(p, p) - p.y * p.y, 0.0)), p.y, 0.0);
    let seg4: f32 = body_segment(vec2f(0.56, 0.9), vec2f(0.56, 0.96), vec2f(0.12, 1.02), profile);
    let seg2: f32 = body_segment(vec2f(0.8, 0.3), vec2f(0.8, 0.48), vec2f(0.64, 0.9), profile);
    let seg3: f32 = body_segment(vec2f(0.64, 0.9), vec2f(0.6, 0.93), vec2f(0.56, 0.9), profile);
    let seg0: f32 = body_segment(vec2f(0.0, 0.0), vec2f(0.64, 0.0), vec2f(0.64, 0.03), profile);
    let seg1: f32 = body_segment(vec2f(0.64, 0.03), vec2f(0.8, 0.12), vec2f(0.8, 0.3), profile);
    let seg5: f32 = body_segment(vec2f(0.12, 1.02), vec2f(0.0, 1.05), vec2f(0.16, 1.14), profile);
    let seg6: f32 = body_segment(vec2f(0.16, 1.14), vec2f(0.2, 1.2), vec2f(0.0, 1.2), profile);
    return min(min(min(seg0, seg1), min(seg2, seg3)), min(min(seg4, seg5), seg6));
}

fn teapot_attachment_distance(p: vec3f) -> f32 {
    let spout_tip: vec2f = bezier_distance(vec2f(1.0, 0.72), vec2f(0.92, 0.48), vec2f(0.72, 0.42), p);
    let spout_root: vec2f = bezier_distance(vec2f(1.16, 0.96), vec2f(1.04, 0.9), vec2f(1.0, 0.72), p);
    let spout: f32 = max(p.y - 0.9, min(abs(spout_root.x - 0.07) - 0.01, spout_tip.x * (1.0 - 0.75 * spout_tip.y) - 0.08));
    let handle_a: f32 = bezier_distance(vec2f(-0.6, 0.78), vec2f(-1.16, 0.84), vec2f(-1.16, 0.63), p).x;
    let handle_b: f32 = bezier_distance(vec2f(-1.16, 0.63), vec2f(-1.2, 0.42), vec2f(-0.72, 0.24), p).x;
    let handle: f32 = min(handle_a, handle_b) - 0.06;
    return min(handle, spout);
}

fn scene_distance(p: vec3f) -> f32 {
    return smooth_min(teapot_body_distance(p), teapot_attachment_distance(p), 0.02);
}

fn hsv2rgb_smooth(h: f32, s: f32, v: f32) -> vec3f {
    let rgb: vec3f = clamp(abs((h * 6.0 + vec3f(0.0, 4.0, 2.0)) % 6.0 - 3.0) - 1.0, vec3f(0.0), vec3f(1.0));
    let smoothed_rgb: vec3f = rgb * rgb * (3.0 - 2.0 * rgb);
    return v * mix(vec3f(1.0), smoothed_rgb, s);
}

fn tangent_from_normal(n: vec3f) -> vec3f {
    let anchor: vec3f = mix(vec3f(0.0, 0.0, 1.0), vec3f(1.0, 0.0, 0.0), step(0.999, abs(n.z)));
    return normalize(cross(anchor, n));
}

fn bitangent_from_normal(n: vec3f, t: vec3f) -> vec3f {
    return normalize(cross(n, t));
}

fn compute_brdf(n: vec3f, l: vec3f, h: vec3f, r: vec3f, t: vec3f, b: vec3f) -> vec3f {
    let cos_theta_r: f32 = max(dot(n, r), 0.001);
    let alpha: vec2f = vec2f(0.045, 0.068);
    let e2: f32 = dot(h, b) / alpha.y;
    let cos_theta_i: f32 = max(dot(n, l), 0.001);
    let one_over_pi: f32 = 0.31830988618;
    let e1: f32 = dot(h, t) / alpha.x;
    let denom: f32 = max(1.0 + dot(h, n), 0.001);
    let exponent: f32 = -2.0 * ((e1 * e1 + e2 * e2) / denom);
    let lobe: vec2f = vec2f(0.45, 0.048);
    let brdf: f32 = lobe.x * one_over_pi + lobe.y * (1.0 / sqrt(cos_theta_i * cos_theta_r)) * (1.0 / (12.56637061436 * alpha.x * alpha.y)) * exp(exponent);
    let scale: vec3f = vec3f(1.0, 20.0, 10.0);
    let intensity: f32 = scale.x * lobe.x * one_over_pi + scale.y * lobe.y * cos_theta_i * brdf + scale.z * max(dot(h, n), 0.0) * lobe.y;
    return clamp(intensity * vec3f(0.45, 0.54, 1.0), vec3f(0.0), vec3f(1.0));
}

fn estimate_normal(p: vec3f, ray: vec3f, travel: f32) -> vec3f {
    let pitch: f32 = 0.4 * travel / max(resolution.value.x, 1.0);
    let d: vec2f = vec2f(-1.0, 1.0) * pitch;
    let p1: vec3f = p + vec3f(d.x, d.y, d.y);
    let f1: f32 = scene_distance(p1);
    let p2: vec3f = p + vec3f(d.y, d.x, d.y);
    let p0: vec3f = p + vec3f(d.x, d.x, d.x);
    let f0: f32 = scene_distance(p0);
    let f2: f32 = scene_distance(p2);
    let p3: vec3f = p + vec3f(d.y, d.y, d.x);
    let f3: f32 = scene_distance(p3);
    let grad: vec3f = p0 * f0 + p1 * f1 + p2 * f2 + p3 * f3 - p * (f0 + f1 + f2 + f3);
    return normalize(grad - max(0.0, dot(grad, ray)) * ray);
}

fn march_once(origin: vec3f, ray: vec3f, state: vec4f) -> vec4f {
    let next_state: vec4f = state;
    var _ssa_15: vec4f;
    if (state.z > 0.5 && state.x < 4.7) {
        let next_step: f32 = scene_distance(origin + ray * state.x);
        var _ssa_14: vec4f;
        if (next_step < 0.0005) {
            _ssa_14 = vec4f(state.x, next_step, 0.0, 0.0);
        } else {
            _ssa_14 = vec4f(state.x + next_step, next_step, 1.0, 0.0);
        }
        _ssa_15 = _ssa_14;
    } else {
        _ssa_15 = next_state;
    }
    return _ssa_15;
}

fn shadow_once(hit_pos: vec3f, light_dir: vec3f, state: vec2f) -> vec2f {
    let next_t: f32 = state.y + 0.02;
    return vec2f(min(state.x, scene_distance(hit_pos + light_dir * next_t) / next_t), next_t);
}

fn shade(uv: vec2f) -> vec3f {
    let screen: vec2f = uv + uv - 1.0;
    let pixel: vec2f = vec2f(screen.x * resolution.value.x / max(resolution.value.y, 1.0), screen.y);
    let orbit: vec2f = vec2f(0.35 * sin(time.value * 0.23), 0.18 * cos(time.value * 0.17));
    let camera_angle: f32 = 5.0 + 0.2 * time.value + orbit.x;
    let origin: vec3f = 2.9 * vec3f(cos(camera_angle), 0.7 - orbit.y, sin(camera_angle));
    let forward: vec3f = normalize(vec3f(0.0, 1.0, 0.0) * 0.4 - origin);
    let right: vec3f = normalize(cross(forward, vec3f(0.0, 1.0, 0.0)));
    let up: vec3f = cross(right, forward);
    let ray: vec3f = normalize(pixel.x * right + pixel.y * up + forward + forward);
    let bg: vec3f = mix(hsv2rgb_smooth(0.5 + time.value * 0.02, 0.35, 0.4), hsv2rgb_smooth(-0.5 + time.value * 0.02, 0.35, 0.7), uv.y);
    let vignette: f32 = pow(16.0 * uv.x * uv.y * (1.0 - uv.x) * (1.0 - uv.y), 0.16);
    let color: vec3f = bg;
    let march: vec4f = vec4f(0.0, 0.1, 1.0, 0.0);
    let _ssa_98: vec4f = march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march_once(origin, ray, march))))))))))))))))))))))))))))))))))))))))))))))));
    var _ssa_148: vec3f;
    if (_ssa_98.z < 0.5 && _ssa_98.x < 4.7) {
        let hit_pos: vec3f = origin + ray * _ssa_98.x;
        let normal: vec3f = estimate_normal(hit_pos, ray, _ssa_98.x);
        let light_dir: vec3f = normalize(vec3f(1.0, 0.72, 1.0));
        let view_dir: vec3f = normalize(origin - hit_pos);
        let half_dir: vec3f = normalize(light_dir + view_dir);
        let reflected: vec3f = normalize(reflect(vec3f(0.0) - light_dir, normal));
        let tangent: vec3f = tangent_from_normal(normal);
        let bitangent: vec3f = bitangent_from_normal(normal, tangent);
        let shadow_state: vec2f = vec2f(1.0, 0.0);
        let highlight: f32 = pow(max(dot(reflect(vec3f(0.0) - light_dir, normal), view_dir), 0.0), 32.0);
        _ssa_148 = compute_brdf(normal, light_dir, half_dir, reflected, tangent, bitangent) * (0.35 + 0.65 * clamp(3.0 * shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_once(hit_pos, light_dir, shadow_state)))))))))))))))))))).x, 0.0, 1.0)) + vec3f(0.15 * highlight);
    } else {
        _ssa_148 = color;
    }
    return clamp(_ssa_148 * vignette, vec3f(0.0), vec3f(1.0));
}

fn _zwgsl_fragment_main() {
    let color: vec3f = shade(v_uv);
    frag_color = vec4f(color, 1.0);
}

@fragment
fn main(input: FragmentInput) -> FragmentOutput {
    v_uv = input.v_uv;
    _zwgsl_fragment_main();
    var output: FragmentOutput;
    output.frag_color = frag_color;
    return output;
}
