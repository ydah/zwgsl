const std = @import("std");
const token = @import("token.zig");

pub const LayoutResolver = struct {
    tokens: []const token.Token,
    index: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        raw_tokens: []const token.Token,
    ) !LayoutResolver {
        _ = source;
        return .{
            .tokens = try tokenize(allocator, raw_tokens),
        };
    }

    pub fn deinit(self: *LayoutResolver, allocator: std.mem.Allocator) void {
        allocator.free(self.tokens);
        self.* = undefined;
    }

    pub fn next(self: *LayoutResolver) token.Token {
        const item = self.tokens[self.index];
        if (self.index + 1 < self.tokens.len) {
            self.index += 1;
        }
        return item;
    }

    pub fn tokenize(
        allocator: std.mem.Allocator,
        raw_tokens: []const token.Token,
    ) ![]token.Token {
        var resolved: std.ArrayListUnmanaged(token.Token) = .{};
        defer resolved.deinit(allocator);

        var indent_stack: std.ArrayListUnmanaged(u32) = .{};
        defer indent_stack.deinit(allocator);
        try indent_stack.append(allocator, 0);

        var previous_line_had_code = false;
        var line_has_code = false;
        var line_opens_block = false;
        var pending_indent_after_block = false;
        var at_line_start = true;

        for (raw_tokens) |item| {
            switch (item.tag) {
                .newline => {
                    try resolved.append(allocator, item);
                    if (line_has_code) {
                        previous_line_had_code = true;
                        pending_indent_after_block = line_opens_block;
                    }
                    at_line_start = true;
                    line_has_code = false;
                    line_opens_block = false;
                },
                .eof => {
                    while (indent_stack.items.len > 1) {
                        _ = indent_stack.pop();
                        try resolved.append(allocator, makeVirtual(.virtual_dedent, item));
                    }
                    try resolved.append(allocator, item);
                },
                else => {
                    if (at_line_start) {
                        try appendLinePrefix(
                            allocator,
                            &resolved,
                            &indent_stack,
                            item,
                            previous_line_had_code,
                            pending_indent_after_block,
                        );
                        pending_indent_after_block = false;
                        at_line_start = false;
                    }

                    line_has_code = true;
                    if (startsIndentedBlock(item.tag) or item.tag == .kw_do) {
                        line_opens_block = true;
                    }

                    try resolved.append(allocator, item);
                },
            }
        }

        return try resolved.toOwnedSlice(allocator);
    }
};

fn appendLinePrefix(
    allocator: std.mem.Allocator,
    resolved: *std.ArrayListUnmanaged(token.Token),
    indent_stack: *std.ArrayListUnmanaged(u32),
    item: token.Token,
    previous_line_had_code: bool,
    pending_indent_after_block: bool,
) !void {
    const indent = item.column - 1;
    const current_indent = indent_stack.items[indent_stack.items.len - 1];

    if (pending_indent_after_block and item.tag != .kw_end) {
        if (indent <= current_indent) {
            try resolved.append(allocator, makeInvalid(item));
            return;
        }
        try indent_stack.append(allocator, indent);
        try resolved.append(allocator, makeVirtual(.virtual_indent, item));
        return;
    }

    if (indent > current_indent) {
        try resolved.append(allocator, makeInvalid(item));
        return;
    }

    var top = indent_stack.items[indent_stack.items.len - 1];
    while (indent < top and indent_stack.items.len > 1) {
        _ = indent_stack.pop();
        try resolved.append(allocator, makeVirtual(.virtual_dedent, item));
        top = indent_stack.items[indent_stack.items.len - 1];
    }

    if (indent != top) {
        try resolved.append(allocator, makeInvalid(item));
        return;
    }

    if (previous_line_had_code and !suppressesVirtualSemi(item.tag)) {
        try resolved.append(allocator, makeVirtual(.virtual_semi, item));
    }
}

fn startsIndentedBlock(tag: token.TokenTag) bool {
    return switch (tag) {
        .kw_def,
        .kw_if,
        .kw_unless,
        .kw_elsif,
        .kw_else,
        .kw_struct,
        .kw_where,
        .kw_type,
        .kw_when,
        .kw_trait,
        .kw_impl,
        => true,
        else => false,
    };
}

fn suppressesVirtualSemi(tag: token.TokenTag) bool {
    return switch (tag) {
        .kw_end,
        .kw_else,
        .kw_elsif,
        .kw_where,
        .kw_when,
        => true,
        else => false,
    };
}

fn makeVirtual(tag: token.TokenTag, anchor: token.Token) token.Token {
    return .{
        .tag = tag,
        .start = anchor.start,
        .end = anchor.start,
        .line = anchor.line,
        .column = anchor.column,
    };
}

fn makeInvalid(anchor: token.Token) token.Token {
    return .{
        .tag = .invalid,
        .start = anchor.start,
        .end = anchor.start,
        .line = anchor.line,
        .column = anchor.column,
    };
}
