const defaultWasmUrl = new URL("./zwgsl.wasm", import.meta.url);

const requiredExports = [
  "memory",
  "zwgsl_wasm_alloc",
  "zwgsl_wasm_free",
  "zwgsl_wasm_compile",
  "zwgsl_wasm_result_free",
];

const jsonRequests = {
  hover: "zwgsl_wasm_hover",
  completion: "zwgsl_wasm_completion",
  definition: "zwgsl_wasm_definition",
  signatureHelp: "zwgsl_wasm_signature_help",
};

export const createCompiler = async (options = {}) => {
  const instance = await instantiateWasm(options);
  const exports = assertWasmExports(instance.exports);

  return {
    compile(source) {
      return compileSource(exports, source);
    },
    hover(source, line, character) {
      return invokeJsonRequest(exports, jsonRequests.hover, source, line, character, null);
    },
    completion(source, line, character) {
      return invokeJsonRequest(exports, jsonRequests.completion, source, line, character, []);
    },
    signatureHelp(source, line, character) {
      return invokeJsonRequest(exports, jsonRequests.signatureHelp, source, line, character, null);
    },
    definition(source, line, character) {
      return invokeJsonRequest(exports, jsonRequests.definition, source, line, character, []);
    },
  };
};

export default createCompiler;

const instantiateWasm = async (options) => {
  const imports = options.imports ?? {};
  if (options.wasmBytes !== undefined) {
    return instantiateBytes(await options.wasmBytes, imports);
  }

  const source = options.wasmUrl ?? defaultWasmUrl;
  return instantiateUrl(source, imports, options.fetch ?? globalThis.fetch);
};

const instantiateUrl = async (source, imports, fetchImpl) => {
  const fileBytes = await tryReadFileUrl(source);
  if (fileBytes) return instantiateBytes(fileBytes, imports);

  if (typeof fetchImpl !== "function") {
    throw new Error("No fetch implementation is available for loading zwgsl.wasm.");
  }

  const response = await fetchImpl(source);
  if (!response.ok) {
    throw new Error(`Failed to load zwgsl.wasm: HTTP ${response.status}`);
  }

  if (typeof WebAssembly.instantiateStreaming === "function") {
    try {
      const result = await WebAssembly.instantiateStreaming(response.clone(), imports);
      return result.instance;
    } catch {
      // Some servers do not serve wasm with application/wasm.
    }
  }

  return instantiateBytes(await response.arrayBuffer(), imports);
};

const instantiateBytes = async (bytes, imports) => {
  const result = await WebAssembly.instantiate(asArrayBuffer(bytes), imports);
  return result.instance;
};

const tryReadFileUrl = async (source) => {
  const url = urlFromSource(source);
  if (url?.protocol !== "file:") return null;

  try {
    const { readFile } = await import("node:fs/promises");
    return readFile(url);
  } catch {
    return null;
  }
};

const urlFromSource = (source) => {
  try {
    if (source instanceof URL) return source;
    if (typeof source === "string") return new URL(source);
    if (source && typeof source.url === "string") return new URL(source.url);
  } catch {
    return null;
  }
  return null;
};

const asArrayBuffer = (bytes) => {
  if (bytes instanceof ArrayBuffer) return bytes;
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
};

const assertWasmExports = (exports) => {
  for (const name of requiredExports) {
    if (exports[name] === undefined) {
      throw new Error(`zwgsl.wasm is missing required export: ${name}`);
    }
  }
  return exports;
};

const stageSources = (result) =>
  [
    ["vertex", result.vertex],
    ["fragment", result.fragment],
    ["compute", result.compute],
  ];

const compileSource = (exports, source) => {
  const input = writeInput(exports, source);
  if (!input) return fallbackResult("failed to allocate wasm input buffer");

  try {
    const resultPtr = exports.zwgsl_wasm_compile(input.ptr, input.length);
    if (!resultPtr) return fallbackResult("wasm compiler returned a null result");

    try {
      const view = new DataView(exports.memory.buffer);
      const vertex = readOptionalString(
        exports.memory,
        view.getUint32(resultPtr, true),
        view.getUint32(resultPtr + 4, true),
      );
      const fragment = readOptionalString(
        exports.memory,
        view.getUint32(resultPtr + 8, true),
        view.getUint32(resultPtr + 12, true),
      );
      const compute = readOptionalString(
        exports.memory,
        view.getUint32(resultPtr + 16, true),
        view.getUint32(resultPtr + 20, true),
      );
      const diagnosticsPtr = view.getUint32(resultPtr + 24, true);
      const diagnosticsLen = view.getUint32(resultPtr + 28, true);
      const diagnostics = readDiagnostics(exports.memory, diagnosticsPtr, diagnosticsLen);

      return {
        wgsl: stageSources({ vertex, fragment, compute })
          .map(([stage, part]) => part === null ? null : `// ${stage}\n${part}`)
          .filter((part) => part !== null)
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
    exports.zwgsl_wasm_free(input.ptr, input.allocationSize);
  }
};

const writeInput = (exports, source) => {
  const bytes = new TextEncoder().encode(source);
  const allocationSize = Math.max(bytes.byteLength, 1);
  const ptr = exports.zwgsl_wasm_alloc(allocationSize);
  if (!ptr) return null;
  new Uint8Array(exports.memory.buffer, ptr, bytes.byteLength).set(bytes);
  return {
    ptr,
    length: bytes.byteLength,
    allocationSize,
  };
};

const readOptionalString = (memory, ptr, len) => {
  if (!ptr || !len) return null;
  return new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
};

const readDiagnostics = (memory, ptr, len) => {
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

const invokeJsonRequest = (exports, request, source, line, character, fallback) => {
  if (typeof exports[request] !== "function" || typeof exports.zwgsl_wasm_json_result_free !== "function") {
    return fallback;
  }

  const input = writeInput(exports, source);
  if (!input) return fallback;

  try {
    const resultPtr = exports[request](input.ptr, input.length, line, character);
    if (!resultPtr) return fallback;

    try {
      const view = new DataView(exports.memory.buffer);
      const json = readOptionalString(
        exports.memory,
        view.getUint32(resultPtr, true),
        view.getUint32(resultPtr + 4, true),
      );
      if (!json) return fallback;
      return JSON.parse(json);
    } catch {
      return fallback;
    } finally {
      exports.zwgsl_wasm_json_result_free(resultPtr);
    }
  } finally {
    exports.zwgsl_wasm_free(input.ptr, input.allocationSize);
  }
};

const fallbackResult = (message) => ({
  wgsl: `// ${message}\n`,
  vertex: null,
  fragment: null,
  compute: null,
  diagnostics: [{ message, line: 0, column: 0, severity: 1 }],
});
