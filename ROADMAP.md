# Roadmap

This roadmap tracks likely project direction. It is not a release promise; the
feature matrix remains the source of truth for implemented behavior.

## Near Term

- Add more WGSL and GLSL snapshot fixtures for complete examples.
- Improve diagnostics with clearer expected/actual type context and backend
  source locations.
- Expose generated resource layout details in CLI and playground output.
- Keep release-facing versions consistent across C API, Zig package metadata,
  playground package metadata, and editor package metadata.

## Tooling

- Add formatter support that can be shared by `zwgsl fmt` and LSP formatting.
- Add LSP signature help for builtins, user functions, and trait methods.
- Add focused code actions for common fixes such as missing declarations and
  simple type annotations.
- Evaluate incremental document sync once the document store has range-edit
  coverage.

## Validation And Distribution

- Add generated WGSL validation once a stable validator dependency is chosen for
  CI and local development.
- Add release assets for CLI, LSP, C library/header, and wasm artifacts.
- Evaluate npm and Homebrew distribution after release artifacts are stable.

## Examples And Docs

- Expand the WGSL/GLSL migration guide with more before/after examples.
- Add more complete tutorials around uniforms, lighting, texture sampling, and
  PBR/postprocess workflows.
- Keep examples aligned with playground samples and golden output fixtures.
- Keep architecture notes aligned with compiler pipeline changes.

## Non-Goals

See [Design Notes](docs/design-notes.md#non-goals) for the current project
non-goals.
