#version 300 es
precision highp float;

uniform mat4 mvp;
uniform vec4 base_color;

in vec3 v_pos;

layout(location = 0) out vec4 frag_color;

void main() {
    frag_color = vec4(v_pos, base_color.a);
}
