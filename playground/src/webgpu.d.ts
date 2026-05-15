interface HTMLCanvasElement {
  getContext(contextId: "webgpu", options?: unknown): GPUCanvasContext | null;
}

declare const GPUBufferUsage: {
  readonly COPY_DST: GPUFlagsConstant;
  readonly UNIFORM: GPUFlagsConstant;
  readonly VERTEX: GPUFlagsConstant;
};

declare const GPUTextureUsage: {
  readonly COPY_DST: GPUFlagsConstant;
  readonly TEXTURE_BINDING: GPUFlagsConstant;
};
