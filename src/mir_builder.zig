const std = @import("std");
const hir = @import("hir.zig");
const mir = @import("mir.zig");

pub fn build(_: std.mem.Allocator, module: *hir.Module) !*mir.Module {
    return module;
}
