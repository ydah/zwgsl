#version 300 es
precision mediump float;

uniform sampler2D scene_tex;

in vec2 v_uv;

layout(location = 0) out vec4 frag_color;

void main() {
    vec4 color = texture(scene_tex, v_uv);
    frag_color = vec4(color.rgb, 1.0);
}
