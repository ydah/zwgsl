import "./styles.css";

import { createEditor } from "./editor";
import { createCompiler, type CompileResult } from "./compiler";
import { defaultExample, exampleSources, type ExampleSource } from "./examples";
import { createPreview } from "./preview";
import { hasResourceLayout, renderResourceLayout } from "./resource-layout";

const status = document.querySelector<HTMLSpanElement>("#status")!;
const output = document.querySelector<HTMLElement>("#wgsl-output")!;
const button = document.querySelector<HTMLButtonElement>("#compile-button")!;
const canvas = document.querySelector<HTMLCanvasElement>("#preview-canvas")!;
const previewStatus = document.querySelector<HTMLSpanElement>("#preview-status")!;
const uniformControls = document.querySelector<HTMLElement>("#uniform-controls")!;
const sampleSelect = document.querySelector<HTMLSelectElement>("#sample-select")!;
const copyWgslButton = document.querySelector<HTMLButtonElement>("#copy-wgsl-button")!;
const copyDiagnosticsButton = document.querySelector<HTMLButtonElement>("#copy-diagnostics-button")!;
const shareSourceButton = document.querySelector<HTMLButtonElement>("#share-source-button")!;
const downloadSourceButton = document.querySelector<HTMLButtonElement>("#download-source-button")!;
const downloadWgslButton = document.querySelector<HTMLButtonElement>("#download-wgsl-button")!;
const exampleGallery = document.querySelector<HTMLElement>("#example-gallery")!;
const tutorialSteps = document.querySelector<HTMLElement>("#tutorial-steps")!;
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
const sourceQueryKey = "source";
const tutorialSampleIds = [
  "hello-triangle",
  "animated-uniforms",
  "phong",
  "postprocess",
  "adt-match",
] as const;

const sampleIdFromLocation = () => new URLSearchParams(window.location.search).get(sampleQueryKey);
const sourceParamFromLocation = () => new URLSearchParams(window.location.search).get(sourceQueryKey);

const findSample = (sampleId: string | null) =>
  sampleId ? exampleSources.find((entry) => entry.id === sampleId) : null;

const updateSampleUrl = (sampleId: string | null) => {
  const url = new URL(window.location.href);
  if (sampleId) {
    url.searchParams.set(sampleQueryKey, sampleId);
  } else {
    url.searchParams.delete(sampleQueryKey);
  }
  url.searchParams.delete(sourceQueryKey);
  window.history.replaceState(null, "", `${url.pathname}${url.search}${url.hash}`);
};

const decodeSharedSource = (value: string) => {
  try {
    const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized.padEnd(normalized.length + ((4 - normalized.length % 4) % 4), "=");
    const binary = window.atob(padded);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    return new TextDecoder().decode(bytes);
  } catch {
    return null;
  }
};

const encodeSharedSource = (source: string) => {
  const bytes = new TextEncoder().encode(source);
  let binary = "";
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });
  return window.btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
};

const shareUrlForSource = (source: string) => {
  const url = new URL(window.location.href);
  url.searchParams.delete(sampleQueryKey);
  url.searchParams.set(sourceQueryKey, encodeSharedSource(source));
  return url;
};

const customOption = new Option("Custom", "custom");
sampleSelect.append(customOption);

for (const example of exampleSources) {
  sampleSelect.append(new Option(example.label, example.id));
}

const initialSourceParam = sourceParamFromLocation();
const initialSharedSource =
  initialSourceParam === null ? null : decodeSharedSource(initialSourceParam);
const initialSampleId = sampleIdFromLocation();
const initialSample = findSample(initialSampleId);

if (initialSharedSource !== null) {
  editor.setValue(initialSharedSource);
  sampleSelect.value = "custom";
} else if (initialSample) {
  editor.setValue(initialSample.source);
  sampleSelect.value = initialSample.id;
  if (initialSourceParam !== null) updateSampleUrl(initialSample.id);
} else {
  sampleSelect.value = defaultExample.id;
  if (initialSampleId || initialSourceParam !== null) updateSampleUrl(null);
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
      return hasResourceLayout(result);
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

const updateSampleButtons = () => {
  const selected = selectedSampleId();
  for (const button of document.querySelectorAll<HTMLButtonElement>("[data-sample-id]")) {
    button.setAttribute("aria-pressed", button.dataset.sampleId === selected ? "true" : "false");
  }
};

const loadExample = (example: ExampleSource, trigger: CompileTrigger) => {
  isLoadingSample = true;
  editor.setValue(example.source);
  isLoadingSample = false;
  sampleSelect.value = example.id;
  updateSampleUrl(example.id);
  updateSampleButtons();

  window.clearTimeout(compileTimer);
  requestCompile(trigger);
};

const renderExampleGallery = () => {
  const fragment = document.createDocumentFragment();

  for (const example of exampleSources) {
    const card = document.createElement("button");
    card.className = "example-card";
    card.type = "button";
    card.dataset.sampleId = example.id;

    const title = document.createElement("strong");
    title.textContent = example.label;
    const summary = document.createElement("span");
    summary.textContent = example.summary;
    const tags = document.createElement("small");
    tags.textContent = example.tags.join(" / ");

    card.append(title, summary, tags);
    card.addEventListener("click", () => loadExample(example, "sample"));
    fragment.append(card);
  }

  exampleGallery.replaceChildren(fragment);
};

const renderTutorialSteps = () => {
  const fragment = document.createDocumentFragment();

  for (const [index, sampleId] of tutorialSampleIds.entries()) {
    const example = findSample(sampleId);
    if (!example) continue;

    const step = document.createElement("button");
    step.className = "tutorial-step";
    step.type = "button";
    step.dataset.sampleId = example.id;

    const number = document.createElement("span");
    number.textContent = String(index + 1).padStart(2, "0");
    const label = document.createElement("strong");
    label.textContent = example.label;
    const summary = document.createElement("small");
    summary.textContent = example.summary;

    step.append(number, label, summary);
    step.addEventListener("click", () => loadExample(example, "sample"));
    fragment.append(step);
  }

  tutorialSteps.replaceChildren(fragment);
};

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
    updateSampleButtons();
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

shareSourceButton.addEventListener("click", async () => {
  const url = shareUrlForSource(editor.getValue());
  window.history.replaceState(null, "", `${url.pathname}${url.search}${url.hash}`);
  sampleSelect.value = "custom";
  updateSampleButtons();
  await copyText(url.toString());
  flashButtonLabel(shareSourceButton, "Copied");
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
    updateSampleButtons();
    return;
  }

  const example = exampleSources.find((entry) => entry.id === sampleSelect.value);
  if (!example) return;
  loadExample(example, "sample");
});

renderExampleGallery();
renderTutorialSteps();
updateActionButtons();
updateSampleButtons();
requestCompile("initial");
await compileLoop;
