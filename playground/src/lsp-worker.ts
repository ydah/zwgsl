import { createCompiler } from "./compiler";

type WorkerRequest = {
  id: number;
  method: "diagnostics" | "hover" | "completion" | "definition";
  source: string;
  line?: number;
  character?: number;
};

type SymbolInfo = {
  name: string;
  detail: string;
  line: number;
  column: number;
  kind: number;
};

type CompletionItem = {
  label: string;
  kind: number;
  detail: string;
};

type DefinitionResult = {
  line: number;
  column: number;
  length: number;
} | null;

const compilerPromise = createCompiler();

const keywordDocs = new Map([
  ["def", { detail: "Define a function", documentation: "Defines a function with an implicit return from the final expression." }],
  ["let", { detail: "Immutable binding", documentation: "Creates an immutable local binding." }],
  ["match", { detail: "Pattern match", documentation: "Matches values against variants, literals, and wildcards." }],
  ["where", { detail: "Function-local bindings", documentation: "Attaches local bindings that remain visible across the function body." }],
  ["type", { detail: "Algebraic data type", documentation: "Defines tagged unions with constructor variants." }],
]);

const builtinDocs = new Map([
  ["normalize", { detail: "fn normalize(v: Vec(N)) -> Vec(N)", documentation: "Returns a normalized vector." }],
  ["length", { detail: "fn length(v: Vec(N) | Sca) -> Float", documentation: "Returns the magnitude." }],
  ["dot", { detail: "fn dot(a: Vec(N), b: Vec(N)) -> Float", documentation: "Computes a dot product." }],
  ["cross", { detail: "fn cross(a: Vec(3), b: Vec(3)) -> Vec(3)", documentation: "Computes a 3D cross product." }],
  ["mix", { detail: "fn mix(a: T, b: T, t: T | Sca) -> T", documentation: "Interpolates between two values." }],
]);

const builtinTypes = [
  "Float",
  "Int",
  "UInt",
  "Bool",
  "Vec2",
  "Vec3",
  "Vec4",
  "Mat2",
  "Mat3",
  "Mat4",
  "Sampler2D",
  "SamplerCube",
  "Sampler3D",
];

const methodItems = [
  { label: "normalize", kind: 2, detail: "method" },
  { label: "length", kind: 2, detail: "method" },
  { label: "dot", kind: 2, detail: "method" },
  { label: "cross", kind: 2, detail: "method" },
  { label: "mix", kind: 2, detail: "method" },
  { label: "clamp", kind: 2, detail: "method" },
];

const blockSnippets: CompletionItem[] = [
  { label: "def", kind: 15, detail: "def name ... end" },
  { label: "match", kind: 15, detail: "match value ... when ... end" },
  { label: "trait", kind: 15, detail: "trait Name ... end" },
  { label: "impl", kind: 15, detail: "impl Trait for Type ... end" },
  { label: "where", kind: 15, detail: "where clause" },
];

const swizzles = [
  { label: "x", kind: 5, detail: "swizzle" },
  { label: "y", kind: 5, detail: "swizzle" },
  { label: "z", kind: 5, detail: "swizzle" },
  { label: "w", kind: 5, detail: "swizzle" },
  { label: "xy", kind: 5, detail: "swizzle" },
  { label: "xyz", kind: 5, detail: "swizzle" },
  { label: "rgba", kind: 5, detail: "swizzle" },
];

const findDefinitions = (source: string): SymbolInfo[] => {
  const definitions: SymbolInfo[] = [];
  const lines = source.split(/\r?\n/);

  lines.forEach((line, index) => {
    const typeMatch = line.match(/^\s*(?:type|struct|trait)\s+([A-Z][A-Za-z0-9_]*)/);
    if (typeMatch) {
      definitions.push({
        name: typeMatch[1],
        detail: line.trim(),
        line: index,
        column: line.indexOf(typeMatch[1]) + 1,
        kind: 7,
      });
    }

    const functionMatch = line.match(/^\s*def\s+([A-Za-z_]\w*)/);
    if (functionMatch) {
      definitions.push({
        name: functionMatch[1],
        detail: line.trim(),
        line: index,
        column: line.indexOf(functionMatch[1]) + 1,
        kind: 3,
      });
    }

    const implMatch = line.match(/^\s*impl\s+([A-Z][A-Za-z0-9_]*)\s+for\s+([A-Z][A-Za-z0-9_]*(?:\([^)]*\))?)/);
    if (implMatch) {
      definitions.push({
        name: `${implMatch[1]}::${implMatch[2]}`,
        detail: line.trim(),
        line: index,
        column: line.indexOf(implMatch[1]) + 1,
        kind: 8,
      });
    }

    const variableMatch = line.match(/^\s*(?:let\s+)?([A-Za-z_]\w*)\s*(?::\s*([A-Za-z_]\w*(?:\([^)]*\))?))?\s*=/);
    if (variableMatch) {
      definitions.push({
        name: variableMatch[1],
        detail: variableMatch[2] ? `${variableMatch[1]}: ${variableMatch[2]}` : `${variableMatch[1]}: inferred`,
        line: index,
        column: line.indexOf(variableMatch[1]) + 1,
        kind: 6,
      });
    }

    const stageMatch = line.match(/^\s*(uniform|input|output|varying)\s+:([A-Za-z_]\w*)\s*,\s*([A-Za-z_]\w*(?:\([^)]*\))?)/);
    if (stageMatch) {
      definitions.push({
        name: stageMatch[2],
        detail: `${stageMatch[2]}: ${stageMatch[3]}`,
        line: index,
        column: line.indexOf(stageMatch[2]) + 1,
        kind: 6,
      });
    }
  });

  return definitions;
};

const wordAt = (source: string, line: number, character: number) => {
  const text = source.split(/\r?\n/)[line];
  if (!text) return null;
  const safeIndex = Math.max(0, Math.min(character, text.length - 1));
  let start = safeIndex;
  while (start > 0 && /[A-Za-z0-9_]/.test(text[start - 1])) start -= 1;
  let end = safeIndex;
  while (end < text.length && /[A-Za-z0-9_]/.test(text[end])) end += 1;
  if (start === end) return null;
  return text.slice(start, end);
};

const memberCompletion = (source: string, line: number, character: number) => {
  const text = source.split(/\r?\n/)[line] ?? "";
  const prefix = text.slice(0, character);
  if (!/\.\w*$/.test(prefix) && !/\.$/.test(prefix)) return null;
  return [...swizzles, ...methodItems];
};

const findDefinition = (source: string, line: number, character: number): DefinitionResult => {
  const word = wordAt(source, line, character);
  if (!word) return null;

  const definition = [...findDefinitions(source)].reverse().find((item) => item.name === word);
  if (!definition) return null;

  return {
    line: definition.line,
    column: definition.column,
    length: definition.name.length,
  };
};

self.addEventListener("message", async (event: MessageEvent<WorkerRequest>) => {
  const compiler = await compilerPromise;
  const { id, method, source, line = 0, character = 0 } = event.data;

  if (method === "diagnostics") {
    const result = await compiler.compile(source);
    self.postMessage({ id, result: result.diagnostics });
    return;
  }

  if (method === "hover") {
    const word = wordAt(source, line, character);
    if (!word) {
      self.postMessage({ id, result: null });
      return;
    }

    const keyword = keywordDocs.get(word);
    if (keyword) {
      self.postMessage({ id, result: keyword });
      return;
    }

    const builtin = builtinDocs.get(word);
    if (builtin) {
      self.postMessage({ id, result: builtin });
      return;
    }

    const definitions = findDefinitions(source);
    const definition = [...definitions].reverse().find((item) => item.name === word);
    self.postMessage({
      id,
      result: definition ? { detail: definition.detail, documentation: "source definition" } : null,
    });
    return;
  }

  if (method === "completion") {
    const memberItems = memberCompletion(source, line, character);
    if (memberItems) {
      self.postMessage({ id, result: memberItems });
      return;
    }

    const definitions = findDefinitions(source);
    const result = [
      ...definitions.map((item) => ({ label: item.name, kind: item.kind, detail: item.detail })),
      ...blockSnippets,
      ...[...keywordDocs.entries()].map(([label, info]) => ({ label, kind: 14, detail: info.detail })),
      ...[...builtinDocs.entries()].map(([label, info]) => ({ label, kind: 3, detail: info.detail })),
      ...builtinTypes.map((label) => ({ label, kind: 7, detail: "type" })),
    ];
    self.postMessage({ id, result });
    return;
  }

  if (method === "definition") {
    self.postMessage({ id, result: findDefinition(source, line, character) });
  }
});

export {};
