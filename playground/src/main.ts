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
const outputTabButtons = Array.from(
  document.querySelectorAll<HTMLButtonElement>("[data-output-tab]"),
);

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
let latestResult: CompileResult | null = null;
let activeOutputTab: OutputTab = "all";

type CompileTrigger = "initial" | "edit" | "manual" | "sample";
type OutputTab = "all" | "vertex" | "fragment" | "compute" | "diagnostics" | "resources";

const sampleQueryKey = "sample";

const sampleIdFromLocation = () => new URLSearchParams(window.location.search).get(sampleQueryKey);

const findSample = (sampleId: string | null) =>
  sampleId ? exampleSources.find((entry) => entry.id === sampleId) : null;

const updateSampleUrl = (sampleId: string | null) => {
  const url = new URL(window.location.href);
  if (sampleId) {
    url.searchParams.set(sampleQueryKey, sampleId);
  } else {
    url.searchParams.delete(sampleQueryKey);
  }
  window.history.replaceState(null, "", `${url.pathname}${url.search}${url.hash}`);
};

const customOption = new Option("Custom", "custom");
sampleSelect.append(customOption);

for (const example of exampleSources) {
  sampleSelect.append(new Option(example.label, example.id));
}

const initialSampleId = sampleIdFromLocation();
const initialSample = findSample(initialSampleId);

if (initialSample) {
  editor.setValue(initialSample.source);
  sampleSelect.value = initialSample.id;
} else {
  sampleSelect.value = defaultExample.id;
  if (initialSampleId) updateSampleUrl(null);
}

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

const renderStageOutput = (stage: "vertex" | "fragment" | "compute", source: string | null) =>
  source && source.trim().length > 0 ? source : `// No ${stage} output.\n`;

const renderResourceLayout = (result: CompileResult) => {
  const sources = [
    ["vertex", result.vertex],
    ["fragment", result.fragment],
    ["compute", result.compute],
  ] as const;
  const rows: string[] = [];

  for (const [stage, source] of sources) {
    if (!source) continue;

    for (const match of source.matchAll(/@group\((\d+)\)\s*@binding\((\d+)\)\s*var(?:<([^>]+)>)?\s+([A-Za-z_]\w*):\s*([^;]+);/g)) {
      const bindingClass = match[3] ? `<${match[3]}> ` : "";
      rows.push(`${stage}: group ${match[1]} binding ${match[2]} ${bindingClass}${match[4]}: ${match[5].trim()}`);
    }

    for (const match of source.matchAll(/@location\((\d+)\)\s+([A-Za-z_]\w*):\s*([^,\n}]+)/g)) {
      rows.push(`${stage}: location ${match[1]} ${match[2]}: ${match[3].trim()}`);
    }
  }

  if (rows.length === 0) return "// No resources or stage locations detected.\n";
  return ["// Generated resource layout", ...rows.map((row) => `// ${row}`)].join("\n");
};

const outputTabAvailable = (result: CompileResult, tab: OutputTab) => {
  switch (tab) {
    case "all":
      return true;
    case "vertex":
      return Boolean(result.vertex?.trim());
    case "fragment":
      return Boolean(result.fragment?.trim());
    case "compute":
      return Boolean(result.compute?.trim());
    case "diagnostics":
      return result.diagnostics.length > 0;
    case "resources":
      return !renderResourceLayout(result).startsWith("// No resources");
  }
};

const resolveOutputTab = (result: CompileResult) =>
  outputTabAvailable(result, activeOutputTab) ? activeOutputTab : "all";

const renderOutputTab = (result: CompileResult, tab: OutputTab) => {
  switch (tab) {
    case "all":
      return renderCompileOutput(result);
    case "vertex":
      return renderStageOutput("vertex", result.vertex);
    case "fragment":
      return renderStageOutput("fragment", result.fragment);
    case "compute":
      return renderStageOutput("compute", result.compute);
    case "diagnostics":
      return latestDiagnostics.trim().length > 0 ? latestDiagnostics : "// No diagnostics.\n";
    case "resources":
      return renderResourceLayout(result);
  }
};

const renderOutputPanel = (result: CompileResult) => {
  activeOutputTab = resolveOutputTab(result);
  output.textContent = renderOutputTab(result, activeOutputTab);
  for (const button of outputTabButtons) {
    const tab = button.dataset.outputTab as OutputTab;
    button.disabled = !outputTabAvailable(result, tab);
    button.setAttribute("aria-pressed", tab === activeOutputTab ? "true" : "false");
  }
};

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
    latestResult = result;
    latestWgsl = result.wgsl;
    latestDiagnostics = renderDiagnostics(result);
    renderOutputPanel(result);
    updateActionButtons();
    await preview.render(result);
    status.textContent =
      result.diagnostics.length === 0
        ? `ok • compile ${formatCompileDuration(compileDuration)} • ${compileTimestamp()}`
        : `${result.diagnostics.length} issue(s) • compile ${formatCompileDuration(compileDuration)} • ${compileTimestamp()}`;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const compileDuration = performance.now() - compileStartedAt;
    latestResult = {
      wgsl: "",
      vertex: null,
      fragment: null,
      compute: null,
      diagnostics: [{ message, line: 0, column: 0, severity: 1 }],
    };
    latestWgsl = "";
    latestDiagnostics = `// compile failed\n// ${message}`;
    activeOutputTab = "diagnostics";
    renderOutputPanel(latestResult);
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
  if (!isLoadingSample) {
    sampleSelect.value = "custom";
    updateSampleUrl(null);
  }
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

for (const button of outputTabButtons) {
  button.addEventListener("click", () => {
    activeOutputTab = button.dataset.outputTab as OutputTab;
    if (latestResult) renderOutputPanel(latestResult);
  });
}

sampleSelect.addEventListener("change", () => {
  if (sampleSelect.value === "custom") {
    updateSampleUrl(null);
    return;
  }

  const example = exampleSources.find((entry) => entry.id === sampleSelect.value);
  if (!example) return;

  isLoadingSample = true;
  editor.setValue(example.source);
  isLoadingSample = false;
  updateSampleUrl(example.id);

  window.clearTimeout(compileTimer);
  requestCompile("sample");
});

updateActionButtons();
requestCompile("initial");
await compileLoop;
