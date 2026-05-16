import * as monaco from "monaco-editor";
import { registerLanguage } from "./language";

type Diagnostic = {
  message: string;
  line: number;
  column: number;
  severity: number;
};

type LearningAnnotation = {
  line: number;
  message: string;
};

export type PlaygroundEditor = monaco.editor.IStandaloneCodeEditor & {
  setCompilerDiagnostics(diagnostics: Diagnostic[]): void;
  setLearningAnnotations(annotations: LearningAnnotation[]): void;
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

type SignatureHelpResult = {
  signatures: Array<{
    label: string;
    documentation?: { kind?: string; value: string } | string;
    parameters?: Array<{ label: string }>;
  }>;
  activeSignature: number;
  activeParameter: number;
} | null;

type DefinitionResult = {
  line: number;
  column: number;
  length: number;
} | null;

export const createEditor = async (element: HTMLElement, value: string): Promise<PlaygroundEditor> => {
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
    glyphMargin: true,
    padding: { top: 20, bottom: 20 },
  });

  const model = editor.getModel();
  if (!model) return withPlaygroundMethods(editor, () => undefined, () => undefined);
  const learningDecorations = editor.createDecorationsCollection();

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

  const setDiagnostics = (owner: string, diagnostics: Diagnostic[]) => {
    monaco.editor.setModelMarkers(
      model,
      owner,
      diagnostics.map((diagnostic) => ({
        message: diagnostic.message,
        severity:
          diagnostic.severity === 1
            ? monaco.MarkerSeverity.Error
            : monaco.MarkerSeverity.Warning,
        startLineNumber: Math.max(1, diagnostic.line || 1),
        startColumn: Math.max(1, diagnostic.column || 1),
        endLineNumber: Math.max(1, diagnostic.line || 1),
        endColumn: markerEndColumn(diagnostic),
      })),
    );
  };

  const markerEndColumn = (diagnostic: Diagnostic) => {
    const line = Math.max(1, diagnostic.line || 1);
    const column = Math.max(1, diagnostic.column || 1);
    if (line > model.getLineCount()) return column + 1;
    return Math.min(model.getLineMaxColumn(line), column + 1);
  };

  const pushDiagnostics = async () => {
    const diagnostics = await request<Diagnostic[]>("diagnostics", { source: model.getValue() });
    setDiagnostics("zwgsl", diagnostics);
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
      const word = activeModel.getWordUntilPosition(position);
      const range = new monaco.Range(
        position.lineNumber,
        word.startColumn,
        position.lineNumber,
        word.endColumn,
      );
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
          range,
        })),
      };
    },
  });

  monaco.languages.registerSignatureHelpProvider("zwgsl", {
    signatureHelpTriggerCharacters: ["(", ","],
    async provideSignatureHelp(activeModel, position) {
      const result = await request<SignatureHelpResult>("signatureHelp", {
        source: activeModel.getValue(),
        line: position.lineNumber - 1,
        character: position.column - 1,
      });
      if (!result) return null;

      return {
        value: {
          signatures: result.signatures.map((signature) => ({
            label: signature.label,
            documentation: signature.documentation,
            parameters: signature.parameters ?? [],
          })),
          activeSignature: result.activeSignature,
          activeParameter: result.activeParameter,
        },
        dispose() {},
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
  return withPlaygroundMethods(
    editor,
    (diagnostics) => setDiagnostics("zwgsl-compile", diagnostics),
    (annotations) => {
      learningDecorations.set(
        annotations.map((annotation) => ({
          range: new monaco.Range(annotation.line, 1, annotation.line, 1),
          options: {
            isWholeLine: true,
            className: "learning-line-highlight",
            glyphMarginClassName: "learning-glyph",
            hoverMessage: { value: annotation.message },
            after: {
              content: `  ${annotation.message}`,
              inlineClassName: "learning-inline-hint",
            },
          },
        })),
      );
    },
  );
};

const withPlaygroundMethods = (
  editor: monaco.editor.IStandaloneCodeEditor,
  setCompilerDiagnostics: (diagnostics: Diagnostic[]) => void,
  setLearningAnnotations: (annotations: LearningAnnotation[]) => void,
): PlaygroundEditor =>
  Object.assign(editor, {
    setCompilerDiagnostics,
    setLearningAnnotations,
  });
