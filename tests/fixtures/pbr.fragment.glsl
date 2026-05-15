#version 300 es
precision highp float;

uniform mat4 mvp;
uniform vec3 albedo;
uniform float metallic;
uniform float roughness;

in vec3 v_normal;

layout(location = 0) out vec4 frag_color;

float saturate(float x) {
    return clamp(x, 0.0, 1.0);
}

void main() {
    float n_dot_up = saturate(dot(normalize(v_normal), vec3(0.0, 1.0, 0.0)));
    float energy = mix(0.04, 1.0, metallic);
    vec3 color = albedo * (energy * (1.0 - roughness) * n_dot_up);
    frag_color = vec4(color, 1.0);
}
