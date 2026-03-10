import type { CompileResult } from "./compiler";

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

export const createPreview = async (canvas: HTMLCanvasElement) => {
  const adapter = await navigator.gpu?.requestAdapter();
  const device = await adapter?.requestDevice();
  const context = canvas.getContext("webgpu");

  if (!adapter || !device || !context) {
    return {
      async render(_: CompileResult) {
        const ctx = canvas.getContext("2d");
        if (!ctx) return;
        ctx.fillStyle = "#ff7f50";
        ctx.fillRect(0, 0, canvas.width, canvas.height);
      },
    };
  }

  const format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format, alphaMode: "opaque" });

  return {
    async render(result: CompileResult) {
      if (result.compute && !result.vertex && !result.fragment) return;

      try {
        const vertexModule = device.createShaderModule({
          code: result.vertex?.includes("@vertex") ? result.vertex : fallbackVertexShader,
        });
        const fragmentModule = device.createShaderModule({
          code: result.fragment?.includes("@fragment") ? result.fragment : fallbackFragmentShader,
        });

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
        pass.draw(3);
        pass.end();
        device.queue.submit([encoder.finish()]);
      } catch {
        // Keep the previous frame when the generated WGSL is not renderable.
      }
    },
  };
};
