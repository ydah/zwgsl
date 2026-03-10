import * as monaco from "monaco-editor";
import { registerLanguage } from "./language";

export const createEditor = async (element: HTMLElement, value: string) => {
  registerLanguage(monaco);

  return monaco.editor.create(element, {
    value,
    language: "zwgsl",
    automaticLayout: true,
    minimap: { enabled: false },
    fontFamily: "IBM Plex Mono, ui-monospace, monospace",
    fontSize: 14,
    theme: "vs-dark",
    smoothScrolling: true,
    padding: { top: 20, bottom: 20 },
  });
};
