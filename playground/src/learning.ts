export type LearningAnnotation = {
  line: number;
  message: string;
};

type LearningRule = {
  pattern: RegExp;
  message: string;
};

const rules: LearningRule[] = [
  {
    pattern: /^\s*uniform\b/,
    message: "uniform becomes a @group(0) binding in generated WGSL",
  },
  {
    pattern: /^\s*input\b/,
    message: "stage input lowers to a WGSL location or builtin parameter",
  },
  {
    pattern: /^\s*output\b/,
    message: "stage output lowers to a WGSL location result",
  },
  {
    pattern: /^\s*varying\b/,
    message: "varying links vertex output to fragment input",
  },
  {
    pattern: /^\s*vertex\s+do\b/,
    message: "vertex stage emits an @vertex entry point",
  },
  {
    pattern: /^\s*fragment\s+do\b/,
    message: "fragment stage emits an @fragment entry point",
  },
  {
    pattern: /^\s*compute\s+do\b/,
    message: "compute stage emits an @compute entry point",
  },
  {
    pattern: /^\s*where\b/,
    message: "where bindings are lowered before the function body",
  },
  {
    pattern: /^\s*type\b/,
    message: "ADT constructors are represented as tagged values",
  },
  {
    pattern: /^\s*match\b/,
    message: "match arms lower to structured WGSL control flow",
  },
  {
    pattern: /^\s*trait\b/,
    message: "traits are resolved statically during compilation",
  },
  {
    pattern: /^\s*impl\b/,
    message: "impl methods are specialized before WGSL emission",
  },
  {
    pattern: /\.normalize\b|\.dot\b|\.cross\b|\.length\b/,
    message: "method chains lower to WGSL builtin calls",
  },
  {
    pattern: /\bSampler(?:2D|3D|Cube)\b/,
    message: "samplers lower to paired texture and sampler bindings",
  },
];

const maxAnnotations = 8;

export const learningAnnotationsForSource = (source: string): LearningAnnotation[] => {
  const annotations: LearningAnnotation[] = [];
  const usedMessages = new Set<string>();

  for (const [index, line] of source.split("\n").entries()) {
    for (const rule of rules) {
      if (!rule.pattern.test(line) || usedMessages.has(rule.message)) continue;
      annotations.push({ line: index + 1, message: rule.message });
      usedMessages.add(rule.message);
      break;
    }

    if (annotations.length >= maxAnnotations) break;
  }

  return annotations;
};
