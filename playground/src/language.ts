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
];

export const registerLanguage = (instance: typeof monaco) => {
  instance.languages.register({ id: "zwgsl" });
  instance.languages.setMonarchTokensProvider("zwgsl", {
    keywords,
    tokenizer: {
      root: [
        [/[a-zA-Z_][\w]*/, { cases: { "@keywords": "keyword", "@default": "identifier" } }],
        [/:[a-zA-Z_][\w]*/, "string"],
        [/\d+\.\d+/, "number.float"],
        [/\d+/, "number"],
        [/".*?"/, "string"],
        [/#.*$/, "comment"],
      ],
    },
  });
};
