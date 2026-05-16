const std = @import("std");

test {
    std.testing.refAllDecls(@import("zwgsl"));
}

comptime {
    _ = @import("c_api_test.zig");
    _ = @import("diagnostics_test.zig");
    _ = @import("formatter_test.zig");
    _ = @import("fuzz_smoke_test.zig");
    _ = @import("glsl_emitter_test.zig");
    _ = @import("integration_test.zig");
    _ = @import("lexer_test.zig");
    _ = @import("lsp_test.zig");
    _ = @import("parser_test.zig");
    _ = @import("readme_test.zig");
    _ = @import("sema_test.zig");
    _ = @import("source_map_test.zig");
    _ = @import("version_consistency_test.zig");
    _ = @import("wasm_bridge_test.zig");
    _ = @import("wgsl_emitter_test.zig");
}
