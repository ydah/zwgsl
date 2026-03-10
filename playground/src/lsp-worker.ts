self.addEventListener("message", async (event: MessageEvent<{ source: string }>) => {
  const { source } = event.data;
  self.postMessage({
    diagnostics: source.includes("end") ? [] : [{ message: "missing end" }],
  });
});

export {};
