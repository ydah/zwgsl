import helloTriangleSource from "../../examples/hello_triangle.zw?raw";
import pbrSource from "../../examples/pbr.zw?raw";
import phongSource from "../../examples/phong.zw?raw";
import postprocessSource from "../../examples/postprocess.zw?raw";
import utahTeapotSource from "../../examples/utah_teapot.zw?raw";
import dependentDimSource from "../../tests/fixtures/dependent_dim.zw?raw";
import matchShapeSource from "../../tests/fixtures/match_shape.zw?raw";

const animatedUniformsSource = `uniform :tint, Vec4
uniform :iTime, Float
uniform :iResolution, Vec2

vertex do
  input :position, Vec3, location: 0
  varying :v_uv, Vec2

  def main
    self.v_uv = position.xy * 0.5 + vec2(0.5, 0.5)
    gl_Position = vec4(position, 1.0)
  end
end

fragment do
  varying :v_uv, Vec2
  output :frag_color, Vec4, location: 0

  def main
    aspect = iResolution.x / max(iResolution.y, 1.0)
    pulse = 0.55 + 0.45 * sin(iTime)
    glow = vec3(v_uv.x, v_uv.y * aspect, 1.0 - v_uv.x)
    frag_color = vec4((tint.rgb * pulse) * glow, tint.a)
  end
end
`;

export type ExampleSource = {
  id: string;
  label: string;
  source: string;
};

export const exampleSources = [
  {
    id: "animated-uniforms",
    label: "Animated Uniforms",
    source: animatedUniformsSource,
  },
  {
    id: "hello-triangle",
    label: "Hello Triangle",
    source: helloTriangleSource,
  },
  {
    id: "phong",
    label: "Phong Lighting",
    source: phongSource,
  },
  {
    id: "pbr",
    label: "PBR",
    source: pbrSource,
  },
  {
    id: "postprocess",
    label: "Postprocess",
    source: postprocessSource,
  },
  {
    id: "utah-teapot",
    label: "Utah Teapot",
    source: utahTeapotSource,
  },
  {
    id: "dependent-dimensions",
    label: "Dependent Dimensions",
    source: dependentDimSource,
  },
  {
    id: "adt-match",
    label: "ADT Match",
    source: matchShapeSource,
  },
] satisfies ExampleSource[];

export const defaultExample = exampleSources[0];
