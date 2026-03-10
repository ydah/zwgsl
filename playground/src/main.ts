import "./styles.css";

import { createEditor } from "./editor";
import { createCompiler } from "./compiler";
import { createPreview } from "./preview";

const source = `vertex do
  input :position, Vec3, location: 0

  def main
    gl_Position = vec4(position, 1.0)
  end
end

fragment do
  output :frag_color, Vec4, location: 0

  def main
    frag_color = vec4(0.9, 0.5, 0.2, 1.0)
  end
end
`;

const status = document.querySelector<HTMLSpanElement>("#status")!;
const output = document.querySelector<HTMLElement>("#wgsl-output")!;
const button = document.querySelector<HTMLButtonElement>("#compile-button")!;
const canvas = document.querySelector<HTMLCanvasElement>("#preview-canvas")!;

const editor = await createEditor(document.querySelector<HTMLElement>("#editor")!, source);
const compiler = await createCompiler();
const preview = await createPreview(canvas);

const runCompile = async () => {
  status.textContent = "compiling";
  const result = await compiler.compile(editor.getValue());
  output.textContent = result.wgsl;
  status.textContent = result.diagnostics.length === 0 ? "ok" : `${result.diagnostics.length} issue(s)`;
  await preview.render(result);
};

editor.onDidChangeModelContent(() => {
  window.clearTimeout((runCompile as typeof runCompile & { timer?: number }).timer);
  (runCompile as typeof runCompile & { timer?: number }).timer = window.setTimeout(runCompile, 300);
});

button.addEventListener("click", () => void runCompile());
await runCompile();
