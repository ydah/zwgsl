export type Diagnostic = {
  message: string;
  line: number;
  column: number;
  severity: number;
};

export type CompileResult = {
  wgsl: string;
  vertex: string | null;
  fragment: string | null;
  compute: string | null;
  diagnostics: Diagnostic[];
};

export type HoverResult =
  | {
      contents?: {
        kind?: string;
        value: string;
      };
    }
  | null;

export type CompletionResult = Array<{
  label: string;
  kind: number;
  detail?: string;
}>;

export type SignatureHelpResult = {
  signatures: Array<{
    label: string;
    documentation?: { kind?: string; value: string } | string;
    parameters?: Array<{ label: string }>;
  }>;
  activeSignature: number;
  activeParameter: number;
} | null;

export type DefinitionResult = Array<{
  uri: string;
  range: {
    start: { line: number; character: number };
    end: { line: number; character: number };
  };
}>;

export type CreateCompilerOptions = {
  wasmUrl?: string | URL | Request;
  wasmBytes?: BufferSource | Promise<BufferSource>;
  imports?: WebAssembly.Imports;
  fetch?: typeof globalThis.fetch;
};

export type Compiler = {
  compile(source: string): CompileResult;
  hover(source: string, line: number, character: number): HoverResult;
  completion(source: string, line: number, character: number): CompletionResult;
  signatureHelp(source: string, line: number, character: number): SignatureHelpResult;
  definition(source: string, line: number, character: number): DefinitionResult;
};

export declare const createCompiler: (options?: CreateCompilerOptions) => Promise<Compiler>;

export default createCompiler;
