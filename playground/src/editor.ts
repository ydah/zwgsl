import * as monaco from "monaco-editor";
import { registerLanguage } from "./language";

type Diagnostic = {
  message: string;
  line: number;
  column: number;
  severity: number;
};

type HoverResult = {
  detail: string;
  documentation?: string;
} | null;

type CompletionResult = Array<{
  label: string;
  kind: number;
  detail?: string;
}>;

type DefinitionResult = {
  line: number;
  column: number;
  length: number;
} | null;

export const createEditor = async (element: HTMLElement, value: string) => {
  registerLanguage(monaco);
  const worker = new Worker(new URL("./lsp-worker.ts", import.meta.url), { type: "module" });
  let nextId = 1;
  const pending = new Map<number, (result: unknown) => void>();

  const editor = monaco.editor.create(element, {
    value,
    language: "zwgsl",
    automaticLayout: true,
    minimap: { enabled: false },
    fontFamily: "IBM Plex Mono, ui-monospace, monospace",
    fontSize: 14,
    theme: "vs-dark",
    smoothScrolling: true,
    padding: { top: 20, bottom: 20 },
  });

  const model = editor.getModel();
  if (!model) return editor;

  worker.addEventListener("message", (event: MessageEvent<{ id: number; result: unknown }>) => {
    const resolve = pending.get(event.data.id);
    if (!resolve) return;
    pending.delete(event.data.id);
    resolve(event.data.result);
  });

  const request = <T>(method: string, payload: Record<string, unknown>) =>
    new Promise<T>((resolve) => {
      const id = nextId++;
      pending.set(id, (result) => resolve(result as T));
      worker.postMessage({ id, method, ...payload });
    });

  const pushDiagnostics = async () => {
    const diagnostics = await request<Diagnostic[]>("diagnostics", { source: model.getValue() });

    monaco.editor.setModelMarkers(
      model,
      "zwgsl",
      diagnostics.map((diagnostic) => ({
        message: diagnostic.message,
        severity:
          diagnostic.severity === 1
            ? monaco.MarkerSeverity.Error
            : monaco.MarkerSeverity.Warning,
        startLineNumber: Math.max(1, diagnostic.line || 1),
        startColumn: Math.max(1, diagnostic.column || 1),
        endLineNumber: Math.max(1, diagnostic.line || 1),
        endColumn: Math.max(1, (diagnostic.column || 1) + 1),
      })),
    );
  };

  let diagnosticsTimer = window.setTimeout(() => undefined, 0);
  model.onDidChangeContent(() => {
    window.clearTimeout(diagnosticsTimer);
    diagnosticsTimer = window.setTimeout(() => void pushDiagnostics(), 150);
  });

  monaco.languages.registerHoverProvider("zwgsl", {
    async provideHover(activeModel, position) {
      const result = await request<HoverResult>("hover", {
        source: activeModel.getValue(),
        line: position.lineNumber - 1,
        character: position.column - 1,
      });
      if (!result) return null;
      return {
        contents: [
          { value: `\`\`\`zwgsl\n${result.detail}\n\`\`\`` },
          ...(result.documentation ? [{ value: result.documentation }] : []),
        ],
      };
    },
  });

  monaco.languages.registerCompletionItemProvider("zwgsl", {
    triggerCharacters: [".", ":"],
    async provideCompletionItems(activeModel, position) {
      const items = await request<CompletionResult>("completion", {
        source: activeModel.getValue(),
        line: position.lineNumber - 1,
        character: position.column - 1,
      });

      return {
        suggestions: items.map((item) => ({
          label: item.label,
          kind: item.kind,
          detail: item.detail,
          insertText: item.label,
          range: undefined,
        })),
      };
    },
  });

  monaco.languages.registerDefinitionProvider("zwgsl", {
    async provideDefinition(activeModel, position) {
      const result = await request<DefinitionResult>("definition", {
        source: activeModel.getValue(),
        line: position.lineNumber - 1,
        character: position.column - 1,
      });

      if (!result) return null;

      return {
        uri: activeModel.uri,
        range: new monaco.Range(
          Math.max(1, result.line + 1),
          Math.max(1, result.column),
          Math.max(1, result.line + 1),
          Math.max(1, result.column + result.length),
        ),
      };
    },
  });

  await pushDiagnostics();
  return editor;
};
