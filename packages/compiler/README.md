# @zwgsl/compiler

This package is the npm distribution surface for the wasm compiler. It is kept
separate from the playground app so release automation can publish the compiler
without shipping Monaco or preview UI code.

Expected package contents after a release build:

- `dist/index.js`: JavaScript loader around `zwgsl.wasm`
- `dist/index.d.ts`: TypeScript declarations for compile and tooling requests
- `dist/zwgsl.wasm`: the compiler artifact from `zig build wasm`

## Usage

```js
import { createCompiler } from "@zwgsl/compiler";

const compiler = await createCompiler();
const result = compiler.compile(`
fragment do
  output :frag_color, Vec4, location: 0

  def main
    frag_color = vec4(1.0, 0.4, 0.2, 1.0)
  end
end
`);

console.log(result.wgsl);
```

By default the loader resolves `dist/zwgsl.wasm` next to `dist/index.js`. Tools
that manage assets themselves can pass `{ wasmUrl }` or `{ wasmBytes }` to
`createCompiler()`.

The package is not published by this repository alone. Publishing requires npm
credentials and a release workflow step that copies the wasm artifact into this
directory and runs `npm publish`.
