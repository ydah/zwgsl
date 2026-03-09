#version 300 es
precision mediump float;

uniform vec4 base_color;

in vec3 v_color;

layout(location = 0) out vec4 frag_color;

vec3 tone_map(vec3 color) {
    return clamp(normalize(color), 0.0, 1.0);
}

void main() {
    frag_color = vec4(v_color, base_color.a);
}
