import type { CompileResult } from "./compiler";

type PreviewApi = {
  render(result: CompileResult): Promise<void>;
};

type UniformValueKind = "f32" | "i32" | "u32";

type UniformSpec = {
  binding: number;
  name: string;
  typeName: string;
  kind: UniformValueKind;
  length: 1 | 2 | 3 | 4;
  columns: 1 | 2 | 3 | 4;
  auto: "time" | "resolution" | null;
  slider: {
    min: number;
    max: number;
    step: number;
  } | null;
};

type UniformState = {
  spec: UniformSpec;
  buffer: GPUBuffer;
  values: number[];
  inputs: HTMLInputElement[];
  valueLabels: HTMLOutputElement[];
};

type TextureDimension = "2d" | "3d" | "cube";

type TextureSpec = {
  textureBinding: number;
  samplerBinding: number;
  name: string;
  typeName: string;
  dimension: TextureDimension;
};

type TextureState = {
  spec: TextureSpec;
  texture: GPUTexture;
  view: GPUTextureView;
  sampler: GPUSampler;
};

type VertexAttributeKind = "f32" | "i32" | "u32";

type VertexAttributeSpec = {
  location: number;
  name: string;
  typeName: string;
  format: GPUVertexFormat;
  kind: VertexAttributeKind;
  componentCount: 1 | 2 | 3 | 4;
  offset: number;
};

type VertexPreviewState = {
  buffer: GPUBuffer | null;
  buffers: GPUVertexBufferLayout[];
  vertexCount: number;
  profile: "fullscreen" | "triangle";
};

type CompiledPreviewState = {
  key: string;
  pipeline: GPURenderPipeline;
  bindGroup: GPUBindGroup | null;
  uniforms: UniformState[];
  textures: TextureState[];
  vertex: VertexPreviewState;
};

const fallbackVertexShader = `
@vertex
fn main(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
  var positions = array<vec2f, 3>(
    vec2f(-1.0, -1.0),
    vec2f(3.0, -1.0),
    vec2f(-1.0, 3.0),
  );
  return vec4f(positions[index], 0.0, 1.0);
}
`;

const fallbackFragmentShader = `
@fragment
fn main() -> @location(0) vec4f {
  return vec4f(0.91, 0.48, 0.19, 1.0);
}
`;

const previewFullscreenPositions = [
  [-1, -1, 0, 1],
  [3, -1, 0, 1],
  [-1, 3, 0, 1],
] as const;

const previewTrianglePositions = [
  [-0.7, -0.6, 0, 1],
  [0.7, -0.6, 0, 1],
  [0, 0.78, 0, 1],
] as const;

const previewFullscreenUvs = [
  [0, 0, 0, 1],
  [2, 0, 0, 1],
  [0, 2, 0, 1],
] as const;

const previewTriangleUvs = [
  [0, 1, 0, 1],
  [1, 1, 0, 1],
  [0.5, 0, 0, 1],
] as const;

const previewColors = [
  [0.91, 0.48, 0.19, 1],
  [0.18, 0.64, 1, 1],
  [1, 0.82, 0.24, 1],
] as const;

export const createPreview = async (
  canvas: HTMLCanvasElement,
  controlsRoot: HTMLElement,
  status: HTMLElement,
): Promise<PreviewApi> => {
  const adapter = await navigator.gpu?.requestAdapter();
  const device = await adapter?.requestDevice();
  const context = canvas.getContext("webgpu");

  if (!adapter || !device || !context) {
    status.textContent = "2d fallback";
    controlsRoot.replaceChildren(makeEmptyState("WebGPU unavailable"));
    return {
      async render(_: CompileResult) {
        const ctx = canvas.getContext("2d");
        if (!ctx) return;
        resizeCanvas(canvas);
        ctx.fillStyle = "#ff7f50";
        ctx.fillRect(0, 0, canvas.width, canvas.height);
      },
    };
  }

  const format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format, alphaMode: "opaque" });

  let pendingResult: CompileResult | null = null;
  let activeState: CompiledPreviewState | null = null;
  let buildVersion = 0;
  const startedAt = performance.now();

  const ensureState = async (result: CompileResult) => {
    const currentVersion = ++buildVersion;

    if (result.compute && !result.vertex && !result.fragment) {
      status.textContent = "compute only";
      controlsRoot.replaceChildren(makeEmptyState("Compute shaders do not have a preview surface."));
      return activeState;
    }

    const vertexSource = result.vertex?.includes("@vertex") ? result.vertex : fallbackVertexShader;
    const fragmentSource = result.fragment?.includes("@fragment") ? result.fragment : fallbackFragmentShader;
    const nextKey = `${vertexSource}\n// ---\n${fragmentSource}`;

    if (activeState?.key === nextKey) {
      return activeState;
    }

    const uniformSpecs = collectUniformSpecs(vertexSource, fragmentSource);
    const uniformStates = uniformSpecs.map((spec) => createUniformState(device, spec, canvas));
    const textureSpecs = collectTextureSpecs(vertexSource, fragmentSource);
    const textureStates = textureSpecs.map((spec) => createTextureState(device, spec));
    const vertexState = createVertexPreviewState(device, vertexSource, uniformSpecs, textureSpecs);

    try {
      const vertexModule = device.createShaderModule({ code: vertexSource });
      const fragmentModule = device.createShaderModule({ code: fragmentSource });
      const pipeline = await device.createRenderPipelineAsync({
        layout: "auto",
        vertex: {
          module: vertexModule,
          entryPoint: "main",
          buffers: vertexState.buffers,
        },
        fragment: {
          module: fragmentModule,
          entryPoint: "main",
          targets: [{ format }],
        },
        primitive: { topology: "triangle-list" },
      });

      if (currentVersion !== buildVersion) {
        destroyUniforms(uniformStates);
        destroyTextures(textureStates);
        destroyVertexPreview(vertexState);
        return activeState;
      }

      const bindEntries = [
        ...uniformStates.map<GPUBindGroupEntry>((state) => ({
          binding: state.spec.binding,
          resource: { buffer: state.buffer },
        })),
        ...textureStates.flatMap<GPUBindGroupEntry>((state) => [
          {
            binding: state.spec.textureBinding,
            resource: state.view,
          },
          {
            binding: state.spec.samplerBinding,
            resource: state.sampler,
          },
        ]),
      ];

      const bindGroup =
        bindEntries.length > 0
          ? device.createBindGroup({
              layout: pipeline.getBindGroupLayout(0),
              entries: bindEntries,
            })
          : null;

      if (activeState) {
        destroyUniforms(activeState.uniforms);
        destroyTextures(activeState.textures);
        destroyVertexPreview(activeState.vertex);
      }

      renderControls(controlsRoot, uniformStates, textureStates);
      status.textContent = vertexState.profile === "triangle" ? "live • triangle" : "live • fullscreen";
      return {
        key: nextKey,
        pipeline,
        bindGroup,
        uniforms: uniformStates,
        textures: textureStates,
        vertex: vertexState,
      };
    } catch (error) {
      destroyUniforms(uniformStates);
      destroyTextures(textureStates);
      destroyVertexPreview(vertexState);
      status.textContent = "preview error";
      controlsRoot.replaceChildren(
        makeEmptyState(
          `WGSL compiled, but the preview pipeline could not be created. ${describePreviewError(error)}`,
        ),
      );
      console.error("zwgsl playground preview failed", error);
      return activeState;
    }
  };

  const tick = (now: number) => {
    if (pendingResult) {
      const result = pendingResult;
      pendingResult = null;
      void ensureState(result).then((state) => {
        if (state) activeState = state;
      });
    }

    if (activeState) {
      updateUniforms(activeState.uniforms, canvas, device, (now - startedAt) / 1000);
      drawFrame(device, context, activeState.pipeline, activeState.bindGroup, activeState.vertex);
    }

    window.requestAnimationFrame(tick);
  };

  window.requestAnimationFrame(tick);

  return {
    async render(result: CompileResult) {
      pendingResult = result;
    },
  };
};

const destroyUniforms = (uniforms: UniformState[]) => {
  for (const state of uniforms) {
    state.buffer.destroy();
  }
};

const destroyTextures = (textures: TextureState[]) => {
  for (const state of textures) {
    state.texture.destroy();
  }
};

const destroyVertexPreview = (vertex: VertexPreviewState) => {
  vertex.buffer?.destroy();
};

const collectUniformSpecs = (...sources: Array<string | null>) => {
  const specs = new Map<number, UniformSpec>();
  const pattern = /@group\(0\)\s*@binding\((\d+)\)\s*var<uniform>\s+([A-Za-z_]\w*):\s*([A-Za-z0-9_<>]+);/g;

  for (const source of sources) {
    if (!source) continue;
    const wrappedTypes = collectWrappedUniformTypes(source);
    for (const match of source.matchAll(pattern)) {
      const binding = Number(match[1]);
      if (Number.isNaN(binding) || specs.has(binding)) continue;
      const resolvedType = wrappedTypes.get(match[3]) ?? match[3];
      const spec = parseUniformSpec(binding, match[2], resolvedType);
      if (spec) specs.set(binding, spec);
    }
  }

  return [...specs.values()].sort((left, right) => left.binding - right.binding);
};

const collectWrappedUniformTypes = (source: string) => {
  const wrappedTypes = new Map<string, string>();
  const pattern =
    /struct\s+([A-Za-z_]\w*)\s*\{\s*(?:@align\(16\)\s*)?value:\s*([A-Za-z0-9_<>]+),\s*\};?/g;

  for (const match of source.matchAll(pattern)) {
    wrappedTypes.set(match[1], match[2]);
  }

  return wrappedTypes;
};

const collectTextureSpecs = (...sources: Array<string | null>) => {
  const textures = new Map<string, { binding: number; name: string; typeName: string }>();
  const samplers = new Map<string, number>();
  const texturePattern =
    /@group\(0\)\s*@binding\((\d+)\)\s*var\s+([A-Za-z_]\w*):\s*(texture_(?:2d|3d|cube)<f32>);/g;
  const samplerPattern = /@group\(0\)\s*@binding\((\d+)\)\s*var\s+([A-Za-z_]\w*):\s*sampler;/g;

  for (const source of sources) {
    if (!source) continue;

    for (const match of source.matchAll(texturePattern)) {
      const binding = Number(match[1]);
      const name = match[2];
      const baseName = name.endsWith("_texture") ? name.slice(0, -"_texture".length) : name;
      if (!Number.isNaN(binding) && !textures.has(baseName)) {
        textures.set(baseName, { binding, name: baseName, typeName: match[3] });
      }
    }

    for (const match of source.matchAll(samplerPattern)) {
      const binding = Number(match[1]);
      const name = match[2];
      const baseName = name.endsWith("_sampler") ? name.slice(0, -"_sampler".length) : name;
      if (!Number.isNaN(binding) && !samplers.has(baseName)) {
        samplers.set(baseName, binding);
      }
    }
  }

  return [...textures.values()]
    .flatMap<TextureSpec>((texture) => {
      const samplerBinding = samplers.get(texture.name);
      if (samplerBinding === undefined) return [];
      return [
        {
          textureBinding: texture.binding,
          samplerBinding,
          name: texture.name,
          typeName: texture.typeName,
          dimension: texture.typeName.includes("cube")
            ? "cube"
            : texture.typeName.includes("3d")
              ? "3d"
              : "2d",
        },
      ];
    })
    .sort((left, right) => left.textureBinding - right.textureBinding);
};

const parseUniformSpec = (binding: number, name: string, typeName: string): UniformSpec | null => {
  if (typeName === "f32" || typeName === "i32" || typeName === "u32") {
    return {
      binding,
      name,
      typeName,
      kind: typeName,
      length: 1,
      columns: 1,
      auto: autoUniform(name),
      slider: sliderRange(name, typeName === "f32"),
    };
  }

  const vectorMatch = /^vec([234])(f|i|u)$/.exec(typeName);
  if (vectorMatch) {
    return {
      binding,
      name,
      typeName,
      kind: vectorMatch[2] === "f" ? "f32" : vectorMatch[2] === "i" ? "i32" : "u32",
      length: Number(vectorMatch[1]) as 2 | 3 | 4,
      columns: 1,
      auto: autoUniform(name),
      slider: sliderRange(name, vectorMatch[2] === "f"),
    };
  }

  const matrixMatch = /^mat([234])x([234])f$/.exec(typeName);
  if (matrixMatch && matrixMatch[1] === matrixMatch[2]) {
    return {
      binding,
      name,
      typeName,
      kind: "f32",
      length: Number(matrixMatch[1]) as 2 | 3 | 4,
      columns: Number(matrixMatch[2]) as 2 | 3 | 4,
      auto: null,
      slider: null,
    };
  }

  return null;
};

const autoUniform = (name: string): UniformSpec["auto"] => {
  if (name === "iTime") return "time";
  if (name === "iResolution") return "resolution";
  return null;
};

const sliderRange = (name: string, isFloat: boolean) => {
  if (/matrix|transform|projection|view|model|mvp/i.test(name)) return null;
  if (/time|resolution/i.test(name)) return null;
  if (/color|tint|albedo|base/i.test(name)) {
    return {
      min: 0,
      max: 1,
      step: isFloat ? 0.01 : 1,
    };
  }
  return {
    min: isFloat ? -4 : -8,
    max: isFloat ? 4 : 8,
    step: isFloat ? 0.01 : 1,
  };
};

const createUniformState = (device: GPUDevice, spec: UniformSpec, canvas: HTMLCanvasElement): UniformState => ({
  spec,
  buffer: device.createBuffer({
    size: uniformBufferSize(spec),
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  }),
  values: initialValues(spec, canvas),
  inputs: [],
  valueLabels: [],
});

const uniformBufferSize = (spec: UniformSpec) => (spec.columns > 1 ? spec.columns * 16 : 16);

const initialValues = (spec: UniformSpec, canvas: HTMLCanvasElement) => {
  if (spec.auto === "resolution") {
    return fillValues(spec.length, [canvas.clientWidth || 1280, canvas.clientHeight || 720, 1, 0]);
  }

  if (spec.columns > 1) {
    return identityMatrix(spec.length);
  }

  if (/color|tint|albedo|base/i.test(spec.name)) {
    return fillValues(spec.length, [0.91, 0.48, 0.19, 1]);
  }

  if (/light/i.test(spec.name)) {
    return fillValues(spec.length, [0.4, 0.6, 1.2, 1]);
  }

  if (spec.kind === "u32") {
    return fillValues(spec.length, [1, 1, 1, 1]);
  }

  return fillValues(spec.length, [0, 0, 0, 1]);
};

const fillValues = (length: number, seed: number[]) => seed.slice(0, length);

const identityMatrix = (size: 2 | 3 | 4) => {
  const values = new Array<number>(size * size).fill(0);
  for (let index = 0; index < size; index += 1) {
    values[index * size + index] = 1;
  }
  return values;
};

const createTextureState = (device: GPUDevice, spec: TextureSpec): TextureState => {
  const texture = makePreviewTexture(device, spec);
  return {
    spec,
    texture,
    view: texture.createView({
      dimension: spec.dimension,
    }),
    sampler: device.createSampler({
      magFilter: "linear",
      minFilter: "linear",
      mipmapFilter: "linear",
      addressModeU: "repeat",
      addressModeV: "repeat",
      addressModeW: "repeat",
    }),
  };
};

const makePreviewTexture = (device: GPUDevice, spec: TextureSpec) => {
  const extent =
    spec.dimension === "cube"
      ? { width: 48, height: 48, depthOrArrayLayers: 6 }
      : spec.dimension === "3d"
        ? { width: 16, height: 16, depthOrArrayLayers: 16 }
        : { width: 96, height: 96, depthOrArrayLayers: 1 };

  const texture = device.createTexture({
    size: extent,
    format: "rgba8unorm",
    dimension: spec.dimension === "3d" ? "3d" : "2d",
    usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
  });

  const width = extent.width;
  const height = extent.height;
  const layers = extent.depthOrArrayLayers;
  const data = new Uint8Array(width * height * layers * 4);

  for (let layer = 0; layer < layers; layer += 1) {
    for (let y = 0; y < height; y += 1) {
      for (let x = 0; x < width; x += 1) {
        const offset = ((layer * width * height) + (y * width) + x) * 4;
        const band = ((Math.floor(x / 12) + Math.floor(y / 12) + layer) % 2) === 0;
        data[offset] = band ? 247 : 38;
        data[offset + 1] = spec.dimension === "3d" ? Math.floor((layer / Math.max(1, layers - 1)) * 255) : band ? 141 : 196;
        data[offset + 2] = spec.dimension === "cube" ? ((layer * 37) % 255) : band ? 64 : 250;
        data[offset + 3] = 255;
      }
    }
  }

  device.queue.writeTexture(
    { texture },
    data,
    {
      bytesPerRow: width * 4,
      rowsPerImage: height,
    },
    extent,
  );

  return texture;
};

const createVertexPreviewState = (
  device: GPUDevice,
  source: string,
  uniformSpecs: UniformSpec[],
  textureSpecs: TextureSpec[],
): VertexPreviewState => {
  const attributes = collectVertexAttributeSpecs(source);
  const profile = choosePreviewProfile(attributes, uniformSpecs, textureSpecs);
  if (attributes.length === 0) {
    return {
      buffer: null,
      buffers: [],
      vertexCount: 3,
      profile,
    };
  }

  const stride = attributes.reduce((size, attribute) => size + vertexFormatSize(attribute.format), 0);
  let nextOffset = 0;
  for (const attribute of attributes) {
    attribute.offset = nextOffset;
    nextOffset += vertexFormatSize(attribute.format);
  }

  const vertexCount = previewTrianglePositions.length;
  const bytes = new ArrayBuffer(stride * vertexCount);
  const view = new DataView(bytes);

  for (let vertexIndex = 0; vertexIndex < vertexCount; vertexIndex += 1) {
    const baseOffset = vertexIndex * stride;
    for (const attribute of attributes) {
      writeVertexAttribute(
        view,
        baseOffset + attribute.offset,
        attribute,
        previewAttributeValues(attribute, vertexIndex, profile),
      );
    }
  }

  const buffer = device.createBuffer({
    size: bytes.byteLength,
    usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
  });
  device.queue.writeBuffer(buffer, 0, bytes);

  return {
    buffer,
    buffers: [
      {
        arrayStride: stride,
        stepMode: "vertex",
        attributes: attributes.map((attribute) => ({
          shaderLocation: attribute.location,
          offset: attribute.offset,
          format: attribute.format,
        })),
      },
    ],
    vertexCount,
    profile,
  };
};

const choosePreviewProfile = (
  attributes: VertexAttributeSpec[],
  uniformSpecs: UniformSpec[],
  textureSpecs: TextureSpec[],
) => {
  if (textureSpecs.length > 0) return "fullscreen" as const;

  for (const attribute of attributes) {
    const name = attribute.name.toLowerCase();
    if (name.includes("normal") || name.includes("color") || name.includes("colour")) {
      return "triangle" as const;
    }
  }

  for (const uniform of uniformSpecs) {
    if (/matrix|projection|view|model|mvp/i.test(uniform.name)) {
      return "triangle" as const;
    }
  }

  return "fullscreen" as const;
};

const collectVertexAttributeSpecs = (source: string) => {
  const structMatch = /struct\s+VertexInput\s*\{([\s\S]*?)\};?/.exec(source);
  if (!structMatch) return [];

  const pattern = /@location\((\d+)\)\s*([A-Za-z_]\w*):\s*([A-Za-z0-9_]+),/g;
  const attributes: VertexAttributeSpec[] = [];

  for (const match of structMatch[1].matchAll(pattern)) {
    const location = Number(match[1]);
    const format = parseVertexAttributeFormat(match[3]);
    if (!Number.isFinite(location) || !format) continue;
    attributes.push({
      location,
      name: match[2],
      typeName: match[3],
      format: format.format,
      kind: format.kind,
      componentCount: format.componentCount,
      offset: 0,
    });
  }

  return attributes.sort((left, right) => left.location - right.location);
};

const parseVertexAttributeFormat = (typeName: string) => {
  if (typeName === "f32") return { format: "float32" as const, kind: "f32" as const, componentCount: 1 as const };
  if (typeName === "i32") return { format: "sint32" as const, kind: "i32" as const, componentCount: 1 as const };
  if (typeName === "u32") return { format: "uint32" as const, kind: "u32" as const, componentCount: 1 as const };

  const vectorMatch = /^vec([234])(f|i|u)$/.exec(typeName);
  if (!vectorMatch) return null;

  const width = Number(vectorMatch[1]) as 2 | 3 | 4;
  const prefix =
    vectorMatch[2] === "f"
      ? "float32"
      : vectorMatch[2] === "i"
        ? "sint32"
        : "uint32";
  const kind = vectorMatch[2] === "f" ? "f32" : vectorMatch[2] === "i" ? "i32" : "u32";

  return {
    format: `${prefix}x${width}` as GPUVertexFormat,
    kind,
    componentCount: width,
  };
};

const vertexFormatSize = (format: GPUVertexFormat) => {
  switch (format) {
    case "float32":
    case "sint32":
    case "uint32":
      return 4;
    case "float32x2":
    case "sint32x2":
    case "uint32x2":
      return 8;
    case "float32x3":
    case "sint32x3":
    case "uint32x3":
      return 12;
    case "float32x4":
    case "sint32x4":
    case "uint32x4":
      return 16;
    default:
      throw new Error(`Unsupported preview vertex format: ${format}`);
  }
};

const previewAttributeValues = (
  attribute: VertexAttributeSpec,
  vertexIndex: number,
  profile: "fullscreen" | "triangle",
) => {
  const name = attribute.name.toLowerCase();
  const positions = profile === "fullscreen" ? previewFullscreenPositions : previewTrianglePositions;
  const uvs = profile === "fullscreen" ? previewFullscreenUvs : previewTriangleUvs;

  if (name.includes("position")) return positions[vertexIndex].slice(0, attribute.componentCount);
  if (name === "uv" || name.endsWith("_uv") || name.includes("texcoord")) {
    return uvs[vertexIndex].slice(0, attribute.componentCount);
  }
  if (name.includes("normal")) {
    return [0, 0, 1, 0].slice(0, attribute.componentCount);
  }
  if (name.includes("color") || name.includes("colour") || name.includes("tint")) {
    return previewColors[vertexIndex].slice(0, attribute.componentCount);
  }
  if (name.includes("index") || name.endsWith("id")) {
    return [vertexIndex, 0, 0, 1].slice(0, attribute.componentCount);
  }
  if (attribute.kind === "f32") {
    return [0, 0, 0, 1].slice(0, attribute.componentCount);
  }
  return [0, 0, 0, 0].slice(0, attribute.componentCount);
};

const writeVertexAttribute = (
  view: DataView,
  offset: number,
  attribute: VertexAttributeSpec,
  values: number[],
) => {
  for (let index = 0; index < attribute.componentCount; index += 1) {
    const targetOffset = offset + index * 4;
    const value = values[index] ?? 0;

    switch (attribute.kind) {
      case "f32":
        view.setFloat32(targetOffset, value, true);
        break;
      case "i32":
        view.setInt32(targetOffset, Math.round(value), true);
        break;
      case "u32":
        view.setUint32(targetOffset, Math.max(0, Math.round(value)), true);
        break;
    }
  }
};

const describePreviewError = (error: unknown) => {
  if (error instanceof Error && error.message) return error.message;
  return "Check the browser console for the WebGPU validation error.";
};

const renderControls = (root: HTMLElement, uniforms: UniformState[], textures: TextureState[]) => {
  root.replaceChildren();

  if (uniforms.length === 0 && textures.length === 0) {
    root.append(makeEmptyState("No preview resources detected. Preview is using only shader code."));
    return;
  }

  for (const state of textures) {
    root.append(makeTextureCard(state));
  }

  for (const state of uniforms) {
    root.append(makeUniformCard(state));
  }
};

const makeEmptyState = (message: string) => {
  const element = document.createElement("p");
  element.className = "uniform-empty";
  element.textContent = message;
  return element;
};

const makeUniformCard = (state: UniformState) => {
  const card = document.createElement("section");
  card.className = "uniform-card";

  const header = document.createElement("header");
  header.className = "uniform-card-header";

  const title = document.createElement("strong");
  title.textContent = state.spec.name;
  header.append(title);

  const meta = document.createElement("span");
  meta.textContent =
    state.spec.auto === "time"
      ? "live time"
      : state.spec.auto === "resolution"
        ? "canvas size"
        : state.spec.columns > 1
          ? "identity matrix"
          : state.spec.typeName;
  header.append(meta);
  card.append(header);

  if (state.spec.slider === null) {
    const text = document.createElement("p");
    text.className = "uniform-live";
    text.textContent =
      state.spec.auto === null
        ? "Static value generated by the playground runtime."
        : "Updated every frame by the preview runtime.";
    card.append(text);
    return card;
  }

  const axes = ["x", "y", "z", "w"];
  for (let index = 0; index < state.spec.length; index += 1) {
    const row = document.createElement("label");
    row.className = "uniform-field";

    const axis = document.createElement("span");
    axis.textContent = state.spec.length === 1 ? state.spec.typeName : axes[index];
    row.append(axis);

    const input = document.createElement("input");
    input.type = "range";
    input.min = String(state.spec.slider.min);
    input.max = String(state.spec.slider.max);
    input.step = String(state.spec.slider.step);
    input.value = String(state.values[index] ?? 0);

    const output = document.createElement("output");
    output.value = formatUniformValue(state.values[index] ?? 0, state.spec.kind);
    output.textContent = output.value;

    input.addEventListener("input", () => {
      const nextValue = Number(input.value);
      state.values[index] = nextValue;
      output.value = formatUniformValue(nextValue, state.spec.kind);
      output.textContent = output.value;
    });

    state.inputs.push(input);
    state.valueLabels.push(output);

    row.append(input, output);
    card.append(row);
  }

  return card;
};

const makeTextureCard = (state: TextureState) => {
  const card = document.createElement("section");
  card.className = "uniform-card";

  const header = document.createElement("header");
  header.className = "uniform-card-header";

  const title = document.createElement("strong");
  title.textContent = state.spec.name;
  header.append(title);

  const meta = document.createElement("span");
  meta.textContent = state.spec.typeName;
  header.append(meta);
  card.append(header);

  const text = document.createElement("p");
  text.className = "uniform-live";
  text.textContent =
    state.spec.dimension === "2d"
      ? "Generated checkerboard texture for sampler preview."
      : `Generated ${state.spec.dimension} texture placeholder for sampler preview.`;
  card.append(text);

  return card;
};

const formatUniformValue = (value: number, kind: UniformValueKind) =>
  kind === "f32" ? value.toFixed(2) : String(Math.round(value));

const updateUniforms = (
  uniforms: UniformState[],
  canvas: HTMLCanvasElement,
  device: GPUDevice,
  elapsedSeconds: number,
) => {
  resizeCanvas(canvas);

  for (const state of uniforms) {
    if (state.spec.auto === "time") {
      state.values[0] = elapsedSeconds;
      syncValueLabel(state, 0);
    } else if (state.spec.auto === "resolution") {
      const next = fillValues(state.spec.length, [canvas.width, canvas.height, 1, 0]);
      state.values.splice(0, state.values.length, ...next);
      next.forEach((_, index) => syncValueLabel(state, index));
    }

    device.queue.writeBuffer(state.buffer, 0, encodeUniform(state.spec, state.values));
  }
};

const syncValueLabel = (state: UniformState, index: number) => {
  const label = state.valueLabels[index];
  if (!label) return;
  const formatted = formatUniformValue(state.values[index] ?? 0, state.spec.kind);
  label.value = formatted;
  label.textContent = formatted;
};

const encodeUniform = (spec: UniformSpec, values: number[]) => {
  if (spec.kind === "f32") {
    const data = new Float32Array(spec.columns > 1 ? spec.columns * 4 : 4);
    if (spec.columns > 1) {
      for (let column = 0; column < spec.columns; column += 1) {
        for (let row = 0; row < spec.length; row += 1) {
          data[column * 4 + row] = values[column * spec.length + row] ?? 0;
        }
      }
    } else {
      values.forEach((value, index) => {
        data[index] = value;
      });
    }
    return data;
  }

  if (spec.kind === "u32") {
    const data = new Uint32Array(4);
    values.forEach((value, index) => {
      data[index] = Math.max(0, Math.round(value));
    });
    return data;
  }

  const data = new Int32Array(4);
  values.forEach((value, index) => {
    data[index] = Math.round(value);
  });
  return data;
};

const resizeCanvas = (canvas: HTMLCanvasElement) => {
  const ratio = window.devicePixelRatio || 1;
  const width = Math.max(1, Math.floor(canvas.clientWidth * ratio));
  const height = Math.max(1, Math.floor(canvas.clientHeight * ratio));
  if (canvas.width !== width) canvas.width = width;
  if (canvas.height !== height) canvas.height = height;
};

const drawFrame = (
  device: GPUDevice,
  context: GPUCanvasContext,
  pipeline: GPURenderPipeline,
  bindGroup: GPUBindGroup | null,
  vertex: VertexPreviewState,
) => {
  const encoder = device.createCommandEncoder();
  const view = context.getCurrentTexture().createView();
  const pass = encoder.beginRenderPass({
    colorAttachments: [
      {
        view,
        clearValue: { r: 0.07, g: 0.1, b: 0.14, a: 1 },
        loadOp: "clear",
        storeOp: "store",
      },
    ],
  });

  pass.setPipeline(pipeline);
  if (bindGroup) {
    pass.setBindGroup(0, bindGroup);
  }
  if (vertex.buffer) {
    pass.setVertexBuffer(0, vertex.buffer);
  }
  pass.draw(vertex.vertexCount);
  pass.end();
  device.queue.submit([encoder.finish()]);
};
