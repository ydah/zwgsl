const std = @import("std");
const string_pool = @import("string_pool.zig");
const token = @import("token.zig");

pub const Lexer = struct {
    source: []const u8,
    pos: u32,
    line: u32,
    column: u32,
    last_significant: ?token.TokenTag = null,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .column = 1,
        };
    }

    pub fn next(self: *Lexer) token.Token {
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            switch (ch) {
                ' ', '\t', '\r' => {
                    self.advanceChar();
                    continue;
                },
                '\n' => {
                    const start = self.pos;
                    const line = self.line;
                    const column = self.column;
                    self.advanceNewline();
                    if (self.shouldSkipNewline(start)) continue;
                    return .{
                        .tag = .newline,
                        .start = start,
                        .end = self.pos,
                        .line = line,
                        .column = column,
                    };
                },
                '#' => {
                    self.skipComment();
                    continue;
                },
                '"' => return self.lexString(),
                ':' => {
                    if (self.pos + 1 < self.source.len and isIdentifierStart(self.source[self.pos + 1])) {
                        return self.lexSymbol();
                    }
                    return self.lexSingle(.colon);
                },
                '(' => return self.lexSingle(.lparen),
                ')' => return self.lexSingle(.rparen),
                '[' => return self.lexSingle(.lbracket),
                ']' => return self.lexSingle(.rbracket),
                ',' => return self.lexSingle(.comma),
                '.' => return self.lexSingle(.dot),
                '|' => {
                    if (self.matchChar('|')) return self.lexTwo(.or_or);
                    return self.lexSingle(.pipe);
                },
                '+' => {
                    if (self.matchChar('=')) return self.lexTwo(.plus_assign);
                    return self.lexSingle(.plus);
                },
                '-' => {
                    if (self.matchChar('>')) return self.lexTwo(.arrow);
                    if (self.matchChar('=')) return self.lexTwo(.minus_assign);
                    return self.lexSingle(.minus);
                },
                '*' => {
                    if (self.matchChar('=')) return self.lexTwo(.star_assign);
                    return self.lexSingle(.star);
                },
                '/' => {
                    if (self.matchChar('=')) return self.lexTwo(.slash_assign);
                    return self.lexSingle(.slash);
                },
                '%' => return self.lexSingle(.percent),
                '=' => {
                    if (self.matchChar('=')) return self.lexTwo(.eq);
                    return self.lexSingle(.assign);
                },
                '!' => {
                    if (self.matchChar('=')) return self.lexTwo(.neq);
                    return self.lexSingle(.bang);
                },
                '<' => {
                    if (self.matchChar('=')) return self.lexTwo(.le);
                    return self.lexSingle(.lt);
                },
                '>' => {
                    if (self.matchChar('=')) return self.lexTwo(.ge);
                    return self.lexSingle(.gt);
                },
                '&' => {
                    if (self.matchChar('&')) return self.lexTwo(.and_and);
                    return self.lexInvalid();
                },
                '\\' => {
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '\n') {
                        self.advanceChar();
                        continue;
                    }
                    return self.lexInvalid();
                },
                else => {
                    if (std.ascii.isDigit(ch)) return self.lexNumber();
                    if (isIdentifierStart(ch)) return self.lexIdentifierOrKeyword();
                    return self.lexInvalid();
                },
            }
        }

        return .{
            .tag = .eof,
            .start = self.pos,
            .end = self.pos,
            .line = self.line,
            .column = self.column,
        };
    }

    pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) ![]token.Token {
        return tokenizeWithPool(allocator, null, source);
    }

    pub fn tokenizeWithPool(
        allocator: std.mem.Allocator,
        pool: ?*string_pool.StringPool,
        source: []const u8,
    ) ![]token.Token {
        var lexer = Lexer.init(source);
        var items: std.ArrayListUnmanaged(token.Token) = .{};
        defer items.deinit(allocator);

        while (true) {
            var item = lexer.next();
            if (pool) |active_pool| {
                item.interned = try internToken(active_pool, item, source);
            }
            try items.append(allocator, item);
            if (item.tag == .eof) break;
        }

        return try items.toOwnedSlice(allocator);
    }

    fn shouldSkipNewline(self: *Lexer, newline_pos: u32) bool {
        if (newline_pos > 0) {
            var cursor = newline_pos;
            while (cursor > 0) {
                cursor -= 1;
                const ch = self.source[cursor];
                if (ch == ' ' or ch == '\t' or ch == '\r') continue;
                if (ch == '\\') return true;
                break;
            }
        }

        return switch (self.last_significant orelse return false) {
            .plus,
            .minus,
            .star,
            .slash,
            .percent,
            .assign,
            .plus_assign,
            .minus_assign,
            .star_assign,
            .slash_assign,
            .comma,
            .lparen,
            .lbracket,
            .pipe,
            .arrow,
            .kw_do,
            => true,
            else => false,
        };
    }

    fn lexString(self: *Lexer) token.Token {
        const start = self.pos;
        const line = self.line;
        const column = self.column;
        self.advanceChar();

        while (self.pos < self.source.len and self.source[self.pos] != '"') {
            if (self.source[self.pos] == '\n') break;
            self.advanceChar();
        }

        if (self.pos < self.source.len and self.source[self.pos] == '"') {
            self.advanceChar();
        }

        return .{
            .tag = .string_literal,
            .start = start,
            .end = self.pos,
            .line = line,
            .column = column,
        };
    }

    fn lexNumber(self: *Lexer) token.Token {
        const start = self.pos;
        const line = self.line;
        const column = self.column;
        var saw_dot = false;

        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (std.ascii.isDigit(ch)) {
                self.advanceChar();
                continue;
            }
            if (ch == '.' and !saw_dot and self.pos + 1 < self.source.len and std.ascii.isDigit(self.source[self.pos + 1])) {
                saw_dot = true;
                self.advanceChar();
                continue;
            }
            break;
        }

        const kind: token.TokenTag = if (saw_dot) .float_literal else .integer_literal;
        self.last_significant = kind;
        return .{
            .tag = kind,
            .start = start,
            .end = self.pos,
            .line = line,
            .column = column,
        };
    }

    fn lexIdentifierOrKeyword(self: *Lexer) token.Token {
        const start = self.pos;
        const line = self.line;
        const column = self.column;

        while (self.pos < self.source.len and isIdentifierContinue(self.source[self.pos])) {
            self.advanceChar();
        }

        const lexeme = self.source[start..self.pos];
        const tag = token.keywordTag(lexeme) orelse token.TokenTag.identifier;
        self.last_significant = tag;
        return .{
            .tag = tag,
            .start = start,
            .end = self.pos,
            .line = line,
            .column = column,
        };
    }

    fn lexSymbol(self: *Lexer) token.Token {
        const start = self.pos;
        const line = self.line;
        const column = self.column;
        self.advanceChar();
        while (self.pos < self.source.len and isIdentifierContinue(self.source[self.pos])) {
            self.advanceChar();
        }
        self.last_significant = .symbol;
        return .{
            .tag = .symbol,
            .start = start,
            .end = self.pos,
            .line = line,
            .column = column,
        };
    }

    fn lexSingle(self: *Lexer, tag: token.TokenTag) token.Token {
        const start = self.pos;
        const line = self.line;
        const column = self.column;
        self.advanceChar();
        if (tag != .newline) self.last_significant = tag;
        return .{
            .tag = tag,
            .start = start,
            .end = self.pos,
            .line = line,
            .column = column,
        };
    }

    fn lexTwo(self: *Lexer, tag: token.TokenTag) token.Token {
        const start = self.pos;
        const line = self.line;
        const column = self.column;
        self.advanceChar();
        self.advanceChar();
        self.last_significant = tag;
        return .{
            .tag = tag,
            .start = start,
            .end = self.pos,
            .line = line,
            .column = column,
        };
    }

    fn lexInvalid(self: *Lexer) token.Token {
        const start = self.pos;
        const line = self.line;
        const column = self.column;
        self.advanceChar();
        return .{
            .tag = .invalid,
            .start = start,
            .end = self.pos,
            .line = line,
            .column = column,
        };
    }

    fn skipComment(self: *Lexer) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.advanceChar();
        }
    }

    fn advanceChar(self: *Lexer) void {
        self.pos += 1;
        self.column += 1;
    }

    fn advanceNewline(self: *Lexer) void {
        self.pos += 1;
        self.line += 1;
        self.column = 1;
    }

    fn matchChar(self: *Lexer, expected: u8) bool {
        return self.pos + 1 < self.source.len and self.source[self.pos + 1] == expected;
    }
};

fn internToken(
    pool: *string_pool.StringPool,
    item: token.Token,
    source: []const u8,
) !?[]const u8 {
    return switch (item.tag) {
        .identifier,
        .kw_def,
        .kw_end,
        .kw_do,
        .kw_if,
        .kw_elsif,
        .kw_else,
        .kw_unless,
        .kw_return,
        .kw_vertex,
        .kw_fragment,
        .kw_compute,
        .kw_uniform,
        .kw_input,
        .kw_output,
        .kw_varying,
        .kw_struct,
        .kw_true,
        .kw_false,
        .kw_inout,
        .kw_self,
        .kw_discard,
        .kw_version,
        .kw_precision,
        .kw_pipeline,
        .kw_nil,
        => try pool.intern(item.lexeme(source)),
        .symbol => try pool.intern(item.lexeme(source)[1..]),
        else => null,
    };
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentifierContinue(ch: u8) bool {
    return isIdentifierStart(ch) or std.ascii.isDigit(ch);
}
