const std = @import("std");
const hir = @import("hir.zig");
const ir_builder = @import("ir_builder.zig");
const sema = @import("sema.zig");

pub fn build(allocator: std.mem.Allocator, typed: *sema.TypedProgram) !*hir.Module {
    return try ir_builder.build(allocator, typed);
}
