const std = @import("std");
const zwgsl = @import("zwgsl");

test "wasm bridge compiles compute WGSL and frees storage" {
    const source =
        \\compute do
        \\  def main
        \\    id: UVec3 = global_invocation_id
        \\  end
        \\end
    ;

    const input_ptr = zwgsl.zwgsl_wasm_alloc(source.len);
    try std.testing.expect(input_ptr != 0);
    defer zwgsl.zwgsl_wasm_free(input_ptr, source.len);

    const input: [*]u8 = @ptrFromInt(input_ptr);
    @memcpy(input[0..source.len], source);

    const result_ptr = zwgsl.zwgsl_wasm_compile(input_ptr, source.len);
    try std.testing.expect(result_ptr != 0);
    defer zwgsl.zwgsl_wasm_result_free(result_ptr);

    const result: *const zwgsl.WasmCompileResult = @ptrFromInt(result_ptr);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics_len);
    try std.testing.expect(result.compute_ptr != 0);
    try std.testing.expect(result.compute_len > 0);

    const compute_source: [*]const u8 = @ptrFromInt(result.compute_ptr);
    const slice = compute_source[0..result.compute_len];
    try std.testing.expect(std.mem.indexOf(u8, slice, "@compute @workgroup_size(1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, slice, "global_invocation_id") != null);
}
