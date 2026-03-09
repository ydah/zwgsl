const std = @import("std");

test {
    std.testing.refAllDecls(@import("zwgsl"));
}

comptime {
    _ = @import("diagnostics_test.zig");
    _ = @import("glsl_emitter_test.zig");
    _ = @import("integration_test.zig");
    _ = @import("lexer_test.zig");
    _ = @import("parser_test.zig");
    _ = @import("sema_test.zig");
    _ = @import("wgsl_emitter_test.zig");
}
