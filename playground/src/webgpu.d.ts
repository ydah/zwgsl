interface HTMLCanvasElement {
  getContext(contextId: "webgpu", options?: unknown): GPUCanvasContext | null;
}

declare const GPUBufferUsage: {
  readonly COPY_DST: GPUFlagsConstant;
  readonly COPY_SRC: GPUFlagsConstant;
  readonly MAP_READ: GPUFlagsConstant;
  readonly STORAGE: GPUFlagsConstant;
  readonly UNIFORM: GPUFlagsConstant;
  readonly VERTEX: GPUFlagsConstant;
};

declare const GPUMapMode: {
  readonly READ: GPUFlagsConstant;
};

declare const GPUTextureUsage: {
  readonly COPY_DST: GPUFlagsConstant;
  readonly TEXTURE_BINDING: GPUFlagsConstant;
};
