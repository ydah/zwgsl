import {
  createCompiler,
  type CompletionResult as CompilerCompletionResult,
  type DefinitionResult as CompilerDefinitionResult,
  type HoverResult as CompilerHoverResult,
} from "./compiler";

type WorkerRequest = {
  id: number;
  method: "diagnostics" | "hover" | "completion" | "definition";
  source: string;
  line?: number;
  character?: number;
};

type HoverResult =
  | {
      detail: string;
      documentation?: string;
    }
  | null;

type CompletionItem = {
  label: string;
  kind: number;
  detail?: string;
};

type DefinitionResult =
  | {
      line: number;
      column: number;
      length: number;
    }
  | null;

const compilerPromise = createCompiler();

self.addEventListener("message", async (event: MessageEvent<WorkerRequest>) => {
  const compiler = await compilerPromise;
  const { id, method, source, line = 0, character = 0 } = event.data;

  if (method === "diagnostics") {
    const result = await compiler.compile(source);
    self.postMessage({ id, result: result.diagnostics });
    return;
  }

  if (method === "hover") {
    const result = await compiler.hover(source, line, character);
    self.postMessage({ id, result: decodeHover(result) });
    return;
  }

  if (method === "completion") {
    const result = await compiler.completion(source, line, character);
    self.postMessage({ id, result: decodeCompletion(result) });
    return;
  }

  if (method === "definition") {
    const result = await compiler.definition(source, line, character);
    self.postMessage({ id, result: decodeDefinition(result) });
  }
});

const decodeHover = (result: CompilerHoverResult): HoverResult => {
  const markdown = result?.contents?.value;
  if (!markdown) return null;

  const match = markdown.match(/^```zwgsl\n([\s\S]*?)\n```(?:\n\n([\s\S]*))?$/);
  if (!match) {
    return { detail: markdown };
  }

  return {
    detail: match[1],
    documentation: match[2],
  };
};

const decodeCompletion = (result: CompilerCompletionResult): CompletionItem[] =>
  result.map((item) => ({
    label: item.label,
    kind: item.kind,
    detail: item.detail,
  }));

const decodeDefinition = (result: CompilerDefinitionResult): DefinitionResult => {
  const location = result[0];
  if (!location) return null;

  return {
    line: location.range.start.line,
    column: location.range.start.character + 1,
    length: Math.max(1, location.range.end.character - location.range.start.character),
  };
};

export {};
