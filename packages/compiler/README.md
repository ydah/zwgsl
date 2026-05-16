# @zwgsl/compiler

This package directory is a staging area for an npm distribution of the wasm
compiler. It is intentionally kept separate from the playground app so release
automation can publish the compiler without shipping Monaco or preview UI code.

Expected package contents after a release build:

- `dist/index.js`: a small JavaScript loader around `zwgsl.wasm`
- `dist/index.d.ts`: TypeScript declarations for compile and tooling requests
- `dist/zwgsl.wasm`: the compiler artifact from `zig build wasm`

The package is not published by this repository alone. Publishing requires npm
credentials and a release workflow step that copies the wasm artifact into this
directory, builds the loader, and runs `npm publish`.
