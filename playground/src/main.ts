import "./styles.css";

import { createEditor } from "./editor";
import { createCompiler, type CompileResult } from "./compiler";
import { createPreview } from "./preview";

const source = `uniform :tint, Vec4
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
let pendingTrigger: CompileTrigger | null = null;
let compileLoop: Promise<void> | null = null;

type CompileTrigger = "initial" | "edit" | "manual";

const setCompileButtonState = (busy: boolean) => {
  button.disabled = busy;
  button.textContent = busy ? "Compiling..." : "Compile";
  button.setAttribute("aria-busy", busy ? "true" : "false");
};

const compileTimestamp = () =>
  new Intl.DateTimeFormat("ja-JP", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(new Date());

const formatDiagnostic = (diagnostic: CompileResult["diagnostics"][number]) => {
  const line = Math.max(1, diagnostic.line || 1);
  const column = Math.max(1, diagnostic.column || 1);
  return `// L${line}:C${column} ${diagnostic.message}`;
};

const renderCompileOutput = (result: CompileResult) => {
  if (result.wgsl.trim().length > 0) return result.wgsl;
  if (result.diagnostics.length === 0) return "// No WGSL output.\n";
  return ["// Compile produced diagnostics only", ...result.diagnostics.map(formatDiagnostic)].join("\n");
};

const runCompile = async (trigger: CompileTrigger) => {
  setCompileButtonState(true);
  status.textContent = trigger === "manual" ? "compiling (manual)" : "compiling";

  try {
    const result = await compiler.compile(editor.getValue());
    output.textContent = renderCompileOutput(result);
    await preview.render(result);
    status.textContent =
      result.diagnostics.length === 0
        ? `ok • ${compileTimestamp()}`
        : `${result.diagnostics.length} issue(s) • ${compileTimestamp()}`;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    output.textContent = `// compile failed\n// ${message}\n`;
    status.textContent = "compile failed";
    previewStatus.textContent = "compile failed";
    console.error("zwgsl playground compile failed", error);
  } finally {
    setCompileButtonState(false);
  }
};

const drainCompileQueue = async () => {
  while (pendingTrigger) {
    const trigger = pendingTrigger;
    pendingTrigger = null;
    await runCompile(trigger);
  }
  compileLoop = null;
};

const requestCompile = (trigger: CompileTrigger) => {
  pendingTrigger = trigger;
  if (compileLoop) return;
  compileLoop = drainCompileQueue();
};

editor.onDidChangeModelContent(() => {
  window.clearTimeout(compileTimer);
  compileTimer = window.setTimeout(() => requestCompile("edit"), 300);
});

button.addEventListener("click", () => {
  window.clearTimeout(compileTimer);
  requestCompile("manual");
});

requestCompile("initial");
await compileLoop;
