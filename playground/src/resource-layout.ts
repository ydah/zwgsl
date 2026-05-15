import type { CompileResult } from "./compiler";
import {
  collectBindings,
  collectStructs,
  sizeOfWgslType,
  sizeOfWrapperField,
} from "./wgsl-layout";
import type { BindingInfo, ShaderStage, StructField, StructInfo } from "./wgsl-layout";

type ResourceRow = {
  stages: Set<ShaderStage>;
  text: string;
};

const noResourceLayout = "// No resources or stage locations detected.\n";

const stageSources = (result: CompileResult) =>
  [
    ["vertex", result.vertex],
    ["fragment", result.fragment],
    ["compute", result.compute],
  ] as const;

export const renderResourceLayout = (result: CompileResult) => {
  const resourceRows = new Map<string, ResourceRow>();
  const interfaceRows: string[] = [];

  for (const [stage, source] of stageSources(result)) {
    if (!source) continue;

    const structs = collectStructs(source);
    const bindings = collectBindings(source);
    addBindingRows(resourceRows, stage, structs, bindings);
    interfaceRows.push(...collectInterfaceRows(stage, structs, source));
  }

  const rows = [
    ...Array.from(resourceRows.values()).map((row) => `${formatStages(row.stages)}: ${row.text}`),
    ...interfaceRows,
  ];

  if (rows.length === 0) return noResourceLayout;
  return ["// Generated resource layout", ...rows.map((row) => `// ${row}`)].join("\n");
};

export const hasResourceLayout = (result: CompileResult) =>
  renderResourceLayout(result) !== noResourceLayout;

const addBindingRows = (
  rows: Map<string, ResourceRow>,
  stage: ShaderStage,
  structs: Map<string, StructInfo>,
  bindings: BindingInfo[],
) => {
  const textures = new Map<string, BindingInfo>();
  const samplers = new Map<string, BindingInfo>();

  for (const binding of bindings) {
    if (binding.typeName.startsWith("texture_")) {
      textures.set(resourceBaseName(binding.name, "_texture"), binding);
      continue;
    }

    if (binding.typeName === "sampler") {
      samplers.set(resourceBaseName(binding.name, "_sampler"), binding);
      continue;
    }

    addResourceRow(rows, stage, bindingKey(binding), describeBinding(binding, structs));
  }

  for (const [name, texture] of textures) {
    const sampler = samplers.get(name);
    if (!sampler) {
      addResourceRow(rows, stage, bindingKey(texture), describeBinding(texture, structs));
      continue;
    }

    addResourceRow(
      rows,
      stage,
      `texture-sampler:${texture.group}:${texture.binding}:${sampler.group}:${sampler.binding}:${name}`,
      `texture/sampler ${name}: texture group ${texture.group} binding ${texture.binding}, sampler group ${sampler.group} binding ${sampler.binding} ${texture.typeName}`,
    );
    samplers.delete(name);
  }

  for (const sampler of samplers.values()) {
    addResourceRow(rows, stage, bindingKey(sampler), describeBinding(sampler, structs));
  }
};

const addResourceRow = (
  rows: Map<string, ResourceRow>,
  stage: ShaderStage,
  key: string,
  text: string,
) => {
  const existing = rows.get(key);
  if (existing) {
    existing.stages.add(stage);
    return;
  }

  rows.set(key, {
    stages: new Set([stage]),
    text,
  });
};

const describeBinding = (binding: BindingInfo, structs: Map<string, StructInfo>) => {
  const addressSpace = binding.addressSpace ? `${binding.addressSpace} ` : "";
  const uniform = binding.addressSpace === "uniform" ? describeUniformType(binding, structs) : null;
  const typeDescription = uniform ?? binding.typeName;
  return `${addressSpace}${binding.name}: group ${binding.group} binding ${binding.binding} ${typeDescription}`;
};

const describeUniformType = (binding: BindingInfo, structs: Map<string, StructInfo>) => {
  const wrapper = structs.get(binding.typeName);
  const valueField = wrapper?.fields.find((field) => field.name === "value");
  const typeName = valueField?.typeName ?? binding.typeName;
  const size = valueField
    ? sizeOfWrapperField(valueField)
    : sizeOfWgslType(typeName);

  return size === null ? typeName : `${typeName} (${size} bytes)`;
};

const collectInterfaceRows = (
  stage: ShaderStage,
  structs: Map<string, StructInfo>,
  source: string,
) => {
  const rows: string[] = [];

  for (const [structName, role] of interfaceStructRoles(stage)) {
    const struct = structs.get(structName);
    if (!struct) continue;

    for (const field of struct.fields) {
      rows.push(`${role} ${formatFieldAttribute(field)} ${field.name}: ${field.typeName}`);
    }
  }

  if (stage === "compute") {
    rows.push(...collectComputeBuiltinRows(source));
  }

  return rows;
};

const collectComputeBuiltinRows = (source: string) => {
  const rows: string[] = [];
  for (const match of source.matchAll(/@builtin\(([^)]+)\)\s+([A-Za-z_]\w*):\s*([^,\n)]+)/g)) {
    rows.push(`compute input @builtin(${match[1]}) ${match[2]}: ${match[3].trim()}`);
  }
  return rows;
};

const interfaceStructRoles = (stage: ShaderStage) => {
  if (stage === "vertex") {
    return [
      ["VertexInput", "vertex input"],
      ["VertexOutput", "vertex output"],
    ] as const;
  }

  if (stage === "fragment") {
    return [
      ["FragmentInput", "fragment input"],
      ["FragmentOutput", "fragment output"],
    ] as const;
  }

  return [] as const;
};

const formatFieldAttribute = (field: StructField) => {
  if (field.location !== null) return `@location(${field.location})`;
  if (field.builtin) return `@builtin(${field.builtin})`;
  return "@field";
};

const formatStages = (stages: Set<ShaderStage>) => Array.from(stages).join("/");

const bindingKey = (binding: BindingInfo) =>
  `binding:${binding.group}:${binding.binding}:${binding.name}:${binding.typeName}`;

const resourceBaseName = (name: string, suffix: string) =>
  name.endsWith(suffix) ? name.slice(0, -suffix.length) : name;
