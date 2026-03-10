export type CompileResult = {
  wgsl: string;
  vertex: string | null;
  fragment: string | null;
  compute: string | null;
  diagnostics: Array<{
    message: string;
    line: number;
    column: number;
    severity: number;
  }>;
};

type WasmExports = {
  memory: WebAssembly.Memory;
  zwgsl_wasm_alloc(size: number): number;
  zwgsl_wasm_free(ptr: number, size: number): void;
  zwgsl_wasm_compile(ptr: number, size: number): number;
  zwgsl_wasm_result_free(ptr: number): void;
};

let compilerPromise: Promise<ReturnType<typeof createLoadedCompiler>> | null = null;

export const createCompiler = async () => {
  compilerPromise ??= createLoadedCompiler();
  return compilerPromise;
};

const createLoadedCompiler = async () => {
  const exports = await loadWasmExports();
  if (!exports) {
    return {
      async compile(source: string): Promise<CompileResult> {
        return {
          wgsl: `// zwgsl.wasm is not available\n// source size: ${source.length}\n`,
          vertex: null,
          fragment: null,
          compute: null,
          diagnostics: [
            {
              message: "zwgsl.wasm is missing. Run `npm run sync-wasm` first.",
              line: 0,
              column: 0,
              severity: 1,
            },
          ],
        };
      },
    };
  }

  return {
    async compile(source: string): Promise<CompileResult> {
      const bytes = new TextEncoder().encode(source);
      const sourcePtr = exports.zwgsl_wasm_alloc(bytes.byteLength);
      if (!sourcePtr) {
        return fallbackResult("failed to allocate wasm input buffer");
      }

      try {
        new Uint8Array(exports.memory.buffer, sourcePtr, bytes.byteLength).set(bytes);
        const resultPtr = exports.zwgsl_wasm_compile(sourcePtr, bytes.byteLength);
        if (!resultPtr) {
          return fallbackResult("wasm compiler returned a null result");
        }

        try {
          const view = new DataView(exports.memory.buffer);
          const vertex = readOptionalString(exports.memory, view.getUint32(resultPtr, true), view.getUint32(resultPtr + 4, true));
          const fragment = readOptionalString(exports.memory, view.getUint32(resultPtr + 8, true), view.getUint32(resultPtr + 12, true));
          const compute = readOptionalString(exports.memory, view.getUint32(resultPtr + 16, true), view.getUint32(resultPtr + 20, true));
          const diagnosticsPtr = view.getUint32(resultPtr + 24, true);
          const diagnosticsLen = view.getUint32(resultPtr + 28, true);
          const diagnostics = readDiagnostics(exports.memory, diagnosticsPtr, diagnosticsLen);

          return {
            wgsl: [vertex, fragment, compute]
              .filter((part): part is string => Boolean(part))
              .map((part, index) => {
                const stage = index === 0 ? "vertex" : index === 1 ? "fragment" : "compute";
                return `// ${stage}\n${part}`;
              })
              .join("\n\n"),
            vertex,
            fragment,
            compute,
            diagnostics,
          };
        } finally {
          exports.zwgsl_wasm_result_free(resultPtr);
        }
      } finally {
        exports.zwgsl_wasm_free(sourcePtr, bytes.byteLength);
      }
    },
  };
};

const loadWasmExports = async (): Promise<WasmExports | null> => {
  try {
    const response = await fetch("/zwgsl.wasm");
    if (!response.ok) return null;

    try {
      const wasm = await WebAssembly.instantiateStreaming(response, {});
      return wasm.instance.exports as WasmExports;
    } catch {
      const fallbackResponse = await fetch("/zwgsl.wasm");
      if (!fallbackResponse.ok) return null;
      const bytes = await fallbackResponse.arrayBuffer();
      const wasm = await WebAssembly.instantiate(bytes, {});
      return wasm.instance.exports as WasmExports;
    }
  } catch {
    return null;
  }
};

const readOptionalString = (memory: WebAssembly.Memory, ptr: number, len: number) => {
  if (!ptr || !len) return null;
  const bytes = new Uint8Array(memory.buffer, ptr, len);
  return new TextDecoder().decode(bytes);
};

const readDiagnostics = (memory: WebAssembly.Memory, ptr: number, len: number) => {
  if (!ptr || !len) return [];
  const diagnostics = [];
  const view = new DataView(memory.buffer);

  for (let index = 0; index < len; index += 1) {
    const offset = ptr + index * 20;
    const messagePtr = view.getUint32(offset, true);
    const messageLen = view.getUint32(offset + 4, true);
    diagnostics.push({
      message: readOptionalString(memory, messagePtr, messageLen) ?? "unknown error",
      line: view.getUint32(offset + 8, true),
      column: view.getUint32(offset + 12, true),
      severity: view.getUint32(offset + 16, true),
    });
  }

  return diagnostics;
};

const fallbackResult = (message: string): CompileResult => ({
  wgsl: `// ${message}\n`,
  vertex: null,
  fragment: null,
  compute: null,
  diagnostics: [{ message, line: 0, column: 0, severity: 1 }],
});
