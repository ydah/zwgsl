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

test "wasm bridge exposes hover completion and definition JSON" {
    const source =
        \\def helper(v: Vec3) -> Vec3
        \\  normalize(v)
        \\end
        \\
        \\compute do
        \\  def main
        \\    let value = helper(vec3(1.0))
        \\  end
        \\end
    ;

    const input_ptr = zwgsl.zwgsl_wasm_alloc(source.len);
    try std.testing.expect(input_ptr != 0);
    defer zwgsl.zwgsl_wasm_free(input_ptr, source.len);

    const input: [*]u8 = @ptrFromInt(input_ptr);
    @memcpy(input[0..source.len], source);

    const hover_ptr = zwgsl.zwgsl_wasm_hover(input_ptr, source.len, 1, 5);
    try std.testing.expect(hover_ptr != 0);
    defer zwgsl.zwgsl_wasm_json_result_free(hover_ptr);

    const hover_result: *const zwgsl.WasmJsonResult = @ptrFromInt(hover_ptr);
    const hover_json = @as([*]const u8, @ptrFromInt(hover_result.json_ptr))[0..hover_result.json_len];
    try std.testing.expect(std.mem.indexOf(u8, hover_json, "normalize") != null);

    const completion_ptr = zwgsl.zwgsl_wasm_completion(input_ptr, source.len, 5, 7);
    try std.testing.expect(completion_ptr != 0);
    defer zwgsl.zwgsl_wasm_json_result_free(completion_ptr);

    const completion_result: *const zwgsl.WasmJsonResult = @ptrFromInt(completion_ptr);
    const completion_json = @as([*]const u8, @ptrFromInt(completion_result.json_ptr))[0..completion_result.json_len];
    try std.testing.expect(std.mem.indexOf(u8, completion_json, "\"helper\"") != null);

    const definition_ptr = zwgsl.zwgsl_wasm_definition(input_ptr, source.len, 6, 18);
    try std.testing.expect(definition_ptr != 0);
    defer zwgsl.zwgsl_wasm_json_result_free(definition_ptr);

    const definition_result: *const zwgsl.WasmJsonResult = @ptrFromInt(definition_ptr);
    const definition_json = @as([*]const u8, @ptrFromInt(definition_result.json_ptr))[0..definition_result.json_len];
    try std.testing.expect(std.mem.indexOf(u8, definition_json, "\"line\":0") != null);
}
