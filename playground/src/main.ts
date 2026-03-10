import "./styles.css";

import { createEditor } from "./editor";
import { createCompiler } from "./compiler";
import { createPreview } from "./preview";

const source = `uniform :tint, Vec4
uniform :iTime, Float
uniform :iResolution, Vec2

vertex do
  input :position, Vec3, location: 0

  def main
    gl_Position = vec4(position, 1.0)
  end
end

fragment do
  output :frag_color, Vec4, location: 0

  def main
    uv = vec2(position.x, position.y) * 0.5 + vec2(0.5, 0.5)
    aspect = iResolution.x / max(iResolution.y, 1.0)
    pulse = 0.55 + 0.45 * sin(iTime)
    glow = vec3(uv.x, uv.y * aspect, 1.0 - uv.x)
    frag_color = vec4((tint.rgb * pulse) * glow, tint.a)
  end
end
`;

const status = document.querySelector<HTMLSpanElement>("#status")!;
const output = document.querySelector<HTMLElement>("#wgsl-output")!;
const button = document.querySelector<HTMLButtonElement>("#compile-button")!;
const canvas = document.querySelector<HTMLCanvasElement>("#preview-canvas")!;
const previewStatus = document.querySelector<HTMLSpanElement>("#preview-status")!;
const uniformControls = document.querySelector<HTMLElement>("#uniform-controls")!;

const editor = await createEditor(document.querySelector<HTMLElement>("#editor")!, source);
const compiler = await createCompiler();
const preview = await createPreview(canvas, uniformControls, previewStatus);
let compileTimer = 0;

const runCompile = async () => {
  status.textContent = "compiling";
  const result = await compiler.compile(editor.getValue());
  output.textContent = result.wgsl;
  status.textContent = result.diagnostics.length === 0 ? "ok" : `${result.diagnostics.length} issue(s)`;
  await preview.render(result);
};

editor.onDidChangeModelContent(() => {
  window.clearTimeout(compileTimer);
  compileTimer = window.setTimeout(runCompile, 300);
});

button.addEventListener("click", () => void runCompile());
await runCompile();
