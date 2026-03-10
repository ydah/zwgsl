const zwgsl = @import("zwgsl");

pub fn main() !void {
    try zwgsl.lsp.server.main();
}
