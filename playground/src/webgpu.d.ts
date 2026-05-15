type GPUVertexFormat = string;
type GPUTextureFormat = string;
type GPUTextureViewDimension = string;
type GPUTextureDimension = string;

type GPUBindGroupEntry = {
  binding: number;
  resource: unknown;
};

type GPUVertexBufferLayout = {
  arrayStride: number;
  stepMode: string;
  attributes: Array<{
    shaderLocation: number;
    offset: number;
    format: GPUVertexFormat;
  }>;
};

type GPUCompilationMessage = {
  type: string;
  lineNum: number;
  linePos: number;
  message: string;
};

type GPUCompilationInfo = {
  messages: GPUCompilationMessage[];
};

interface GPUBuffer {
  destroy(): void;
}

interface GPUTexture {
  createView(descriptor?: { dimension?: GPUTextureViewDimension }): GPUTextureView;
  destroy(): void;
}

interface GPUTextureView {}

interface GPUSampler {}

interface GPUBindGroup {}

interface GPURenderPipeline {
  getBindGroupLayout(index: number): unknown;
}

interface GPUShaderModule {
  getCompilationInfo(): Promise<GPUCompilationInfo>;
}

interface GPUCanvasContext {
  configure(descriptor: {
    device: GPUDevice;
    format: GPUTextureFormat;
    alphaMode?: string;
  }): void;
  getCurrentTexture(): GPUTexture;
}

interface GPUAdapter {
  requestDevice(): Promise<GPUDevice>;
}

interface GPUQueue {
  writeBuffer(buffer: GPUBuffer, offset: number, data: BufferSource): void;
  writeTexture(destination: unknown, data: BufferSource, layout: unknown, size: unknown): void;
  submit(commandBuffers: unknown[]): void;
}

interface GPUDevice {
  queue: GPUQueue;
  createBuffer(descriptor: unknown): GPUBuffer;
  createTexture(descriptor: unknown): GPUTexture;
  createSampler(descriptor: unknown): GPUSampler;
  createShaderModule(descriptor: { code: string }): GPUShaderModule;
  createRenderPipelineAsync(descriptor: unknown): Promise<GPURenderPipeline>;
  createBindGroup(descriptor: unknown): GPUBindGroup;
  createCommandEncoder(): {
    beginRenderPass(descriptor: unknown): {
      setPipeline(pipeline: GPURenderPipeline): void;
      setBindGroup(index: number, bindGroup: GPUBindGroup): void;
      setVertexBuffer(slot: number, buffer: GPUBuffer): void;
      draw(vertexCount: number): void;
      end(): void;
    };
    finish(): unknown;
  };
}

interface Navigator {
  gpu?: {
    requestAdapter(): Promise<GPUAdapter | null>;
    getPreferredCanvasFormat(): GPUTextureFormat;
  };
}

interface HTMLCanvasElement {
  getContext(contextId: "webgpu"): GPUCanvasContext | null;
}

declare const GPUBufferUsage: {
  UNIFORM: number;
  COPY_DST: number;
  VERTEX: number;
};

declare const GPUTextureUsage: {
  TEXTURE_BINDING: number;
  COPY_DST: number;
};
