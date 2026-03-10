const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const string_pool = @import("string_pool.zig");
const token = @import("token.zig");

pub const ParseError = error{ParseFailed};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const token.Token,
    index: usize = 0,
    diagnostics: *diagnostics.DiagnosticList,
    pool: ?*string_pool.StringPool = null,

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

    pub fn initWithPool(
        allocator: std.mem.Allocator,
        pool: *string_pool.StringPool,
        source: []const u8,
        tokens: []const token.Token,
        diagnostic_list: *diagnostics.DiagnosticList,
    ) Parser {
        var parser = init(allocator, source, tokens, diagnostic_list);
        parser.pool = pool;
        return parser;
    }

    pub fn parseProgram(self: *Parser) anyerror!*ast.Program {
        var items: std.ArrayListUnmanaged(ast.Item) = .{};
        defer items.deinit(self.allocator);

        self.consumeNewlines();
        while (!self.isAtEnd()) {
            const item = self.parseTopLevelItem() catch |err| switch (err) {
                error.ParseFailed => {
                    const before = self.index;
                    self.synchronize();
                    if (self.index == before and !self.isAtEnd()) {
                        _ = self.advance();
                    }
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
            .kw_type => .{ .type_def = try self.parseTypeDef() },
            .kw_trait => .{ .trait_def = try self.parseTraitDef() },
            .kw_impl => .{ .impl_def = try self.parseImplDef() },
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
        const type_name = try self.expectTypeSpec("uniform type");
        return .{
            .position = positionOf(start),
            .name = name,
            .type_name = type_name,
        };
    }

    fn parseStructDef(self: *Parser) anyerror!ast.StructDef {
        const start = try self.expect(.kw_struct, "struct");
        const name = try self.expectIdentifier("struct name");
        var params: std.ArrayListUnmanaged([]const u8) = .{};
        defer params.deinit(self.allocator);
        if (self.match(.lparen)) {
            if (!self.check(.rparen)) {
                while (true) {
                    try params.append(self.allocator, try self.expectIdentifier("type parameter"));
                    if (!self.match(.comma)) break;
                }
            }
            _ = try self.expect(.rparen, "')' after struct parameters");
        }
        self.consumeNewlines();

        var fields: std.ArrayListUnmanaged(ast.StructField) = .{};
        defer fields.deinit(self.allocator);

        while (!self.check(.kw_end) and !self.isAtEnd()) {
            const field_name_tok = try self.expect(.identifier, "struct field name");
            _ = try self.expect(.colon, "':' after field name");
            const type_name = try self.expectTypeSpec("field type");
            try fields.append(self.allocator, .{
                .position = positionOf(field_name_tok),
                .name = try self.identifierValue(field_name_tok),
                .type_name = type_name,
            });
            self.consumeNewlines();
        }

        _ = try self.expect(.kw_end, "'end' to close struct");
        return .{
            .position = positionOf(start),
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
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
        const type_name = try self.expectTypeSpec("shader variable type");
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
            return_type = try self.expectTypeSpec("return type");
        }
        const constraints = if (self.check(.kw_where))
            try self.parseTypeConstraints()
        else
            &.{};

        self.consumeNewlines();
        const body = try self.parseStatementList(&.{ .kw_where, .kw_end });
        const where_clause = if (self.check(.kw_where))
            try self.parseWhereClause()
        else
            null;
        _ = try self.expect(.kw_end, "'end' to close function");

        const function = try self.allocator.create(ast.FunctionDef);
        function.* = .{
            .position = positionOf(start),
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .constraints = constraints,
            .body = body,
            .where_clause = where_clause,
        };
        return function;
    }

    fn parseTypeConstraints(self: *Parser) anyerror![]const ast.TypeConstraint {
        _ = try self.expect(.kw_where, "type constraint");
        var constraints: std.ArrayListUnmanaged(ast.TypeConstraint) = .{};
        defer constraints.deinit(self.allocator);

        while (true) {
            const start = self.current();
            const param_name = try self.expectIdentifier("constraint type parameter");
            _ = try self.expect(.colon, "':' after type parameter");
            const trait_name = try self.expectIdentifier("trait name");
            try constraints.append(self.allocator, .{
                .position = positionOf(start),
                .param_name = param_name,
                .trait_name = trait_name,
            });
            if (!self.match(.comma)) break;
        }

        return try constraints.toOwnedSlice(self.allocator);
    }

    fn parseTypeDef(self: *Parser) anyerror!ast.TypeDef {
        const start = try self.expect(.kw_type, "type definition");
        const name = try self.expectIdentifier("type name");
        var params: std.ArrayListUnmanaged([]const u8) = .{};
        defer params.deinit(self.allocator);
        if (self.match(.lparen)) {
            if (!self.check(.rparen)) {
                while (true) {
                    try params.append(self.allocator, try self.expectIdentifier("type parameter"));
                    if (!self.match(.comma)) break;
                }
            }
            _ = try self.expect(.rparen, "')' after type parameters");
        }

        var variants: std.ArrayListUnmanaged(ast.Variant) = .{};
        defer variants.deinit(self.allocator);

        self.consumeNewlines();
        while (!self.isAtEnd() and !self.check(.kw_end)) {
            try variants.append(self.allocator, try self.parseVariant());
            self.consumeNewlines();
        }

        _ = try self.expect(.kw_end, "'end' to close type definition");
        return .{
            .position = positionOf(start),
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .variants = try variants.toOwnedSlice(self.allocator),
        };
    }

    fn parseVariant(self: *Parser) anyerror!ast.Variant {
        const start = self.current();
        const name = try self.expectIdentifier("variant name");
        var fields: std.ArrayListUnmanaged(ast.VariantField) = .{};
        defer fields.deinit(self.allocator);

        if (self.match(.lparen)) {
            if (!self.check(.rparen)) {
                while (true) {
                    const field_start = self.current();
                    const field_name = try self.expectIdentifier("variant field name");
                    _ = try self.expect(.colon, "':' after variant field");
                    const type_name = try self.expectTypeSpec("variant field type");
                    try fields.append(self.allocator, .{
                        .position = positionOf(field_start),
                        .name = field_name,
                        .type_name = type_name,
                    });
                    if (!self.match(.comma)) break;
                }
            }
            _ = try self.expect(.rparen, "')' after variant fields");
        }

        return .{
            .position = positionOf(start),
            .name = name,
            .fields = try fields.toOwnedSlice(self.allocator),
        };
    }

    fn parseWhereClause(self: *Parser) anyerror!ast.WhereClause {
        const start = try self.expect(.kw_where, "where clause");
        var bindings: std.ArrayListUnmanaged(ast.LetBinding) = .{};
        defer bindings.deinit(self.allocator);

        self.consumeNewlines();
        while (!self.isAtEnd() and !self.check(.kw_end)) {
            try bindings.append(self.allocator, try self.parseWhereBinding());
            self.consumeNewlines();
        }

        return .{
            .position = positionOf(start),
            .bindings = try bindings.toOwnedSlice(self.allocator),
        };
    }

    fn parseTraitDef(self: *Parser) anyerror!ast.TraitDef {
        const start = try self.expect(.kw_trait, "trait definition");
        const name = try self.expectIdentifier("trait name");
        self.consumeNewlines();

        var methods: std.ArrayListUnmanaged(*ast.FunctionDef) = .{};
        defer methods.deinit(self.allocator);

        while (!self.isAtEnd() and !self.check(.kw_end)) {
            try methods.append(self.allocator, try self.parseTraitMethod());
            self.consumeNewlines();
        }

        _ = try self.expect(.kw_end, "'end' to close trait");
        return .{
            .position = positionOf(start),
            .name = name,
            .methods = try methods.toOwnedSlice(self.allocator),
        };
    }

    fn parseTraitMethod(self: *Parser) anyerror!*ast.FunctionDef {
        const start = try self.expect(.kw_def, "trait method");
        const name = try self.expectIdentifier("trait method name");
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
            return_type = try self.expectTypeSpec("return type");
        }

        const constraints = if (self.check(.kw_where))
            try self.parseTypeConstraints()
        else
            &.{};
        _ = try self.expect(.kw_end, "'end' to close trait method");

        const function = try self.allocator.create(ast.FunctionDef);
        function.* = .{
            .position = positionOf(start),
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .constraints = constraints,
            .body = &.{},
            .where_clause = null,
        };
        return function;
    }

    fn parseImplDef(self: *Parser) anyerror!ast.ImplDef {
        const start = try self.expect(.kw_impl, "impl definition");
        const trait_name = try self.expectIdentifier("trait name");
        _ = try self.expect(.kw_for, "'for' after trait name");
        const for_type_name = try self.expectTypeSpec("impl target type");
        self.consumeNewlines();

        var methods: std.ArrayListUnmanaged(*ast.FunctionDef) = .{};
        defer methods.deinit(self.allocator);

        while (!self.isAtEnd() and !self.check(.kw_end)) {
            try methods.append(self.allocator, try self.parseFunctionDef());
            self.consumeNewlines();
        }

        _ = try self.expect(.kw_end, "'end' to close impl");
        return .{
            .position = positionOf(start),
            .trait_name = trait_name,
            .for_type_name = for_type_name,
            .methods = try methods.toOwnedSlice(self.allocator),
        };
    }

    fn parseParam(self: *Parser) anyerror!ast.Param {
        const start = self.current();
        const is_inout = self.match(.kw_inout);
        const name = try self.expectIdentifier("parameter name");
        _ = try self.expect(.colon, "':' after parameter name");
        const type_name = try self.expectTypeSpec("parameter type");
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
            .kw_let => try self.parseLetStatement(),
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
        const value: ?*ast.Expr = if (self.currentStartsBoundary())
            null
        else
            try self.parseExpression(0);
        return try self.makeStmt(positionOf(start), .{ .return_stmt = value });
    }

    fn parseDiscardStatement(self: *Parser) anyerror!*ast.Stmt {
        const start = try self.expect(.kw_discard, "discard");
        return try self.makeStmt(positionOf(start), .{ .discard = {} });
    }

    fn parseLetStatement(self: *Parser) anyerror!*ast.Stmt {
        const start = try self.expect(.kw_let, "let binding");
        return try self.makeStmt(positionOf(start), .{
            .let_binding = try self.parseBinding(positionOf(start), "let binding name"),
        });
    }

    fn parseSimpleStatement(self: *Parser) anyerror!*ast.Stmt {
        if (self.looksLikeTypedAssignment()) {
            const name_tok = try self.expect(.identifier, "typed assignment name");
            _ = try self.expect(.colon, "':' after variable name");
            const type_name = try self.expectTypeSpec("typed assignment type");
            _ = try self.expect(.assign, "'=' after type annotation");
            const value = try self.parseExpression(0);
            return try self.makeStmt(positionOf(name_tok), .{
                .typed_assignment = .{
                    .name = try self.identifierValue(name_tok),
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

    fn parseWhereBinding(self: *Parser) anyerror!ast.LetBinding {
        return try self.parseBinding(positionOf(self.current()), "where binding name");
    }

    fn parseBinding(self: *Parser, position: ast.Position, name_label: []const u8) anyerror!ast.LetBinding {
        const name_tok = try self.expect(.identifier, name_label);
        var type_name: ?[]const u8 = null;
        if (self.match(.colon)) {
            type_name = try self.expectTypeSpec("binding type");
        }
        _ = try self.expect(.assign, "'=' after binding");
        return .{
            .position = position,
            .name = try self.identifierValue(name_tok),
            .type_name = type_name,
            .value = try self.parseExpression(0),
        };
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
                        .name = try self.identifierValue(member_name_tok),
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
                    .symbol = try self.symbolValue(tok),
                });
            },
            .identifier => {
                _ = self.advance();
                return self.makeExpr(positionOf(tok), .{
                    .identifier = try self.identifierValue(tok),
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
            .pipe => return try self.parseLambda(),
            .kw_match => return try self.parseMatchExpr(),
            else => {
                try self.reportUnexpected(tok, "expression");
                return error.ParseFailed;
            },
        }
    }

    fn parseLambda(self: *Parser) anyerror!*ast.Expr {
        const start = try self.expect(.pipe, "'|' to start lambda");
        var params: std.ArrayListUnmanaged([]const u8) = .{};
        defer params.deinit(self.allocator);

        if (!self.check(.pipe)) {
            while (true) {
                try params.append(self.allocator, try self.expectIdentifier("lambda parameter"));
                if (!self.match(.comma)) break;
            }
        }

        _ = try self.expect(.pipe, "'|' to end lambda parameters");
        const body = try self.parseExpression(0);
        return try self.makeExpr(positionOf(start), .{
            .lambda = .{
                .params = try params.toOwnedSlice(self.allocator),
                .body = body,
            },
        });
    }

    fn parseMatchExpr(self: *Parser) anyerror!*ast.Expr {
        const start = try self.expect(.kw_match, "match expression");
        const value = try self.parseExpression(0);
        var arms: std.ArrayListUnmanaged(ast.MatchArm) = .{};
        defer arms.deinit(self.allocator);

        self.consumeNewlines();
        while (self.match(.kw_when)) {
            const pattern = try self.parsePattern();
            const guard = if (self.match(.kw_if)) try self.parseExpression(0) else null;
            self.consumeNewlines();
            try arms.append(self.allocator, .{
                .pattern = pattern,
                .guard = guard,
                .body = try self.parseStatementList(&.{ .kw_when, .kw_end }),
            });
        }

        _ = try self.expect(.kw_end, "'end' to close match expression");
        return try self.makeExpr(positionOf(start), .{
            .match_expr = .{
                .value = value,
                .arms = try arms.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parsePattern(self: *Parser) anyerror!ast.Pattern {
        const tok = self.current();
        return switch (tok.tag) {
            .symbol => blk: {
                _ = self.advance();
                break :blk .{ .symbol = try self.symbolValue(tok) };
            },
            .integer_literal => blk: {
                _ = self.advance();
                break :blk .{ .integer = try std.fmt.parseInt(i64, tok.lexeme(self.source), 10) };
            },
            .float_literal => blk: {
                _ = self.advance();
                break :blk .{ .float = try std.fmt.parseFloat(f64, tok.lexeme(self.source)) };
            },
            .kw_true => {
                _ = self.advance();
                return .{ .bool = true };
            },
            .kw_false => {
                _ = self.advance();
                return .{ .bool = false };
            },
            .identifier => {
                _ = self.advance();
                const name = try self.identifierValue(tok);
                if (std.mem.eql(u8, name, "_")) {
                    return .{ .wildcard = {} };
                }
                if (std.ascii.isUpper(name[0])) {
                    var args: std.ArrayListUnmanaged(ast.Pattern) = .{};
                    defer args.deinit(self.allocator);
                    if (self.match(.lparen)) {
                        if (!self.check(.rparen)) {
                            while (true) {
                                try args.append(self.allocator, try self.parsePattern());
                                if (!self.match(.comma)) break;
                            }
                        }
                        _ = try self.expect(.rparen, "')' after constructor pattern");
                    }
                    return .{
                        .constructor = .{
                            .name = name,
                            .args = try args.toOwnedSlice(self.allocator),
                        },
                    };
                }
                return .{ .binding = name };
            },
            else => {
                try self.reportUnexpected(tok, "pattern");
                return error.ParseFailed;
            },
        };
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
        return try self.symbolValue(symbol_tok);
    }

    fn expectIdentifier(self: *Parser, what: []const u8) anyerror![]const u8 {
        const ident = try self.expect(.identifier, what);
        return try self.identifierValue(ident);
    }

    fn expectTypeSpec(self: *Parser, what: []const u8) anyerror![]const u8 {
        const start = try self.expect(.identifier, what);
        var end = start;

        if (self.match(.lparen)) {
            end = self.previous();
            var depth: usize = 1;
            while (depth > 0) {
                const tok = self.current();
                switch (tok.tag) {
                    .identifier, .integer_literal, .comma => {
                        end = self.advance();
                    },
                    .lparen => {
                        depth += 1;
                        end = self.advance();
                    },
                    .rparen => {
                        depth -= 1;
                        end = self.advance();
                    },
                    else => {
                        try self.reportUnexpected(tok, what);
                        return error.ParseFailed;
                    },
                }
            }
        }

        return try self.intern(self.source[start.start..end.end]);
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
        while (isSeparatorTag(self.current().tag)) {
            _ = self.advance();
        }
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
        if (self.peek(0) != .identifier or self.peek(1) != .colon or self.peek(2) != .identifier) {
            return false;
        }

        var offset: usize = 3;
        if (self.peek(offset) == .lparen) {
            var depth: usize = 1;
            offset += 1;
            while (depth > 0) {
                switch (self.peek(offset)) {
                    .identifier, .integer_literal, .comma => offset += 1,
                    .lparen => {
                        depth += 1;
                        offset += 1;
                    },
                    .rparen => {
                        depth -= 1;
                        offset += 1;
                    },
                    else => return false,
                }
            }
        }

        return self.peek(offset) == .assign;
    }

    fn peek(self: *Parser, offset: usize) token.TokenTag {
        const target = self.index + offset;
        if (target >= self.tokens.len) return .eof;
        return self.tokens[target].tag;
    }

    fn synchronize(self: *Parser) void {
        while (!self.isAtEnd()) {
            if (isSeparatorTag(self.current().tag)) {
                self.consumeNewlines();
                return;
            }
            if (self.check(.kw_end) or self.check(.kw_else) or self.check(.kw_elsif) or self.check(.kw_where) or self.check(.kw_when)) return;
            _ = self.advance();
        }
    }

    fn currentStartsBoundary(self: *Parser) bool {
        return isSeparatorTag(self.current().tag) or
            self.currentIsOneOf(&.{ .kw_end, .kw_else, .kw_elsif, .kw_where, .kw_when, .eof });
    }

    fn intern(self: *Parser, value: []const u8) anyerror![]const u8 {
        if (self.pool) |pool| return try pool.intern(value);
        return value;
    }

    fn identifierValue(self: *Parser, tok: token.Token) anyerror![]const u8 {
        if (tok.interned) |value| return value;
        return try self.intern(tok.lexeme(self.source));
    }

    fn symbolValue(self: *Parser, tok: token.Token) anyerror![]const u8 {
        if (tok.interned) |value| return value;
        return try self.intern(tok.lexeme(self.source)[1..]);
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

fn isSeparatorTag(tag: token.TokenTag) bool {
    return switch (tag) {
        .newline,
        .virtual_indent,
        .virtual_dedent,
        .virtual_semi,
        => true,
        else => false,
    };
}
