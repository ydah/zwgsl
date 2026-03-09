#version 300 es

uniform vec4 base_color;

layout(location = 0) in vec3 position;

out vec3 v_color;

vec3 tone_map(vec3 color) {
    return clamp(normalize(color), 0.0, 1.0);
}

void main() {
    v_color = tone_map(base_color.rgb);
    gl_Position = vec4(position, 1.0);
}
