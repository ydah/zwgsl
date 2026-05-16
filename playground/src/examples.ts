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
  summary: string;
  tags: string[];
  source: string;
};

export const exampleSources = [
  {
    id: "animated-uniforms",
    label: "Animated Uniforms",
    summary: "Uniform controls and animated fragment output.",
    tags: ["uniform", "fragment", "preview"],
    source: animatedUniformsSource,
  },
  {
    id: "hello-triangle",
    label: "Hello Triangle",
    summary: "Minimal vertex/fragment pipeline.",
    tags: ["vertex", "fragment"],
    source: helloTriangleSource,
  },
  {
    id: "phong",
    label: "Phong Lighting",
    summary: "Varyings, helper functions, and lighting math.",
    tags: ["lighting", "varying"],
    source: phongSource,
  },
  {
    id: "pbr",
    label: "PBR",
    summary: "Structs and reusable shading helpers.",
    tags: ["pbr", "struct"],
    source: pbrSource,
  },
  {
    id: "postprocess",
    label: "Postprocess",
    summary: "Texture sampling and fullscreen preview.",
    tags: ["texture", "sampler"],
    source: postprocessSource,
  },
  {
    id: "utah-teapot",
    label: "Utah Teapot",
    summary: "Larger procedural shader with where bindings.",
    tags: ["sdf", "where"],
    source: utahTeapotSource,
  },
  {
    id: "dependent-dimensions",
    label: "Dependent Dimensions",
    summary: "Compile-time vector dimension checks.",
    tags: ["compute", "types"],
    source: dependentDimSource,
  },
  {
    id: "adt-match",
    label: "ADT Match",
    summary: "Algebraic data types and pattern matching.",
    tags: ["adt", "match"],
    source: matchShapeSource,
  },
] satisfies ExampleSource[];

export const defaultExample = exampleSources[0];
