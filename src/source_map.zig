const std = @import("std");
const compiler = @import("compiler.zig");

pub const StageFilter = enum {
    all,
    vertex,
    fragment,
    compute,
};

pub const Entry = struct {
    stage: []const u8,
    generated_line: u32,
    source_line: u32,
    source_column: ?u32 = null,
    source_text: ?[]const u8 = null,
};

pub fn collect(allocator: std.mem.Allocator, stage: []const u8, generated_source: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);

    var generated_line: u32 = 1;
    var start: usize = 0;
    while (start < generated_source.len) {
        const end = std.mem.indexOfScalarPos(u8, generated_source, start, '\n') orelse generated_source.len;
        const raw_line = generated_source[start..end];
        if (parseDebugComment(raw_line)) |entry| {
            try entries.append(allocator, .{
                .stage = stage,
                .generated_line = generated_line,
                .source_line = entry.source_line,
                .source_column = entry.source_column,
                .source_text = entry.source_text,
            });
        }
        generated_line += 1;
        if (end == generated_source.len) break;
        start = end + 1;
    }

    return try entries.toOwnedSlice(allocator);
}

pub fn writeJson(writer: anytype, output: compiler.CompileOutput, filter: StageFilter) !void {
    try writer.writeAll("{\"version\":1,\"mappings\":[");
    var wrote = false;
    if (filter == .all or filter == .vertex) {
        wrote = try writeStageMappings(writer, wrote, "vertex", output.vertex_source);
    }
    if (filter == .all or filter == .fragment) {
        wrote = try writeStageMappings(writer, wrote, "fragment", output.fragment_source);
    }
    if (filter == .all or filter == .compute) {
        wrote = try writeStageMappings(writer, wrote, "compute", output.compute_source);
    }
    try writer.writeAll("]}\n");
}

fn writeStageMappings(writer: anytype, wrote_before: bool, stage: []const u8, generated_source: ?[]const u8) !bool {
    const source = generated_source orelse return wrote_before;
    var wrote = wrote_before;
    var generated_line: u32 = 1;
    var start: usize = 0;
    while (start < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        if (parseDebugComment(source[start..end])) |entry| {
            if (wrote) try writer.writeByte(',');
            try writer.writeAll("{\"stage\":");
            try writeJsonString(writer, stage);
            try writer.print(",\"generatedLine\":{d},\"sourceLine\":{d}", .{
                generated_line,
                entry.source_line,
            });
            if (entry.source_column) |column| {
                try writer.print(",\"sourceColumn\":{d}", .{column});
            }
            if (entry.source_text) |text| {
                try writer.writeAll(",\"source\":");
                try writeJsonString(writer, text);
            }
            try writer.writeByte('}');
            wrote = true;
        }
        generated_line += 1;
        if (end == source.len) break;
        start = end + 1;
    }
    return wrote;
}

const ParsedComment = struct {
    source_line: u32,
    source_column: ?u32 = null,
    source_text: ?[]const u8 = null,
};

fn parseDebugComment(raw_line: []const u8) ?ParsedComment {
    const line = std.mem.trim(u8, raw_line, " \t\r");
    const prefix = "// zwgsl:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;

    var rest = line[prefix.len..];
    if (std.mem.startsWith(u8, rest, "lowering:")) return null;

    const source_line = parseLeadingU32(&rest) orelse return null;
    var parsed: ParsedComment = .{ .source_line = source_line };

    if (rest.len == 0) return parsed;
    if (rest[0] != ':') return null;
    rest = rest[1..];

    if (parseLeadingU32(&rest)) |source_column| {
        parsed.source_column = source_column;
        if (rest.len > 0 and rest[0] == ':') {
            rest = rest[1..];
        }
    }

    const source_text = std.mem.trim(u8, rest, " \t\r");
    if (source_text.len > 0) parsed.source_text = source_text;
    return parsed;
}

fn parseLeadingU32(rest: *[]const u8) ?u32 {
    var index: usize = 0;
    while (index < rest.*.len and std.ascii.isDigit(rest.*[index])) : (index += 1) {}
    if (index == 0) return null;
    const value = std.fmt.parseInt(u32, rest.*[0..index], 10) catch return null;
    rest.* = rest.*[index..];
    return value;
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| switch (ch) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(ch),
    };
    try writer.writeByte('"');
}
