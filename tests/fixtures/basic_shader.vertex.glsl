#version 300 es

uniform mat4 mvp;
uniform vec4 base_color;

layout(location = 0) in vec3 position;

out vec3 v_pos;

void main() {
    v_pos = position;
    gl_Position = mvp * vec4(position, 1.0);
}
