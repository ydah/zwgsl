import type * as monaco from "monaco-editor";

const keywords = [
  "def",
  "do",
  "end",
  "if",
  "else",
  "elsif",
  "unless",
  "let",
  "where",
  "type",
  "match",
  "when",
  "struct",
  "trait",
  "impl",
  "for",
  "return",
  "then",
  "and",
  "or",
  "not",
  "true",
  "false",
  "self",
  "Self",
];

const declarations = ["uniform", "input", "output", "varying", "vertex", "fragment", "compute"];

const typeKeywords = [
  "Float",
  "Int",
  "UInt",
  "Bool",
  "Vec2",
  "Vec3",
  "Vec4",
  "Mat2",
  "Mat3",
  "Mat4",
  "Sampler2D",
  "SamplerCube",
  "Sampler3D",
];

const blockStartPattern =
  /^\s*(?:def|do|if|unless|match|when|else|elsif|where|struct|type|trait|impl|vertex|fragment|compute)\b.*$/;

export const registerLanguage = (instance: typeof monaco) => {
  instance.languages.register({ id: "zwgsl" });
  instance.languages.setMonarchTokensProvider("zwgsl", {
    keywords,
    declarations,
    typeKeywords,
    tokenizer: {
      root: [
        [/#.*$/, "comment"],
        [/"/, { token: "string.quote", bracket: "@open", next: "@string" }],
        [/:([a-zA-Z_]\w*)/, "symbol"],
        [/\b\d+\.\d+(?:e[+-]?\d+)?\b/i, "number.float"],
        [/\b\d+(?:e[+-]?\d+)?\b/i, "number"],
        [/[A-Z][A-Za-z0-9_]*/, { cases: { "@typeKeywords": "type.identifier", "@default": "type.identifier" } }],
        [/@?[a-zA-Z_][\w]*[!?]?/, {
          cases: {
            "@keywords": "keyword",
            "@declarations": "keyword.declaration",
            "@default": "identifier",
          },
        }],
        [/[+\-*/%=<>!&|.^~]+/, "operator"],
        [/[()[\]]/, "@brackets"],
        [/[,.]/, "delimiter"],
      ],
      string: [
        [/[^\\"]+/, "string"],
        [/\\./, "string.escape"],
        [/"/, { token: "string.quote", bracket: "@close", next: "@pop" }],
      ],
    },
  });
  instance.languages.setLanguageConfiguration("zwgsl", {
    comments: {
      lineComment: "#",
    },
    wordPattern: /(-?\d*\.\d\w*)|([:@]?[A-Za-z_]\w*[!?]?)|([()[\]])|([+\-*/%=<>!&|.^~]+)/g,
    brackets: [
      ["(", ")"],
      ["[", "]"],
      ["do", "end"],
      ["def", "end"],
      ["if", "end"],
      ["match", "end"],
      ["struct", "end"],
      ["type", "end"],
      ["trait", "end"],
      ["impl", "end"],
    ],
    autoClosingPairs: [
      { open: "(", close: ")" },
      { open: "[", close: "]" },
      { open: "\"", close: "\"" },
    ],
    surroundingPairs: [
      { open: "(", close: ")" },
      { open: "[", close: "]" },
      { open: "\"", close: "\"" },
    ],
    indentationRules: {
      increaseIndentPattern: blockStartPattern,
      decreaseIndentPattern: /^\s*end\b.*$/,
      indentNextLinePattern: /^\s*(?:when|else|elsif)\b.*$/,
      unIndentedLinePattern: /^\s*(?:#.*)?$/,
    },
    onEnterRules: [
      {
        beforeText: blockStartPattern,
        action: { indentAction: instance.languages.IndentAction.Indent },
      },
      {
        beforeText: /^\s*end\b.*$/,
        action: { indentAction: instance.languages.IndentAction.Outdent },
      },
      {
        beforeText: /^\s*(?:when|else|elsif)\b.*$/,
        action: { indentAction: instance.languages.IndentAction.IndentOutdent },
      },
    ],
    folding: {
      markers: {
        start: /^\s*(?:def|do|if|unless|match|struct|type|trait|impl|vertex|fragment|compute)\b/,
        end: /^\s*end\b/,
      },
    },
  });
};
