const std = @import("std");
const zwgsl = @import("zwgsl");

const max_source_bytes = 64 * 1024 * 1024;

const Command = enum {
    compile,
    check,
};

const Stage = enum {
    all,
    vertex,
    fragment,
    compute,
};

const CliOptions = struct {
    command: Command,
    input_path: []const u8,
    target: zwgsl.compiler.Target = .wgsl,
    stage: Stage = .all,
    output_path: ?[]const u8 = null,
    emit_debug_comments: bool = false,
    optimize_output: bool = false,
};

const ParseResult = union(enum) {
    options: CliOptions,
    exit_code: u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const code = run(allocator) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("zwgsl: {s}\n", .{@errorName(err)});
        return std.process.exit(2);
    };
    if (code != 0) std.process.exit(code);
}

fn run(allocator: std.mem.Allocator) !u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const parsed = try parseArgs(args, stderr, stdout);
    const options = switch (parsed) {
        .options => |options| options,
        .exit_code => |code| return code,
    };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try std.fs.cwd().readFileAlloc(arena, options.input_path, max_source_bytes);
    const output = try zwgsl.compiler.compile(arena, source, .{
        .target = options.target,
        .emit_debug_comments = if (options.emit_debug_comments) 1 else 0,
        .optimize_output = if (options.optimize_output) 1 else 0,
    });

    if (output.errors.len > 0) {
        try writeDiagnostics(stderr, options.input_path, source, output.errors);
        return 1;
    }

    switch (options.command) {
        .check => {
            try stdout.print("{s}: ok\n", .{options.input_path});
            return 0;
        },
        .compile => {
            if (options.output_path) |path| {
                const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
                defer file.close();
                if (!try writeSelectedOutput(file.deprecatedWriter(), output, options.stage)) {
                    try stderr.print("zwgsl: selected stage has no output\n", .{});
                    return 1;
                }
            } else {
                if (!try writeSelectedOutput(stdout, output, options.stage)) {
                    try stderr.print("zwgsl: selected stage has no output\n", .{});
                    return 1;
                }
            }
            return 0;
        },
    }
}

fn parseArgs(
    args: []const [:0]const u8,
    stderr: anytype,
    stdout: anytype,
) !ParseResult {
    if (args.len == 1) {
        try writeUsage(stderr);
        return .{ .exit_code = 2 };
    }

    if (isHelp(args[1])) {
        try writeUsage(stdout);
        return .{ .exit_code = 0 };
    }

    if (std.mem.eql(u8, args[1], "--version")) {
        try stdout.print("zwgsl {s}\n", .{std.mem.span(zwgsl.zwgsl_version())});
        return .{ .exit_code = 0 };
    }

    const command = parseCommand(args[1]) orelse {
        try writeUsageError(stderr, "unknown command: {s}", .{args[1]});
        return .{ .exit_code = 2 };
    };

    var options = CliOptions{
        .command = command,
        .input_path = "",
    };
    var input_path: ?[]const u8 = null;

    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (isHelp(arg)) {
            try writeUsage(stdout);
            return .{ .exit_code = 0 };
        } else if (std.mem.eql(u8, arg, "--debug-comments")) {
            options.emit_debug_comments = true;
        } else if (std.mem.eql(u8, arg, "--optimize-output")) {
            options.optimize_output = true;
        } else if (std.mem.eql(u8, arg, "--target")) {
            index += 1;
            if (index >= args.len) {
                try writeUsageError(stderr, "--target requires a value", .{});
                return .{ .exit_code = 2 };
            }
            options.target = parseTarget(args[index]) orelse {
                try writeUsageError(stderr, "unknown target: {s}", .{args[index]});
                return .{ .exit_code = 2 };
            };
        } else if (stripPrefix(arg, "--target=")) |value| {
            options.target = parseTarget(value) orelse {
                try writeUsageError(stderr, "unknown target: {s}", .{value});
                return .{ .exit_code = 2 };
            };
        } else if (std.mem.eql(u8, arg, "--stage")) {
            index += 1;
            if (index >= args.len) {
                try writeUsageError(stderr, "--stage requires a value", .{});
                return .{ .exit_code = 2 };
            }
            options.stage = parseStage(args[index]) orelse {
                try writeUsageError(stderr, "unknown stage: {s}", .{args[index]});
                return .{ .exit_code = 2 };
            };
        } else if (stripPrefix(arg, "--stage=")) |value| {
            options.stage = parseStage(value) orelse {
                try writeUsageError(stderr, "unknown stage: {s}", .{value});
                return .{ .exit_code = 2 };
            };
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            index += 1;
            if (index >= args.len) {
                try writeUsageError(stderr, "{s} requires a path", .{arg});
                return .{ .exit_code = 2 };
            }
            options.output_path = args[index];
        } else if (stripPrefix(arg, "--output=")) |value| {
            options.output_path = value;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try writeUsageError(stderr, "unknown option: {s}", .{arg});
            return .{ .exit_code = 2 };
        } else if (input_path == null) {
            input_path = arg;
        } else {
            try writeUsageError(stderr, "unexpected argument: {s}", .{arg});
            return .{ .exit_code = 2 };
        }
    }

    if (input_path) |path| {
        options.input_path = path;
    } else {
        try writeUsageError(stderr, "missing input file", .{});
        return .{ .exit_code = 2 };
    }

    if (options.command == .check and options.output_path != null) {
        try writeUsageError(stderr, "check does not accept --output", .{});
        return .{ .exit_code = 2 };
    }

    return .{ .options = options };
}

fn parseCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "compile")) return .compile;
    if (std.mem.eql(u8, value, "check")) return .check;
    return null;
}

fn parseTarget(value: []const u8) ?zwgsl.compiler.Target {
    if (std.mem.eql(u8, value, "wgsl")) return .wgsl;
    if (std.mem.eql(u8, value, "glsl")) return .glsl_es_300;
    if (std.mem.eql(u8, value, "glsl-es-300")) return .glsl_es_300;
    if (std.mem.eql(u8, value, "glsl_es_300")) return .glsl_es_300;
    return null;
}

fn parseStage(value: []const u8) ?Stage {
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "vertex")) return .vertex;
    if (std.mem.eql(u8, value, "fragment")) return .fragment;
    if (std.mem.eql(u8, value, "compute")) return .compute;
    return null;
}

fn isHelp(value: []const u8) bool {
    return std.mem.eql(u8, value, "--help") or std.mem.eql(u8, value, "-h");
}

fn stripPrefix(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return value[prefix.len..];
}

fn writeSelectedOutput(writer: anytype, output: zwgsl.compiler.CompileOutput, stage: Stage) !bool {
    return switch (stage) {
        .all => try writeAllStages(writer, output),
        .vertex => try writeStage(writer, output.vertex_source),
        .fragment => try writeStage(writer, output.fragment_source),
        .compute => try writeStage(writer, output.compute_source),
    };
}

fn writeAllStages(writer: anytype, output: zwgsl.compiler.CompileOutput) !bool {
    var wrote = false;
    wrote = try writeNamedStage(writer, wrote, "vertex", output.vertex_source) or wrote;
    wrote = try writeNamedStage(writer, wrote, "fragment", output.fragment_source) or wrote;
    wrote = try writeNamedStage(writer, wrote, "compute", output.compute_source) or wrote;
    return wrote;
}

fn writeNamedStage(
    writer: anytype,
    wrote_before: bool,
    name: []const u8,
    source: ?[]const u8,
) !bool {
    const stage_source = source orelse return false;
    if (wrote_before) try writer.writeAll("\n");
    try writer.print("// {s}\n", .{name});
    try writer.writeAll(stage_source);
    return true;
}

fn writeStage(writer: anytype, source: ?[]const u8) !bool {
    const stage_source = source orelse return false;
    try writer.writeAll(stage_source);
    return true;
}

fn writeDiagnostics(writer: anytype, path: []const u8, source: []const u8, errors: []const zwgsl.compiler.Error) !void {
    for (errors) |diagnostic| {
        try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{
            path,
            diagnostic.line,
            diagnostic.column,
            errorKindName(diagnostic.kind),
            std.mem.span(diagnostic.message),
        });
        try zwgsl.diagnostics.writeSourceContext(writer, source, diagnostic.line, diagnostic.column);
    }
}

fn errorKindName(kind: zwgsl.compiler.ErrorKind) []const u8 {
    return switch (kind) {
        .ok => "ok",
        .syntax => "syntax",
        .type => "type",
        .semantic => "semantic",
        .internal => "internal",
    };
}

fn writeUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage:
        \\  zwgsl compile [options] <input.zw>
        \\  zwgsl check [options] <input.zw>
        \\
        \\Options:
        \\  --target <wgsl|glsl-es-300>  Output target (default: wgsl)
        \\  --stage <all|vertex|fragment|compute>
        \\  -o, --output <path>          Write compile output to a file
        \\  --debug-comments             Include source and lowering comments in generated output
        \\  --optimize-output            Emit optimized output formatting
        \\  -h, --help                   Show this help
        \\  --version                    Show version
        \\
    );
}

fn writeUsageError(writer: anytype, comptime fmt: []const u8, args: anytype) !void {
    try writer.writeAll("error: ");
    try writer.print(fmt, args);
    try writer.writeAll("\n\n");
    try writeUsage(writer);
}

const TestWriter = struct {
    fn writeAll(_: *TestWriter, _: []const u8) !void {}
    fn print(_: *TestWriter, comptime _: []const u8, _: anytype) !void {}
};

test "CLI parses compile options" {
    const args = [_][:0]const u8{
        "zwgsl",
        "compile",
        "--target=glsl-es-300",
        "--stage",
        "fragment",
        "-o",
        "out.glsl",
        "shader.zw",
    };
    var stderr = TestWriter{};
    var stdout = TestWriter{};

    const parsed = try parseArgs(args[0..], &stderr, &stdout);
    const options = parsed.options;

    try std.testing.expectEqual(Command.compile, options.command);
    try std.testing.expectEqual(zwgsl.compiler.Target.glsl_es_300, options.target);
    try std.testing.expectEqual(Stage.fragment, options.stage);
    try std.testing.expectEqualStrings("out.glsl", options.output_path.?);
    try std.testing.expectEqualStrings("shader.zw", options.input_path);
}

test "CLI rejects check output path" {
    const args = [_][:0]const u8{
        "zwgsl",
        "check",
        "--output",
        "out.wgsl",
        "shader.zw",
    };
    var stderr = TestWriter{};
    var stdout = TestWriter{};

    const parsed = try parseArgs(args[0..], &stderr, &stdout);

    try std.testing.expectEqual(@as(u8, 2), parsed.exit_code);
}

test "CLI rejects unknown stage" {
    const args = [_][:0]const u8{
        "zwgsl",
        "compile",
        "--stage",
        "geometry",
        "shader.zw",
    };
    var stderr = TestWriter{};
    var stdout = TestWriter{};

    const parsed = try parseArgs(args[0..], &stderr, &stdout);

    try std.testing.expectEqual(@as(u8, 2), parsed.exit_code);
}

test "CLI diagnostics include source context" {
    const source =
        \\def main
        \\  color = 42
        \\end
    ;
    const errors = [_]zwgsl.compiler.Error{.{
        .kind = .semantic,
        .message = "undeclared identifier 'color'",
        .line = 2,
        .column = 3,
    }};

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try writeDiagnostics(
        output.writer(std.testing.allocator),
        "shader.zw",
        source,
        errors[0..],
    );

    try std.testing.expect(std.mem.indexOf(u8, output.items, "shader.zw:2:3: semantic: undeclared identifier 'color'") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "2 |   color = 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "   |   ^") != null);
}
