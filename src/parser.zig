const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const token = @import("token.zig");

pub const ParseError = error{ParseFailed};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const token.Token,
    index: usize = 0,
    diagnostics: *diagnostics.DiagnosticList,

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        tokens: []const token.Token,
        diagnostic_list: *diagnostics.DiagnosticList,
    ) Parser {
        return .{
            .allocator = allocator,
            .source = source,
            .tokens = tokens,
            .diagnostics = diagnostic_list,
        };
    }

    pub fn parseProgram(self: *Parser) anyerror!*ast.Program {
        var items: std.ArrayListUnmanaged(ast.Item) = .{};
        defer items.deinit(self.allocator);

        self.consumeNewlines();
        while (!self.isAtEnd()) {
            const item = self.parseTopLevelItem() catch |err| switch (err) {
                error.ParseFailed => {
                    self.synchronize();
                    self.consumeNewlines();
                    continue;
                },
                else => return err,
            };
            try items.append(self.allocator, item);
            self.consumeNewlines();
        }

        const program = try self.allocator.create(ast.Program);
        program.* = .{
            .items = try items.toOwnedSlice(self.allocator),
        };
        return program;
    }

    fn parseTopLevelItem(self: *Parser) anyerror!ast.Item {
        return switch (self.current().tag) {
            .kw_version => .{ .version = try self.parseVersionDecl() },
            .kw_precision => .{ .precision = try self.parsePrecisionDecl() },
            .kw_uniform => .{ .uniform = try self.parseUniformDecl() },
            .kw_struct => .{ .struct_def = try self.parseStructDef() },
            .kw_def => .{ .function = try self.parseFunctionDef() },
            .kw_vertex, .kw_fragment, .kw_compute => .{ .shader_block = try self.parseShaderBlock() },
            else => {
                const tok = self.current();
                try self.reportUnexpected(tok, "top-level declaration");
                return error.ParseFailed;
            },
        };
    }

    fn parseVersionDecl(self: *Parser) anyerror!ast.VersionDecl {
        const start = try self.expect(.kw_version, "version");
        const value_tok = try self.expect(.string_literal, "version string");
        return .{
            .position = positionOf(start),
            .value = unquote(value_tok.lexeme(self.source)),
        };
    }

    fn parsePrecisionDecl(self: *Parser) anyerror!ast.PrecisionDecl {
        const start = try self.expect(.kw_precision, "precision");
        const stage = try self.parseSymbolName("precision stage");
        _ = try self.expect(.comma, "',' after precision stage");
        const precision = try self.parseSymbolName("precision level");
        return .{
            .position = positionOf(start),
            .stage = stage,
            .precision = precision,
        };
    }

    fn parseUniformDecl(self: *Parser) anyerror!ast.UniformDecl {
        const start = try self.expect(.kw_uniform, "uniform");
        const name = try self.parseSymbolName("uniform name");
        _ = try self.expect(.comma, "',' after uniform name");
        const type_name = try self.expectIdentifier("uniform type");
        return .{
            .position = positionOf(start),
            .name = name,
            .type_name = type_name,
        };
    }

    fn parseStructDef(self: *Parser) anyerror!ast.StructDef {
        const start = try self.expect(.kw_struct, "struct");
        const name = try self.expectIdentifier("struct name");
        self.consumeNewlines();

        var fields: std.ArrayListUnmanaged(ast.StructField) = .{};
        defer fields.deinit(self.allocator);

        while (!self.check(.kw_end) and !self.isAtEnd()) {
            const field_name_tok = try self.expect(.identifier, "struct field name");
            _ = try self.expect(.colon, "':' after field name");
            const type_name = try self.expectIdentifier("field type");
            try fields.append(self.allocator, .{
                .position = positionOf(field_name_tok),
                .name = field_name_tok.lexeme(self.source),
                .type_name = type_name,
            });
            self.consumeNewlines();
        }

        _ = try self.expect(.kw_end, "'end' to close struct");
        return .{
            .position = positionOf(start),
            .name = name,
            .fields = try fields.toOwnedSlice(self.allocator),
        };
    }

    fn parseShaderBlock(self: *Parser) anyerror!*ast.ShaderBlock {
        const start = self.advance();
        const stage = switch (start.tag) {
            .kw_vertex => ast.Stage.vertex,
            .kw_fragment => ast.Stage.fragment,
            .kw_compute => ast.Stage.compute,
            else => unreachable,
        };
        _ = try self.expect(.kw_do, "'do' after shader stage");
        self.consumeNewlines();

        var items: std.ArrayListUnmanaged(ast.StageItem) = .{};
        defer items.deinit(self.allocator);

        while (!self.check(.kw_end) and !self.isAtEnd()) {
            const item = switch (self.current().tag) {
                .kw_input => ast.StageItem{ .input = try self.parseIoDecl(.kw_input) },
                .kw_output => ast.StageItem{ .output = try self.parseIoDecl(.kw_output) },
                .kw_varying => ast.StageItem{ .varying = try self.parseIoDecl(.kw_varying) },
                .kw_precision => ast.StageItem{ .precision = try self.parsePrecisionDecl() },
                .kw_def => ast.StageItem{ .function = try self.parseFunctionDef() },
                else => {
                    try self.reportUnexpected(self.current(), "shader block item");
                    return error.ParseFailed;
                },
            };
            try items.append(self.allocator, item);
            self.consumeNewlines();
        }

        _ = try self.expect(.kw_end, "'end' to close shader block");
        const block = try self.allocator.create(ast.ShaderBlock);
        block.* = .{
            .position = positionOf(start),
            .stage = stage,
            .items = try items.toOwnedSlice(self.allocator),
        };
        return block;
    }

    fn parseIoDecl(self: *Parser, kind: token.TokenTag) anyerror!ast.IoDecl {
        const start = try self.expect(kind, "shader I/O declaration");
        const name = try self.parseSymbolName("shader variable name");
        _ = try self.expect(.comma, "',' after shader variable name");
        const type_name = try self.expectIdentifier("shader variable type");
        var location: ?u32 = null;

        while (self.match(.comma)) {
            const option_name = try self.expectIdentifier("option name");
            _ = try self.expect(.colon, "':' after option name");
            if (std.mem.eql(u8, option_name, "location")) {
                const literal = try self.expect(.integer_literal, "location integer");
                location = try std.fmt.parseInt(u32, literal.lexeme(self.source), 10);
            } else {
                try self.diagnostics.appendFmt(
                    .@"error",
                    self.previous().line,
                    self.previous().column,
                    "unsupported declaration option '{s}'",
                    .{option_name},
                );
                return error.ParseFailed;
            }
        }

        return .{
            .position = positionOf(start),
            .name = name,
            .type_name = type_name,
            .location = location,
        };
    }

    fn parseFunctionDef(self: *Parser) anyerror!*ast.FunctionDef {
        const start = try self.expect(.kw_def, "function definition");
        const name = try self.expectIdentifier("function name");
        var params: std.ArrayListUnmanaged(ast.Param) = .{};
        defer params.deinit(self.allocator);

        if (self.match(.lparen)) {
            if (!self.check(.rparen)) {
                while (true) {
                    try params.append(self.allocator, try self.parseParam());
                    if (!self.match(.comma)) break;
                }
            }
            _ = try self.expect(.rparen, "')' after parameters");
        }

        var return_type: ?[]const u8 = null;
        if (self.match(.arrow)) {
            return_type = try self.expectIdentifier("return type");
        }

        self.consumeNewlines();
        const body = try self.parseStatementList(&.{.kw_end});
        _ = try self.expect(.kw_end, "'end' to close function");

        const function = try self.allocator.create(ast.FunctionDef);
        function.* = .{
            .position = positionOf(start),
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .body = body,
        };
        return function;
    }

    fn parseParam(self: *Parser) anyerror!ast.Param {
        const start = self.current();
        const is_inout = self.match(.kw_inout);
        const name = try self.expectIdentifier("parameter name");
        _ = try self.expect(.colon, "':' after parameter name");
        const type_name = try self.expectIdentifier("parameter type");
        return .{
            .position = positionOf(start),
            .name = name,
            .type_name = type_name,
            .is_inout = is_inout,
        };
    }

    fn parseStatementList(self: *Parser, end_tags: []const token.TokenTag) anyerror![]const *ast.Stmt {
        var statements: std.ArrayListUnmanaged(*ast.Stmt) = .{};
        defer statements.deinit(self.allocator);

        self.consumeNewlines();
        while (!self.isAtEnd() and !self.currentIsOneOf(end_tags)) {
            const statement = self.parseStatement() catch |err| switch (err) {
                error.ParseFailed => {
                    self.synchronize();
                    self.consumeNewlines();
                    continue;
                },
                else => return err,
            };
            try statements.append(self.allocator, statement);
            self.consumeNewlines();
        }

        return try statements.toOwnedSlice(self.allocator);
    }

    fn parseStatement(self: *Parser) anyerror!*ast.Stmt {
        const base_statement = switch (self.current().tag) {
            .kw_if => try self.parseIfStatement(false),
            .kw_unless => try self.parseIfStatement(true),
            .kw_return => try self.parseReturnStatement(),
            .kw_discard => try self.parseDiscardStatement(),
            else => try self.parseSimpleStatement(),
        };

        if (self.match(.kw_if)) {
            const condition = try self.parseExpression(0);
            return try self.makeStmt(base_statement.position, .{
                .conditional = .{
                    .condition = condition,
                    .body = base_statement,
                    .negate = false,
                },
            });
        }

        if (self.match(.kw_unless)) {
            const condition = try self.parseExpression(0);
            return try self.makeStmt(base_statement.position, .{
                .conditional = .{
                    .condition = condition,
                    .body = base_statement,
                    .negate = true,
                },
            });
        }

        return base_statement;
    }

    fn parseIfStatement(self: *Parser, negate_first: bool) anyerror!*ast.Stmt {
        const start = self.advance();
        const condition = try self.parseExpression(0);
        self.consumeNewlines();

        var branches: std.ArrayListUnmanaged(ast.Branch) = .{};
        defer branches.deinit(self.allocator);
        try branches.append(self.allocator, .{
            .condition = condition,
            .body = try self.parseStatementList(&.{ .kw_elsif, .kw_else, .kw_end }),
        });

        while (self.match(.kw_elsif)) {
            const elsif_condition = try self.parseExpression(0);
            self.consumeNewlines();
            try branches.append(self.allocator, .{
                .condition = elsif_condition,
                .body = try self.parseStatementList(&.{ .kw_elsif, .kw_else, .kw_end }),
            });
        }

        var else_body: []const *ast.Stmt = &.{};
        if (self.match(.kw_else)) {
            self.consumeNewlines();
            else_body = try self.parseStatementList(&.{.kw_end});
        }

        _ = try self.expect(.kw_end, "'end' to close conditional");
        return try self.makeStmt(positionOf(start), .{
            .if_stmt = .{
                .branches = try branches.toOwnedSlice(self.allocator),
                .else_body = else_body,
                .negate_first = negate_first,
            },
        });
    }

    fn parseReturnStatement(self: *Parser) anyerror!*ast.Stmt {
        const start = try self.expect(.kw_return, "return");
        const value: ?*ast.Expr = if (self.check(.newline) or self.currentIsOneOf(&.{ .kw_end, .kw_else, .kw_elsif, .eof }))
            null
        else
            try self.parseExpression(0);
        return try self.makeStmt(positionOf(start), .{ .return_stmt = value });
    }

    fn parseDiscardStatement(self: *Parser) anyerror!*ast.Stmt {
        const start = try self.expect(.kw_discard, "discard");
        return try self.makeStmt(positionOf(start), .{ .discard = {} });
    }

    fn parseSimpleStatement(self: *Parser) anyerror!*ast.Stmt {
        if (self.looksLikeTypedAssignment()) {
            const name_tok = try self.expect(.identifier, "typed assignment name");
            _ = try self.expect(.colon, "':' after variable name");
            const type_name = try self.expectIdentifier("typed assignment type");
            _ = try self.expect(.assign, "'=' after type annotation");
            const value = try self.parseExpression(0);
            return try self.makeStmt(positionOf(name_tok), .{
                .typed_assignment = .{
                    .name = name_tok.lexeme(self.source),
                    .type_name = type_name,
                    .value = value,
                },
            });
        }

        const expr = try self.parseExpression(0);

        if (self.currentIsAssignmentOperator()) {
            const operator = self.advance().tag;
            const value = try self.parseExpression(0);
            return try self.makeStmt(expr.position, .{
                .assignment = .{
                    .target = expr,
                    .operator = operator,
                    .value = value,
                },
            });
        }

        if (self.check(.kw_do)) {
            if (expr.data == .member) {
                const member = expr.data.member;
                if (std.mem.eql(u8, member.name, "times")) {
                    return try self.parseLoopStatement(expr.position, true, member.target);
                }
                if (std.mem.eql(u8, member.name, "each")) {
                    return try self.parseLoopStatement(expr.position, false, member.target);
                }
            }
        }

        return try self.makeStmt(expr.position, .{ .expression = expr });
    }

    fn parseLoopStatement(self: *Parser, position: ast.Position, is_times: bool, receiver: *ast.Expr) anyerror!*ast.Stmt {
        _ = try self.expect(.kw_do, "'do' to start loop body");
        var binding: ?[]const u8 = null;
        if (self.match(.pipe)) {
            binding = try self.expectIdentifier("loop binding");
            _ = try self.expect(.pipe, "'|' to close loop binding");
        }
        self.consumeNewlines();
        const body = try self.parseStatementList(&.{.kw_end});
        _ = try self.expect(.kw_end, "'end' to close loop");

        return if (is_times)
            try self.makeStmt(position, .{
                .times_loop = .{
                    .count = receiver,
                    .binding = binding,
                    .body = body,
                },
            })
        else
            try self.makeStmt(position, .{
                .each_loop = .{
                    .collection = receiver,
                    .binding = binding,
                    .body = body,
                },
            });
    }

    fn parseExpression(self: *Parser, min_precedence: u8) anyerror!*ast.Expr {
        var expr = try self.parsePrefix();

        while (true) {
            if (self.check(.dot)) {
                const precedence: u8 = 8;
                if (precedence < min_precedence) break;
                _ = self.advance();
                const member_name_tok = try self.expect(.identifier, "member name");
                expr = try self.makeExpr(positionOf(member_name_tok), .{
                    .member = .{
                        .target = expr,
                        .name = member_name_tok.lexeme(self.source),
                    },
                });
                continue;
            }

            if (self.check(.lparen)) {
                const precedence: u8 = 8;
                if (precedence < min_precedence) break;
                expr = try self.finishCall(expr);
                continue;
            }

            if (self.check(.lbracket)) {
                const precedence: u8 = 8;
                if (precedence < min_precedence) break;
                expr = try self.finishIndex(expr);
                continue;
            }

            const precedence = self.binaryPrecedence(self.current().tag) orelse break;
            if (precedence < min_precedence) break;

            const operator = self.advance();
            const rhs = try self.parseExpression(precedence + 1);
            expr = try self.makeExpr(positionOf(operator), .{
                .binary = .{
                    .operator = operator.tag,
                    .lhs = expr,
                    .rhs = rhs,
                },
            });
        }

        return expr;
    }

    fn parsePrefix(self: *Parser) anyerror!*ast.Expr {
        const tok = self.current();
        switch (tok.tag) {
            .integer_literal => {
                _ = self.advance();
                return self.makeExpr(positionOf(tok), .{
                    .integer = try std.fmt.parseInt(i64, tok.lexeme(self.source), 10),
                });
            },
            .float_literal => {
                _ = self.advance();
                return self.makeExpr(positionOf(tok), .{
                    .float = try std.fmt.parseFloat(f64, tok.lexeme(self.source)),
                });
            },
            .string_literal => {
                _ = self.advance();
                return self.makeExpr(positionOf(tok), .{
                    .string = unquote(tok.lexeme(self.source)),
                });
            },
            .symbol => {
                _ = self.advance();
                return self.makeExpr(positionOf(tok), .{
                    .symbol = tok.lexeme(self.source)[1..],
                });
            },
            .identifier => {
                _ = self.advance();
                return self.makeExpr(positionOf(tok), .{
                    .identifier = tok.lexeme(self.source),
                });
            },
            .kw_true => {
                _ = self.advance();
                return self.makeExpr(positionOf(tok), .{ .bool = true });
            },
            .kw_false => {
                _ = self.advance();
                return self.makeExpr(positionOf(tok), .{ .bool = false });
            },
            .kw_self => {
                _ = self.advance();
                return self.makeExpr(positionOf(tok), .{ .self_ref = {} });
            },
            .minus, .bang => {
                _ = self.advance();
                const operand = try self.parseExpression(7);
                return self.makeExpr(positionOf(tok), .{
                    .unary = .{
                        .operator = tok.tag,
                        .operand = operand,
                    },
                });
            },
            .lparen => {
                _ = self.advance();
                const expr = try self.parseExpression(0);
                _ = try self.expect(.rparen, "')' after expression");
                return expr;
            },
            else => {
                try self.reportUnexpected(tok, "expression");
                return error.ParseFailed;
            },
        }
    }

    fn finishCall(self: *Parser, callee: *ast.Expr) anyerror!*ast.Expr {
        const start = try self.expect(.lparen, "'(' to start argument list");
        var args: std.ArrayListUnmanaged(*ast.Expr) = .{};
        defer args.deinit(self.allocator);

        if (!self.check(.rparen)) {
            while (true) {
                try args.append(self.allocator, try self.parseExpression(0));
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.expect(.rparen, "')' after arguments");

        return try self.makeExpr(positionOf(start), .{
            .call = .{
                .callee = callee,
                .args = try args.toOwnedSlice(self.allocator),
            },
        });
    }

    fn finishIndex(self: *Parser, target: *ast.Expr) anyerror!*ast.Expr {
        const start = try self.expect(.lbracket, "'[' to start index expression");
        const index_expr = try self.parseExpression(0);
        _ = try self.expect(.rbracket, "']' after index expression");
        return try self.makeExpr(positionOf(start), .{
            .index = .{
                .target = target,
                .index = index_expr,
            },
        });
    }

    fn binaryPrecedence(_: *Parser, tag: token.TokenTag) ?u8 {
        return switch (tag) {
            .or_or => 1,
            .and_and => 2,
            .eq, .neq => 3,
            .lt, .gt, .le, .ge => 4,
            .plus, .minus => 5,
            .star, .slash, .percent => 6,
            else => null,
        };
    }

    fn makeExpr(self: *Parser, position: ast.Position, data: ast.Expr.Data) anyerror!*ast.Expr {
        const expr = try self.allocator.create(ast.Expr);
        expr.* = .{
            .position = position,
            .data = data,
        };
        return expr;
    }

    fn makeStmt(self: *Parser, position: ast.Position, data: ast.Stmt.Data) anyerror!*ast.Stmt {
        const stmt = try self.allocator.create(ast.Stmt);
        stmt.* = .{
            .position = position,
            .data = data,
        };
        return stmt;
    }

    fn parseSymbolName(self: *Parser, label: []const u8) anyerror![]const u8 {
        const symbol_tok = try self.expect(.symbol, label);
        return symbol_tok.lexeme(self.source)[1..];
    }

    fn expectIdentifier(self: *Parser, what: []const u8) anyerror![]const u8 {
        const ident = try self.expect(.identifier, what);
        return ident.lexeme(self.source);
    }

    fn expect(self: *Parser, tag: token.TokenTag, what: []const u8) anyerror!token.Token {
        const tok = self.current();
        if (tok.tag == tag) {
            return self.advance();
        }
        try self.diagnostics.appendFmt(
            .@"error",
            tok.line,
            tok.column,
            "expected {s}, found {s}",
            .{ what, @tagName(tok.tag) },
        );
        return error.ParseFailed;
    }

    fn reportUnexpected(self: *Parser, tok: token.Token, what: []const u8) anyerror!void {
        try self.diagnostics.appendFmt(
            .@"error",
            tok.line,
            tok.column,
            "expected {s}, found {s}",
            .{ what, @tagName(tok.tag) },
        );
    }

    fn current(self: *Parser) token.Token {
        return self.tokens[self.index];
    }

    fn previous(self: *Parser) token.Token {
        return self.tokens[self.index - 1];
    }

    fn advance(self: *Parser) token.Token {
        const tok = self.tokens[self.index];
        if (self.index + 1 < self.tokens.len) {
            self.index += 1;
        }
        return tok;
    }

    fn match(self: *Parser, tag: token.TokenTag) bool {
        if (!self.check(tag)) return false;
        _ = self.advance();
        return true;
    }

    fn check(self: *Parser, tag: token.TokenTag) bool {
        return self.current().tag == tag;
    }

    fn currentIsOneOf(self: *Parser, tags: []const token.TokenTag) bool {
        for (tags) |tag| {
            if (self.check(tag)) return true;
        }
        return false;
    }

    fn consumeNewlines(self: *Parser) void {
        while (self.match(.newline)) {}
    }

    fn isAtEnd(self: *Parser) bool {
        return self.check(.eof);
    }

    fn currentIsAssignmentOperator(self: *Parser) bool {
        return switch (self.current().tag) {
            .assign, .plus_assign, .minus_assign, .star_assign, .slash_assign => true,
            else => false,
        };
    }

    fn looksLikeTypedAssignment(self: *Parser) bool {
        return self.peek(0) == .identifier and
            self.peek(1) == .colon and
            self.peek(2) == .identifier and
            self.peek(3) == .assign;
    }

    fn peek(self: *Parser, offset: usize) token.TokenTag {
        const target = self.index + offset;
        if (target >= self.tokens.len) return .eof;
        return self.tokens[target].tag;
    }

    fn synchronize(self: *Parser) void {
        while (!self.isAtEnd()) {
            if (self.match(.newline)) return;
            if (self.check(.kw_end) or self.check(.kw_else) or self.check(.kw_elsif)) return;
            _ = self.advance();
        }
    }
};

fn positionOf(tok: token.Token) ast.Position {
    return .{
        .line = tok.line,
        .column = tok.column,
    };
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}
