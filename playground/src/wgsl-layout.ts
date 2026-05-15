export type ShaderStage = "vertex" | "fragment" | "compute";

export type StructField = {
  name: string;
  typeName: string;
  align: number | null;
  builtin: string | null;
  location: number | null;
};

export type StructInfo = {
  fields: StructField[];
};

export type BindingInfo = {
  group: number;
  binding: number;
  addressSpace: string | null;
  name: string;
  typeName: string;
};

export const collectBindings = (source: string) => {
  const bindings: BindingInfo[] = [];
  const pattern = /@group\((\d+)\)\s*@binding\((\d+)\)\s*var(?:<([^>]+)>)?\s+([A-Za-z_]\w*):\s*([^;]+);/g;

  for (const match of source.matchAll(pattern)) {
    bindings.push({
      group: Number.parseInt(match[1], 10),
      binding: Number.parseInt(match[2], 10),
      addressSpace: match[3]?.trim() ?? null,
      name: match[4],
      typeName: match[5].trim(),
    });
  }

  return bindings;
};

export const collectStructs = (source: string) => {
  const structs = new Map<string, StructInfo>();
  for (const match of source.matchAll(/struct\s+([A-Za-z_]\w*)\s*\{([\s\S]*?)\}/g)) {
    structs.set(match[1], {
      fields: collectStructFields(match[2]),
    });
  }
  return structs;
};

export const sizeOfWrapperField = (field: StructField) => {
  const valueSize = sizeOfWgslType(field.typeName);
  if (valueSize === null) return null;
  return roundUp(field.align ?? alignOfWgslType(field.typeName) ?? 1, valueSize);
};

export const sizeOfWgslType = (typeName: string): number | null => {
  if (/^(?:f32|i32|u32|bool)$/.test(typeName)) return 4;

  const vector = typeName.match(/^vec([234])(?:[fiu]|<[^>]+>)$/);
  if (vector) return Number.parseInt(vector[1], 10) * 4;

  const matrix = typeName.match(/^mat(\d)x(\d)f$/);
  if (!matrix) return null;

  const columns = Number.parseInt(matrix[1], 10);
  const rows = Number.parseInt(matrix[2], 10);
  return columns * roundUp(alignOfVector(rows), rows * 4);
};

const collectStructFields = (body: string) => {
  const fields: StructField[] = [];

  for (const line of body.split("\n")) {
    const field = line.match(/([A-Za-z_]\w*)\s*:\s*([^,\n]+)/);
    if (!field) continue;

    fields.push({
      name: field[1],
      typeName: field[2].trim(),
      align: numericAttribute(line, "align"),
      builtin: textAttribute(line, "builtin"),
      location: numericAttribute(line, "location"),
    });
  }

  return fields;
};

const numericAttribute = (line: string, name: string) => {
  const match = line.match(new RegExp(`@${name}\\((\\d+)\\)`));
  return match ? Number.parseInt(match[1], 10) : null;
};

const textAttribute = (line: string, name: string) => {
  const match = line.match(new RegExp(`@${name}\\(([^)]+)\\)`));
  return match?.[1] ?? null;
};

const alignOfWgslType = (typeName: string): number | null => {
  if (/^(?:f32|i32|u32|bool)$/.test(typeName)) return 4;

  const vector = typeName.match(/^vec([234])(?:[fiu]|<[^>]+>)$/);
  if (vector) return alignOfVector(Number.parseInt(vector[1], 10));

  const matrix = typeName.match(/^mat\d+x(\d)f$/);
  return matrix ? alignOfVector(Number.parseInt(matrix[1], 10)) : null;
};

const alignOfVector = (length: number) => (length === 2 ? 8 : 16);

const roundUp = (alignment: number, value: number) =>
  Math.ceil(value / alignment) * alignment;
