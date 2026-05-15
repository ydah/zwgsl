#version 300 es

uniform mat4 mvp;
uniform vec3 albedo;
uniform float metallic;
uniform float roughness;

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;

out vec3 v_normal;

float saturate(float x) {
    return clamp(x, 0.0, 1.0);
}

void main() {
    v_normal = normal;
    gl_Position = mvp * vec4(position, 1.0);
}
