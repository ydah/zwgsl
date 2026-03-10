export type CompileResult = {
  wgsl: string;
  diagnostics: Array<{ message: string }>;
};

type WasmExports = {
  memory?: WebAssembly.Memory;
};

export const createCompiler = async () => {
  let exports: WasmExports | null = null;

  try {
    const response = await fetch("/zwgsl.wasm");
    if (response.ok) {
      const wasm = await WebAssembly.instantiateStreaming(response, {});
      exports = wasm.instance.exports as WasmExports;
    }
  } catch {
    exports = null;
  }

  return {
    async compile(source: string): Promise<CompileResult> {
      if (!exports?.memory) {
        return {
          wgsl: `// wasm compiler not loaded yet\n// source size: ${source.length}\n`,
          diagnostics: [],
        };
      }

      return {
        wgsl: `// zwgsl wasm bridge is connected\n// source size: ${source.length}\n`,
        diagnostics: [],
      };
    },
  };
};
