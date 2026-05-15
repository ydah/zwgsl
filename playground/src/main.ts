import "./styles.css";

import { createEditor } from "./editor";
import { createCompiler, type CompileResult } from "./compiler";
import { defaultExample, exampleSources } from "./examples";
import { createPreview } from "./preview";

const status = document.querySelector<HTMLSpanElement>("#status")!;
const output = document.querySelector<HTMLElement>("#wgsl-output")!;
const button = document.querySelector<HTMLButtonElement>("#compile-button")!;
const canvas = document.querySelector<HTMLCanvasElement>("#preview-canvas")!;
const previewStatus = document.querySelector<HTMLSpanElement>("#preview-status")!;
const uniformControls = document.querySelector<HTMLElement>("#uniform-controls")!;
const sampleSelect = document.querySelector<HTMLSelectElement>("#sample-select")!;
const copyWgslButton = document.querySelector<HTMLButtonElement>("#copy-wgsl-button")!;
const copyDiagnosticsButton = document.querySelector<HTMLButtonElement>("#copy-diagnostics-button")!;
const downloadSourceButton = document.querySelector<HTMLButtonElement>("#download-source-button")!;
const downloadWgslButton = document.querySelector<HTMLButtonElement>("#download-wgsl-button")!;

const editor = await createEditor(
  document.querySelector<HTMLElement>("#editor")!,
  defaultExample.source,
);
const compiler = await createCompiler();
const preview = await createPreview(canvas, uniformControls, previewStatus);
let compileTimer = 0;
let pendingTrigger: CompileTrigger | null = null;
let compileLoop: Promise<void> | null = null;
let isLoadingSample = false;
let latestWgsl = "";
let latestDiagnostics = "";

type CompileTrigger = "initial" | "edit" | "manual" | "sample";

const customOption = new Option("Custom", "custom");
sampleSelect.append(customOption);

for (const example of exampleSources) {
  sampleSelect.append(new Option(example.label, example.id));
}

sampleSelect.value = defaultExample.id;

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

const formatCompileDuration = (milliseconds: number) =>
  milliseconds < 100 ? `${milliseconds.toFixed(1)}ms` : `${Math.round(milliseconds)}ms`;

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

const renderDiagnostics = (result: CompileResult) =>
  result.diagnostics.map(formatDiagnostic).join("\n");

const updateActionButtons = () => {
  const hasWgsl = latestWgsl.trim().length > 0;
  copyWgslButton.disabled = !hasWgsl;
  downloadWgslButton.disabled = !hasWgsl;
  copyDiagnosticsButton.disabled = latestDiagnostics.trim().length === 0;
};

const selectedSampleId = () => (sampleSelect.value === "custom" ? "custom" : sampleSelect.value);

const downloadText = (filename: string, contents: string, type: string) => {
  const blob = new Blob([contents], { type });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.append(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 0);
};

const copyText = async (contents: string) => {
  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(contents);
      return;
    } catch {
      // Fall back to the selection API for browsers that expose clipboard but
      // still reject writes without a permission prompt.
    }
  }

  const textarea = document.createElement("textarea");
  textarea.value = contents;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "fixed";
  textarea.style.opacity = "0";
  document.body.append(textarea);
  textarea.select();
  document.execCommand("copy");
  textarea.remove();
};

const flashButtonLabel = (button: HTMLButtonElement, label: string) => {
  const previous = button.textContent ?? "";
  button.textContent = label;
  window.setTimeout(() => {
    button.textContent = previous;
  }, 1200);
};

const runCompile = async (trigger: CompileTrigger) => {
  setCompileButtonState(true);
  status.textContent =
    trigger === "manual"
      ? "compiling (manual)"
      : trigger === "sample"
        ? "compiling sample"
        : "compiling";

  const compileStartedAt = performance.now();

  try {
    const result = await compiler.compile(editor.getValue());
    const compileDuration = performance.now() - compileStartedAt;
    latestWgsl = result.wgsl;
    latestDiagnostics = renderDiagnostics(result);
    output.textContent = renderCompileOutput(result);
    updateActionButtons();
    await preview.render(result);
    status.textContent =
      result.diagnostics.length === 0
        ? `ok • compile ${formatCompileDuration(compileDuration)} • ${compileTimestamp()}`
        : `${result.diagnostics.length} issue(s) • compile ${formatCompileDuration(compileDuration)} • ${compileTimestamp()}`;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const compileDuration = performance.now() - compileStartedAt;
    latestWgsl = "";
    latestDiagnostics = `// compile failed\n// ${message}`;
    output.textContent = `// compile failed\n// ${message}\n`;
    updateActionButtons();
    status.textContent = `compile failed • compile ${formatCompileDuration(compileDuration)}`;
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
  if (!isLoadingSample) sampleSelect.value = "custom";
  compileTimer = window.setTimeout(() => requestCompile("edit"), 300);
});

button.addEventListener("click", () => {
  window.clearTimeout(compileTimer);
  requestCompile("manual");
});

copyWgslButton.addEventListener("click", async () => {
  await copyText(latestWgsl);
  flashButtonLabel(copyWgslButton, "Copied");
});

copyDiagnosticsButton.addEventListener("click", async () => {
  await copyText(latestDiagnostics);
  flashButtonLabel(copyDiagnosticsButton, "Copied");
});

downloadSourceButton.addEventListener("click", () => {
  downloadText(`${selectedSampleId()}.zw`, editor.getValue(), "text/plain;charset=utf-8");
  flashButtonLabel(downloadSourceButton, "Saved");
});

downloadWgslButton.addEventListener("click", () => {
  downloadText(`${selectedSampleId()}.wgsl`, latestWgsl, "text/plain;charset=utf-8");
  flashButtonLabel(downloadWgslButton, "Saved");
});

sampleSelect.addEventListener("change", () => {
  const example = exampleSources.find((entry) => entry.id === sampleSelect.value);
  if (!example) return;

  isLoadingSample = true;
  editor.setValue(example.source);
  isLoadingSample = false;

  window.clearTimeout(compileTimer);
  requestCompile("sample");
});

updateActionButtons();
requestCompile("initial");
await compileLoop;
