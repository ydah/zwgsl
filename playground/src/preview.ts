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

type CompiledPreviewState = {
  key: string;
  pipeline: GPURenderPipeline;
  bindGroup: GPUBindGroup | null;
  uniforms: UniformState[];
  textures: TextureState[];
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

    try {
      const vertexModule = device.createShaderModule({ code: vertexSource });
      const fragmentModule = device.createShaderModule({ code: fragmentSource });
      const pipeline = await device.createRenderPipelineAsync({
        layout: "auto",
        vertex: { module: vertexModule, entryPoint: "main" },
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
      }

      renderControls(controlsRoot, uniformStates, textureStates);
      status.textContent = "live";
      return {
        key: nextKey,
        pipeline,
        bindGroup,
        uniforms: uniformStates,
        textures: textureStates,
      };
    } catch {
      destroyUniforms(uniformStates);
      destroyTextures(textureStates);
      status.textContent = "preview error";
      controlsRoot.replaceChildren(makeEmptyState("WGSL compiled, but the preview pipeline could not be created."));
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
      drawFrame(device, context, activeState.pipeline, activeState.bindGroup);
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

const collectUniformSpecs = (...sources: Array<string | null>) => {
  const specs = new Map<number, UniformSpec>();
  const pattern = /@group\(0\)\s*@binding\((\d+)\)\s*var<uniform>\s+([A-Za-z_]\w*):\s*([A-Za-z0-9_<>]+);/g;

  for (const source of sources) {
    if (!source) continue;
    for (const match of source.matchAll(pattern)) {
      const binding = Number(match[1]);
      if (Number.isNaN(binding) || specs.has(binding)) continue;
      const spec = parseUniformSpec(binding, match[2], match[3]);
      if (spec) specs.set(binding, spec);
    }
  }

  return [...specs.values()].sort((left, right) => left.binding - right.binding);
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
  pass.draw(3);
  pass.end();
  device.queue.submit([encoder.finish()]);
};
