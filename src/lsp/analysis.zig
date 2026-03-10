const std = @import("std");
const zwgsl = @import("zwgsl");

const ast = zwgsl.ast;
const builtins = zwgsl.builtins;
const core_diagnostics = zwgsl.diagnostics;
const lexer = zwgsl.lexer;
const parser = zwgsl.parser;
const sema = zwgsl.sema;
const string_pool = zwgsl.string_pool;
const token = zwgsl.token;
const types = zwgsl.types;

pub const LspTokenType = enum(u32) {
    keyword = 0,
    function = 1,
    variable = 2,
    parameter = 3,
    type = 4,
    number = 5,
    string = 6,
    comment = 7,
    operator = 8,
    property = 9,
};

pub const DefinitionKind = enum {
    function,
    variable,
    parameter,
    type_name,
    constructor,
    trait,
    builtin,
};

pub const Definition = struct {
    name: []const u8,
    kind: DefinitionKind,
    detail: []const u8,
    documentation: ?[]const u8 = null,
    ty: ?types.Type = null,
    line: u32,
    column: u32,
    end_column: u32,
    always_visible: bool = true,
};

pub const StructInfo = struct {
    name: []const u8,
    params: []const []const u8,
    fields: []const ast.StructField,
};

pub const FunctionScope = struct {
    name: []const u8,
    stage: ?ast.Stage,
    start_line: u32,
    end_line: u32,
    params: []const Definition,
    locals: []const Definition,
    stage_symbols: []const Definition,
    stage_functions: []const Definition,
};

pub const ExprInfo = struct {
    line: u32,
    column: u32,
    detail: []const u8,
};

pub const CompletionItem = struct {
    label: []const u8,
    kind: u8,
    detail: ?[]const u8 = null,
};

pub const TokenRef = struct {
    index: usize,
    tok: token.Token,
};

pub const CommentRange = struct {
    line: u32,
    column: u32,
    len: u32,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    tokens: []const token.Token,
    diagnostics: []const core_diagnostics.Diagnostic,
    globals: []const Definition,
    types: []const Definition,
    constructors: []const Definition,
    traits: []const Definition,
    structs: []const StructInfo,
    function_scopes: []const FunctionScope,
    expr_infos: []const ExprInfo,
    comments: []const CommentRange,

    pub fn init(parent_allocator: std.mem.Allocator, source: []const u8) !Document {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        var pool = string_pool.StringPool.init(arena_allocator);
        var diagnostic_list = core_diagnostics.DiagnosticList.init(arena_allocator);

        const tokens = lexer.Lexer.tokenizeResolvedWithPool(arena_allocator, &pool, source) catch {
            return .{
                .arena = arena,
                .source = source,
                .tokens = &.{},
                .diagnostics = &.{},
                .globals = &.{},
                .types = &.{},
                .constructors = &.{},
                .traits = &.{},
                .structs = &.{},
                .function_scopes = &.{},
                .expr_infos = &.{},
                .comments = collectComments(arena_allocator, source) catch &.{},
            };
        };

        var parsed_program: ?*ast.Program = null;
        var typed_program: ?*sema.TypedProgram = null;

        {
            var syntax_parser = parser.Parser.initWithPool(arena_allocator, &pool, source, tokens, &diagnostic_list);
            parsed_program = syntax_parser.parseProgram() catch null;
        }

        if (parsed_program) |program| {
            typed_program = sema.analyzeWithPool(arena_allocator, &pool, program, &diagnostic_list) catch null;
        }

        const diagnostics = try diagnostic_list.toOwnedSlice();

        var builder = Builder{
            .allocator = arena_allocator,
            .source = source,
            .typed = typed_program,
        };
        if (parsed_program) |program| {
            try builder.collectProgram(program);
        }

        return .{
            .arena = arena,
            .source = source,
            .tokens = tokens,
            .diagnostics = diagnostics,
            .globals = try builder.globals.toOwnedSlice(arena_allocator),
            .types = try builder.types.toOwnedSlice(arena_allocator),
            .constructors = try builder.constructors.toOwnedSlice(arena_allocator),
            .traits = try builder.traits.toOwnedSlice(arena_allocator),
            .structs = try builder.structs.toOwnedSlice(arena_allocator),
            .function_scopes = try builder.function_scopes.toOwnedSlice(arena_allocator),
            .expr_infos = try builder.expr_infos.toOwnedSlice(arena_allocator),
            .comments = try collectComments(arena_allocator, source),
        };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    fn allocator(self: *const Document) std.mem.Allocator {
        return @constCast(&self.arena).allocator();
    }

    pub fn tokenAt(self: *const Document, line: u32, character: u32) ?TokenRef {
        for (self.tokens, 0..) |tok, index| {
            if (!isSemanticToken(tok.tag)) continue;
            if (tok.line == 0 or tok.line - 1 != line) continue;
            const start = if (tok.column > 0) tok.column - 1 else 0;
            const end = start + @as(u32, @intCast(tok.end - tok.start));
            if (character >= start and character < end) {
                return .{ .index = index, .tok = tok };
            }
        }
        return null;
    }

    pub fn tokenBeforeOrAt(self: *const Document, line: u32, character: u32) ?TokenRef {
        var best: ?TokenRef = null;
        for (self.tokens, 0..) |tok, index| {
            if (!isSemanticToken(tok.tag)) continue;
            if (tok.line == 0 or tok.line - 1 > line) break;
            if (tok.line - 1 < line) {
                best = .{ .index = index, .tok = tok };
                continue;
            }
            const start = if (tok.column > 0) tok.column - 1 else 0;
            if (start > character) break;
            best = .{ .index = index, .tok = tok };
        }
        return best;
    }

    pub fn lexeme(self: *const Document, tok: token.Token) []const u8 {
        return tok.lexeme(self.source);
    }

    pub fn previousSignificantToken(self: *const Document, from_index: usize) ?struct { index: usize, tok: token.Token } {
        var index = from_index;
        while (index > 0) {
            index -= 1;
            const tok = self.tokens[index];
            if (!isSemanticToken(tok.tag)) continue;
            return .{ .index = index, .tok = tok };
        }
        return null;
    }

    pub fn resolveDefinition(self: *const Document, name: []const u8, line: u32, character: u32) ?Definition {
        if (self.functionScopeAt(line)) |scope| {
            if (findDefinitionIn(scope.locals, name, line, character)) |definition| return definition;
            if (findDefinitionIn(scope.params, name, line, character)) |definition| return definition;
            if (findAlwaysVisible(scope.stage_symbols, name)) |definition| return definition;
            if (findAlwaysVisible(scope.stage_functions, name)) |definition| return definition;
        }

        if (findAlwaysVisible(self.globals, name)) |definition| return definition;
        if (findAlwaysVisible(self.types, name)) |definition| return definition;
        if (findAlwaysVisible(self.constructors, name)) |definition| return definition;
        if (findAlwaysVisible(self.traits, name)) |definition| return definition;
        if (builtinDefinition(name)) |definition| return definition;
        return null;
    }

    pub fn exprInfoAt(self: *const Document, line: u32, column: u32) ?ExprInfo {
        for (self.expr_infos) |info| {
            if (info.line == line and info.column == column) return info;
        }
        return null;
    }

    pub fn functionScopeAt(self: *const Document, line: u32) ?FunctionScope {
        var best: ?FunctionScope = null;
        for (self.function_scopes) |scope| {
            if (line + 1 < scope.start_line or line + 1 > scope.end_line) continue;
            if (best) |current| {
                const current_span = current.end_line - current.start_line;
                const candidate_span = scope.end_line - scope.start_line;
                if (candidate_span < current_span) best = scope;
            } else {
                best = scope;
            }
        }
        return best;
    }

    pub fn memberCompletionItems(self: *const Document, line: u32, character: u32) ![]const CompletionItem {
        const dot_info = self.dotContext(line, character) orelse return &.{};
        const receiver = self.resolveDefinition(dot_info.receiver_name, line, character) orelse return &.{};
        const receiver_type = receiver.ty orelse return &.{};

        var items: std.ArrayListUnmanaged(CompletionItem) = .{};
        errdefer items.deinit(self.allocator());

        if (receiver_type.isVector()) {
            for (vectorMembers()) |member| {
                try items.append(self.allocator(), member);
            }
            for (numericMethodItems()) |member| {
                try items.append(self.allocator(), member);
            }
            return try items.toOwnedSlice(self.allocator());
        }

        if (receiver_type.isMatrix()) {
            for (numericMethodItems()) |member| {
                try items.append(self.allocator(), member);
            }
            return try items.toOwnedSlice(self.allocator());
        }

        const struct_name = switch (receiver_type) {
            .struct_type => |name| name,
            .type_app => |app_ty| app_ty.name,
            else => null,
        };
        if (struct_name) |name| {
            if (self.findStruct(name)) |info| {
                for (info.fields) |field| {
                    const detail = try std.fmt.allocPrint(self.allocator(), "{s}: {s}", .{ field.name, field.type_name });
                    try items.append(self.allocator(), .{
                        .label = field.name,
                        .kind = 5,
                        .detail = detail,
                    });
                }
            }
        }

        return try items.toOwnedSlice(self.allocator());
    }

    pub fn completionItems(self: *const Document, line: u32, character: u32) ![]const CompletionItem {
        if (self.dotContext(line, character) != null) {
            return try self.memberCompletionItems(line, character);
        }

        var items: std.ArrayListUnmanaged(CompletionItem) = .{};
        errdefer items.deinit(self.allocator());
        var seen = std.StringHashMapUnmanaged(void){};
        defer seen.deinit(self.allocator());

        for (keywordDocs()) |keyword| {
            try appendCompletionUnique(self.allocator(), &items, &seen, .{
                .label = keyword.name,
                .kind = 14,
                .detail = keyword.detail,
            });
        }

        for (builtinItems()) |builtin_item| {
            try appendCompletionUnique(self.allocator(), &items, &seen, .{
                .label = builtin_item.name,
                .kind = 3,
                .detail = builtin_item.detail,
            });
        }

        for (builtinTypes()) |builtin_type| {
            try appendCompletionUnique(self.allocator(), &items, &seen, .{
                .label = builtin_type,
                .kind = 7,
                .detail = "type",
            });
        }

        if (self.functionScopeAt(line)) |scope| {
            for (scope.params) |definition| {
                try appendCompletionFromDefinition(self.allocator(), &items, &seen, definition, line, character);
            }
            for (scope.locals) |definition| {
                try appendCompletionFromDefinition(self.allocator(), &items, &seen, definition, line, character);
            }
            for (scope.stage_symbols) |definition| {
                try appendCompletionFromDefinition(self.allocator(), &items, &seen, definition, line, character);
            }
            for (scope.stage_functions) |definition| {
                try appendCompletionFromDefinition(self.allocator(), &items, &seen, definition, line, character);
            }
        }

        for (self.globals) |definition| {
            try appendCompletionUnique(self.allocator(), &items, &seen, completionFromDefinition(definition));
        }
        for (self.types) |definition| {
            try appendCompletionUnique(self.allocator(), &items, &seen, completionFromDefinition(definition));
        }
        for (self.constructors) |definition| {
            try appendCompletionUnique(self.allocator(), &items, &seen, completionFromDefinition(definition));
        }
        for (self.traits) |definition| {
            try appendCompletionUnique(self.allocator(), &items, &seen, completionFromDefinition(definition));
        }

        return try items.toOwnedSlice(self.allocator());
    }

    pub fn semanticClass(self: *const Document, tok: token.Token, index: usize) LspTokenType {
        return switch (tok.tag) {
            .integer_literal, .float_literal => .number,
            .string_literal, .symbol => .string,
            .plus,
            .minus,
            .star,
            .slash,
            .percent,
            .eq,
            .neq,
            .lt,
            .gt,
            .le,
            .ge,
            .and_and,
            .or_or,
            .bang,
            .assign,
            .plus_assign,
            .minus_assign,
            .star_assign,
            .slash_assign,
            .dot,
            .arrow,
            => .operator,
            .identifier => blk: {
                if (self.previousSignificantToken(index)) |prev| {
                    if (prev.tok.tag == .dot) break :blk .property;
                }
                const start_line = if (tok.line > 0) tok.line - 1 else 0;
                const start_column = if (tok.column > 0) tok.column - 1 else 0;
                const name = self.lexeme(tok);
                if (self.resolveDefinition(name, start_line, start_column)) |definition| {
                    break :blk switch (definition.kind) {
                        .function, .builtin => .function,
                        .parameter => .parameter,
                        .type_name, .trait, .constructor => .type,
                        .variable => .variable,
                    };
                }
                if (looksLikeTypeName(name)) break :blk .type;
                break :blk .variable;
            },
            else => if (isKeyword(tok.tag)) .keyword else .variable,
        };
    }

    pub fn findStruct(self: *const Document, name: []const u8) ?StructInfo {
        for (self.structs) |info| {
            if (std.mem.eql(u8, info.name, name)) return info;
        }
        return null;
    }

    fn dotContext(self: *const Document, line: u32, character: u32) ?struct { receiver_name: []const u8 } {
        const current = self.tokenBeforeOrAt(line, character) orelse return null;
        if (current.tok.tag == .dot) {
            const receiver = self.previousSignificantToken(current.index) orelse return null;
            if (receiver.tok.tag != .identifier) return null;
            return .{ .receiver_name = self.lexeme(receiver.tok) };
        }
        if (current.tok.tag == .identifier) {
            const previous = self.previousSignificantToken(current.index) orelse return null;
            if (previous.tok.tag != .dot) return null;
            const receiver = self.previousSignificantToken(previous.index) orelse return null;
            if (receiver.tok.tag != .identifier) return null;
            return .{ .receiver_name = self.lexeme(receiver.tok) };
        }
        return null;
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    typed: ?*sema.TypedProgram,
    globals: std.ArrayListUnmanaged(Definition) = .{},
    types: std.ArrayListUnmanaged(Definition) = .{},
    constructors: std.ArrayListUnmanaged(Definition) = .{},
    traits: std.ArrayListUnmanaged(Definition) = .{},
    structs: std.ArrayListUnmanaged(StructInfo) = .{},
    function_scopes: std.ArrayListUnmanaged(FunctionScope) = .{},
    expr_infos: std.ArrayListUnmanaged(ExprInfo) = .{},

    fn collectProgram(self: *Builder, program: *ast.Program) !void {
        const global_functions = try self.collectTopLevelFunctionSymbols(program.items);
        for (global_functions) |definition| {
            try self.globals.append(self.allocator, definition);
        }

        for (program.items) |item| {
            switch (item) {
                .uniform => |uniform| {
                    try self.globals.append(self.allocator, try self.variableDefinition(
                        uniform.name,
                        uniform.type_name,
                        .variable,
                        uniform.position,
                        true,
                    ));
                },
                .struct_def => |struct_def| {
                    try self.structs.append(self.allocator, .{
                        .name = struct_def.name,
                        .params = struct_def.params,
                        .fields = struct_def.fields,
                    });
                    const detail = try std.fmt.allocPrint(
                        self.allocator,
                        "struct {s}{s}",
                        .{
                            struct_def.name,
                            try genericSuffix(self.allocator, struct_def.params),
                        },
                    );
                    try self.types.append(self.allocator, .{
                        .name = struct_def.name,
                        .kind = .type_name,
                        .detail = detail,
                        .line = struct_def.position.line,
                        .column = struct_def.position.column,
                        .end_column = struct_def.position.column + @as(u32, @intCast(struct_def.name.len)),
                    });
                },
                .type_def => |type_def| {
                    const detail = try std.fmt.allocPrint(
                        self.allocator,
                        "type {s}{s}",
                        .{
                            type_def.name,
                            try genericSuffix(self.allocator, type_def.params),
                        },
                    );
                    try self.types.append(self.allocator, .{
                        .name = type_def.name,
                        .kind = .type_name,
                        .detail = detail,
                        .line = type_def.position.line,
                        .column = type_def.position.column,
                        .end_column = type_def.position.column + @as(u32, @intCast(type_def.name.len)),
                    });
                    for (type_def.variants) |variant| {
                        try self.constructors.append(self.allocator, try self.variantDefinition(type_def, variant));
                    }
                },
                .trait_def => |trait_def| {
                    const detail = try std.fmt.allocPrint(self.allocator, "trait {s}", .{trait_def.name});
                    try self.traits.append(self.allocator, .{
                        .name = trait_def.name,
                        .kind = .trait,
                        .detail = detail,
                        .line = trait_def.position.line,
                        .column = trait_def.position.column,
                        .end_column = trait_def.position.column + @as(u32, @intCast(trait_def.name.len)),
                    });
                },
                .function => |function| try self.collectFunctionScope(function, null, &.{}, global_functions),
                .shader_block => |block| try self.collectStageBlock(block),
                else => {},
            }
        }
    }

    fn collectStageBlock(self: *Builder, block: *ast.ShaderBlock) !void {
        const stage_symbols = try self.collectStageSymbols(block);
        const stage_functions = try self.collectStageFunctionSymbols(block.items, block.stage);
        for (block.items) |item| {
            switch (item) {
                .function => |function| try self.collectFunctionScope(function, block.stage, stage_symbols, stage_functions),
                else => {},
            }
        }
    }

    fn collectTopLevelFunctionSymbols(self: *Builder, items: []const ast.Item) ![]const Definition {
        var symbols: std.ArrayListUnmanaged(Definition) = .{};
        defer symbols.deinit(self.allocator);

        for (items) |item| {
            const function = switch (item) {
                .function => |value| value,
                else => continue,
            };
            try symbols.append(self.allocator, try self.functionDefinition(function, null));
        }

        return try symbols.toOwnedSlice(self.allocator);
    }

    fn collectStageFunctionSymbols(self: *Builder, items: []const ast.StageItem, stage: ast.Stage) ![]const Definition {
        var symbols: std.ArrayListUnmanaged(Definition) = .{};
        defer symbols.deinit(self.allocator);

        for (items) |item| {
            const function = switch (item) {
                .function => |value| value,
                else => continue,
            };
            try symbols.append(self.allocator, try self.functionDefinition(function, stage));
        }

        return try symbols.toOwnedSlice(self.allocator);
    }

    fn collectStageSymbols(self: *Builder, block: *ast.ShaderBlock) ![]const Definition {
        var symbols: std.ArrayListUnmanaged(Definition) = .{};
        defer symbols.deinit(self.allocator);

        for (block.items) |item| {
            switch (item) {
                .input => |input| try symbols.append(self.allocator, try self.variableDefinition(
                    input.name,
                    input.type_name,
                    .variable,
                    input.position,
                    true,
                )),
                .output => |output| try symbols.append(self.allocator, try self.variableDefinition(
                    output.name,
                    output.type_name,
                    .variable,
                    output.position,
                    true,
                )),
                .varying => |varying| try symbols.append(self.allocator, try self.variableDefinition(
                    varying.name,
                    varying.type_name,
                    .variable,
                    varying.position,
                    true,
                )),
                else => {},
            }
        }

        return try symbols.toOwnedSlice(self.allocator);
    }

    fn collectFunctionScope(
        self: *Builder,
        function: *ast.FunctionDef,
        stage: ?ast.Stage,
        stage_symbols: []const Definition,
        stage_functions: []const Definition,
    ) !void {
        var params: std.ArrayListUnmanaged(Definition) = .{};
        defer params.deinit(self.allocator);
        var locals: std.ArrayListUnmanaged(Definition) = .{};
        defer locals.deinit(self.allocator);
        var known_names = std.StringHashMapUnmanaged(void){};
        defer known_names.deinit(self.allocator);

        for (self.globals.items) |definition| {
            try known_names.put(self.allocator, definition.name, {});
        }
        for (stage_symbols) |definition| {
            try known_names.put(self.allocator, definition.name, {});
        }
        for (function.params, 0..) |param, index| {
            const ty = if (self.typed) |typed_program|
                if (typed_program.functionSignature(function)) |signature|
                    signature.params[index].ty
                else
                    try parseTypeShallow(self.allocator, param.type_name)
            else
                try parseTypeShallow(self.allocator, param.type_name);
            const detail = try std.fmt.allocPrint(
                self.allocator,
                "{s}: {s}",
                .{ param.name, try formatType(self.allocator, ty) },
            );
            try params.append(self.allocator, .{
                .name = param.name,
                .kind = .parameter,
                .detail = detail,
                .ty = ty,
                .line = param.position.line,
                .column = param.position.column,
                .end_column = param.position.column + @as(u32, @intCast(param.name.len)),
                .always_visible = true,
            });
            try known_names.put(self.allocator, param.name, {});
        }

        if (function.where_clause) |where_clause| {
            for (where_clause.bindings) |binding| {
                const definition = try self.bindingDefinition(binding, true);
                try locals.append(self.allocator, definition);
                try known_names.put(self.allocator, definition.name, {});
            }
        }

        for (function.body) |stmt| {
            try self.collectStatementLocals(&locals, &known_names, stmt);
            try self.collectStatementExprs(stmt);
        }

        const start_line = function.position.line;
        const end_line = functionEndLine(function);
        try self.function_scopes.append(self.allocator, .{
            .name = function.name,
            .stage = stage,
            .start_line = start_line,
            .end_line = end_line,
            .params = try params.toOwnedSlice(self.allocator),
            .locals = try locals.toOwnedSlice(self.allocator),
            .stage_symbols = stage_symbols,
            .stage_functions = stage_functions,
        });
    }

    fn collectStatementLocals(
        self: *Builder,
        locals: *std.ArrayListUnmanaged(Definition),
        known_names: *std.StringHashMapUnmanaged(void),
        stmt: *ast.Stmt,
    ) anyerror!void {
        switch (stmt.data) {
            .let_binding => |binding| {
                if (!known_names.contains(binding.name)) {
                    const definition = try self.bindingDefinition(binding, false);
                    try locals.append(self.allocator, definition);
                    try known_names.put(self.allocator, binding.name, {});
                }
            },
            .typed_assignment => |assignment| {
                if (!known_names.contains(assignment.name)) {
                    const ty = try parseTypeShallow(self.allocator, assignment.type_name);
                    const detail = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}: {s}",
                        .{ assignment.name, try formatType(self.allocator, ty) },
                    );
                    try locals.append(self.allocator, .{
                        .name = assignment.name,
                        .kind = .variable,
                        .detail = detail,
                        .ty = ty,
                        .line = stmt.position.line,
                        .column = stmt.position.column,
                        .end_column = stmt.position.column + @as(u32, @intCast(assignment.name.len)),
                        .always_visible = false,
                    });
                    try known_names.put(self.allocator, assignment.name, {});
                }
                try self.collectExprInfo(assignment.value);
            },
            .assignment => |assignment| {
                if (assignment.target.data == .identifier) {
                    const name = assignment.target.data.identifier;
                    if (!known_names.contains(name)) {
                        const ty = self.exprType(assignment.value);
                        const detail = if (ty) |value|
                            try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ name, try formatType(self.allocator, value) })
                        else
                            try std.fmt.allocPrint(self.allocator, "{s}: inferred", .{name});
                        try locals.append(self.allocator, .{
                            .name = name,
                            .kind = .variable,
                            .detail = detail,
                            .ty = ty,
                            .line = assignment.target.position.line,
                            .column = assignment.target.position.column,
                            .end_column = assignment.target.position.column + @as(u32, @intCast(name.len)),
                            .always_visible = false,
                        });
                        try known_names.put(self.allocator, name, {});
                    }
                }
                try self.collectExprInfo(assignment.target);
                try self.collectExprInfo(assignment.value);
            },
            .expression => |expr| try self.collectExprInfo(expr),
            .return_stmt => |expr| if (expr) |value| try self.collectExprInfo(value),
            .if_stmt => |if_stmt| {
                for (if_stmt.branches) |branch| {
                    try self.collectExprInfo(branch.condition);
                    for (branch.body) |branch_stmt| {
                        try self.collectStatementLocals(locals, known_names, branch_stmt);
                    }
                }
                for (if_stmt.else_body) |branch_stmt| {
                    try self.collectStatementLocals(locals, known_names, branch_stmt);
                }
            },
            .conditional => |conditional| {
                try self.collectExprInfo(conditional.condition);
                try self.collectStatementLocals(locals, known_names, conditional.body);
            },
            .times_loop => |loop| {
                try self.collectExprInfo(loop.count);
                for (loop.body) |loop_stmt| {
                    try self.collectStatementLocals(locals, known_names, loop_stmt);
                }
            },
            .each_loop => |loop| {
                try self.collectExprInfo(loop.collection);
                for (loop.body) |loop_stmt| {
                    try self.collectStatementLocals(locals, known_names, loop_stmt);
                }
            },
            .discard => {},
        }
    }

    fn collectStatementExprs(self: *Builder, stmt: *ast.Stmt) anyerror!void {
        switch (stmt.data) {
            .let_binding => |binding| try self.collectExprInfo(binding.value),
            .typed_assignment => |assignment| try self.collectExprInfo(assignment.value),
            .assignment => |assignment| {
                try self.collectExprInfo(assignment.target);
                try self.collectExprInfo(assignment.value);
            },
            .expression => |expr| try self.collectExprInfo(expr),
            .return_stmt => |expr| {
                if (expr) |value| try self.collectExprInfo(value);
            },
            .if_stmt, .conditional, .times_loop, .each_loop, .discard => {},
        }
    }

    fn collectExprInfo(self: *Builder, expr: *ast.Expr) anyerror!void {
        if (self.exprType(expr)) |ty| {
            try self.expr_infos.append(self.allocator, .{
                .line = expr.position.line,
                .column = expr.position.column,
                .detail = try formatType(self.allocator, ty),
            });
        }

        switch (expr.data) {
            .unary => |unary| try self.collectExprInfo(unary.operand),
            .binary => |binary| {
                try self.collectExprInfo(binary.lhs);
                try self.collectExprInfo(binary.rhs);
            },
            .member => |member| try self.collectExprInfo(member.target),
            .call => |call| {
                try self.collectExprInfo(call.callee);
                for (call.args) |arg| try self.collectExprInfo(arg);
            },
            .index => |index_expr| {
                try self.collectExprInfo(index_expr.target);
                try self.collectExprInfo(index_expr.index);
            },
            .lambda => |lambda| try self.collectExprInfo(lambda.body),
            .match_expr => |match_expr| {
                try self.collectExprInfo(match_expr.value);
                for (match_expr.arms) |arm| {
                    if (arm.guard) |guard| try self.collectExprInfo(guard);
                    for (arm.body) |stmt| try self.collectStatementExprs(stmt);
                }
            },
            else => {},
        }
    }

    fn exprType(self: *const Builder, expr: *ast.Expr) ?types.Type {
        const typed_program = self.typed orelse return null;
        const ty = typed_program.exprType(expr);
        if (ty.isError()) return null;
        return ty;
    }

    fn functionDefinition(self: *Builder, function: *ast.FunctionDef, stage: ?ast.Stage) !Definition {
        const detail = if (self.typed) |typed_program|
            if (typed_program.functionSignature(function)) |signature|
                try formatSignature(self.allocator, signature)
            else
                try formatAstFunction(self.allocator, function)
        else
            try formatAstFunction(self.allocator, function);

        const documentation = if (stage) |active_stage|
            try std.fmt.allocPrint(self.allocator, "{s} stage function", .{@tagName(active_stage)})
        else
            "global function";

        return .{
            .name = function.name,
            .kind = .function,
            .detail = detail,
            .documentation = documentation,
            .line = function.position.line,
            .column = function.position.column,
            .end_column = function.position.column + @as(u32, @intCast(function.name.len)),
        };
    }

    fn variableDefinition(
        self: *Builder,
        name: []const u8,
        type_name: []const u8,
        kind: DefinitionKind,
        position: ast.Position,
        always_visible: bool,
    ) !Definition {
        const ty = try parseTypeShallow(self.allocator, type_name);
        const detail = try std.fmt.allocPrint(
            self.allocator,
            "{s}: {s}",
            .{ name, try formatType(self.allocator, ty) },
        );
        return .{
            .name = name,
            .kind = kind,
            .detail = detail,
            .ty = ty,
            .line = position.line,
            .column = position.column,
            .end_column = position.column + @as(u32, @intCast(name.len)),
            .always_visible = always_visible,
        };
    }

    fn bindingDefinition(self: *Builder, binding: ast.LetBinding, always_visible: bool) !Definition {
        const ty = if (binding.type_name) |type_name|
            try parseTypeShallow(self.allocator, type_name)
        else
            self.exprType(binding.value);
        const detail = if (ty) |value|
            try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ binding.name, try formatType(self.allocator, value) })
        else
            try std.fmt.allocPrint(self.allocator, "{s}: inferred", .{binding.name});
        return .{
            .name = binding.name,
            .kind = .variable,
            .detail = detail,
            .ty = ty,
            .line = binding.position.line,
            .column = binding.position.column,
            .end_column = binding.position.column + @as(u32, @intCast(binding.name.len)),
            .always_visible = always_visible,
        };
    }

    fn variantDefinition(self: *Builder, type_def: ast.TypeDef, variant: ast.Variant) !Definition {
        var fields = std.ArrayListUnmanaged(u8){};
        defer fields.deinit(self.allocator);
        const writer = fields.writer(self.allocator);

        try writer.print("{s}(", .{variant.name});
        for (variant.fields, 0..) |field, index| {
            if (index != 0) try writer.writeAll(", ");
            try writer.print("{s}: {s}", .{ field.name, field.type_name });
        }
        try writer.print(") -> {s}", .{type_def.name});

        return .{
            .name = variant.name,
            .kind = .constructor,
            .detail = try fields.toOwnedSlice(self.allocator),
            .line = variant.position.line,
            .column = variant.position.column,
            .end_column = variant.position.column + @as(u32, @intCast(variant.name.len)),
        };
    }
};

const StaticDoc = struct {
    name: []const u8,
    detail: []const u8,
    documentation: []const u8,
};

fn keywordDocs() []const StaticDoc {
    return &.{
        .{ .name = "def", .detail = "Define a function", .documentation = "Defines a function with an implicit return from the last expression." },
        .{ .name = "let", .detail = "Immutable local binding", .documentation = "Creates an immutable local binding inside the current scope." },
        .{ .name = "where", .detail = "Function-local bindings", .documentation = "Attaches local bindings to a function body and keeps them visible from the whole function." },
        .{ .name = "match", .detail = "Pattern match expression", .documentation = "Matches a value against constructor, literal, wildcard, and binding patterns." },
        .{ .name = "when", .detail = "Pattern arm", .documentation = "Starts an arm inside a match expression and may include an optional guard." },
        .{ .name = "type", .detail = "Algebraic data type", .documentation = "Defines a tagged union with constructor variants." },
        .{ .name = "struct", .detail = "Struct definition", .documentation = "Defines a user struct type that lowers to shader-compatible data." },
        .{ .name = "trait", .detail = "Trait definition", .documentation = "Declares a type class-style interface used for constrained functions." },
        .{ .name = "impl", .detail = "Trait implementation", .documentation = "Registers a concrete implementation of a trait for a type." },
        .{ .name = "vertex", .detail = "Vertex stage block", .documentation = "Starts the vertex stage declaration block." },
        .{ .name = "fragment", .detail = "Fragment stage block", .documentation = "Starts the fragment stage declaration block." },
        .{ .name = "compute", .detail = "Compute stage block", .documentation = "Starts the compute stage declaration block." },
    };
}

fn builtinItems() []const StaticDoc {
    return &.{
        .{ .name = "normalize", .detail = "fn normalize(v: Vec(N)) -> Vec(N)", .documentation = "Returns the normalized vector." },
        .{ .name = "length", .detail = "fn length(v: Vec(N) | Sca) -> Float", .documentation = "Returns the vector or scalar magnitude." },
        .{ .name = "dot", .detail = "fn dot(a: Vec(N), b: Vec(N)) -> Float", .documentation = "Computes a dot product with dependent-dimension checking." },
        .{ .name = "cross", .detail = "fn cross(a: Vec(3), b: Vec(3)) -> Vec(3)", .documentation = "Computes a 3D cross product." },
        .{ .name = "reflect", .detail = "fn reflect(i: Vec(N), n: Vec(N)) -> Vec(N)", .documentation = "Reflects an incident vector around a normal." },
        .{ .name = "mix", .detail = "fn mix(a: T, b: T, t: T | Sca) -> T", .documentation = "Linearly interpolates between values." },
        .{ .name = "texture", .detail = "fn texture(s: Sampler2D, uv: Vec2) -> Vec4", .documentation = "Samples a texture and maps to WGSL textureSample." },
        .{ .name = "transpose", .detail = "fn transpose(m: Mat(M, N)) -> Mat(M, N)", .documentation = "Returns the transposed matrix." },
    };
}

fn builtinTypes() []const []const u8 {
    return &.{
        "Float",
        "Int",
        "UInt",
        "Bool",
        "Sca",
        "Vec2",
        "Vec3",
        "Vec4",
        "IVec2",
        "IVec3",
        "IVec4",
        "UVec2",
        "UVec3",
        "UVec4",
        "BVec2",
        "BVec3",
        "BVec4",
        "Mat2",
        "Mat3",
        "Mat4",
        "Sampler2D",
        "SamplerCube",
        "Sampler3D",
        "Vec",
        "Mat",
        "Ten",
    };
}

fn numericMethodItems() []const CompletionItem {
    return &.{
        .{ .label = "normalize", .kind = 2, .detail = "method" },
        .{ .label = "length", .kind = 2, .detail = "method" },
        .{ .label = "dot", .kind = 2, .detail = "method" },
        .{ .label = "cross", .kind = 2, .detail = "method" },
        .{ .label = "reflect", .kind = 2, .detail = "method" },
        .{ .label = "mix", .kind = 2, .detail = "method" },
        .{ .label = "clamp", .kind = 2, .detail = "method" },
        .{ .label = "min", .kind = 2, .detail = "method" },
        .{ .label = "max", .kind = 2, .detail = "method" },
        .{ .label = "pow", .kind = 2, .detail = "method" },
        .{ .label = "transpose", .kind = 2, .detail = "method" },
    };
}

fn vectorMembers() []const CompletionItem {
    return &.{
        .{ .label = "x", .kind = 5, .detail = "swizzle" },
        .{ .label = "y", .kind = 5, .detail = "swizzle" },
        .{ .label = "z", .kind = 5, .detail = "swizzle" },
        .{ .label = "w", .kind = 5, .detail = "swizzle" },
        .{ .label = "xy", .kind = 5, .detail = "swizzle" },
        .{ .label = "xyz", .kind = 5, .detail = "swizzle" },
        .{ .label = "xyzw", .kind = 5, .detail = "swizzle" },
        .{ .label = "rgb", .kind = 5, .detail = "swizzle" },
        .{ .label = "rgba", .kind = 5, .detail = "swizzle" },
    };
}

pub fn keywordDoc(name: []const u8) ?StaticDoc {
    for (keywordDocs()) |keyword| {
        if (std.mem.eql(u8, keyword.name, name)) return keyword;
    }
    return null;
}

pub fn builtinDoc(name: []const u8) ?StaticDoc {
    for (builtinItems()) |item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }
    return null;
}

fn builtinDefinition(name: []const u8) ?Definition {
    const item = builtinDoc(name) orelse return null;
    return .{
        .name = item.name,
        .kind = .builtin,
        .detail = item.detail,
        .documentation = item.documentation,
        .line = 0,
        .column = 0,
        .end_column = 0,
    };
}

fn appendCompletionFromDefinition(
    allocator: std.mem.Allocator,
    items: *std.ArrayListUnmanaged(CompletionItem),
    seen: *std.StringHashMapUnmanaged(void),
    definition: Definition,
    line: u32,
    character: u32,
) !void {
    if (!definition.always_visible) {
        if (definition.line - 1 > line) return;
        if (definition.line - 1 == line and definition.column - 1 > character) return;
    }
    try appendCompletionUnique(allocator, items, seen, completionFromDefinition(definition));
}

fn appendCompletionUnique(
    allocator: std.mem.Allocator,
    items: *std.ArrayListUnmanaged(CompletionItem),
    seen: *std.StringHashMapUnmanaged(void),
    item: CompletionItem,
) !void {
    if (seen.contains(item.label)) return;
    try seen.put(allocator, item.label, {});
    try items.append(allocator, item);
}

fn completionFromDefinition(definition: Definition) CompletionItem {
    return .{
        .label = definition.name,
        .kind = switch (definition.kind) {
            .function, .builtin => 3,
            .parameter => 6,
            .type_name, .trait, .constructor => 7,
            .variable => 6,
        },
        .detail = definition.detail,
    };
}

fn findAlwaysVisible(definitions: []const Definition, name: []const u8) ?Definition {
    for (definitions) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return definition;
    }
    return null;
}

fn findDefinitionIn(definitions: []const Definition, name: []const u8, line: u32, character: u32) ?Definition {
    var index = definitions.len;
    while (index > 0) {
        index -= 1;
        const definition = definitions[index];
        if (!std.mem.eql(u8, definition.name, name)) continue;
        if (definition.always_visible) return definition;
        if (definition.line == 0) continue;
        if (definition.line - 1 < line) return definition;
        if (definition.line - 1 == line and definition.column - 1 <= character) return definition;
    }
    return null;
}

fn genericSuffix(allocator: std.mem.Allocator, params: []const []const u8) ![]const u8 {
    if (params.len == 0) return "";
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);
    try writer.writeByte('(');
    for (params, 0..) |param, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(param);
    }
    try writer.writeByte(')');
    return try buffer.toOwnedSlice(allocator);
}

fn formatSignature(allocator: std.mem.Allocator, signature: sema.FunctionSignature) ![]const u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.print("def {s}", .{signature.name});
    if (signature.params.len > 0) {
        try writer.writeByte('(');
        for (signature.params, 0..) |param, index| {
            if (index != 0) try writer.writeAll(", ");
            try writer.print("{s}: {s}", .{ param.name, try formatType(allocator, param.ty) });
        }
        try writer.writeByte(')');
    }
    try writer.print(" -> {s}", .{try formatType(allocator, signature.return_type)});
    if (signature.constraints.len > 0) {
        try writer.writeAll(" where ");
        for (signature.constraints, 0..) |constraint, index| {
            if (index != 0) try writer.writeAll(", ");
            try writer.print("T{d}: {s}", .{ constraint.type_var, constraint.trait_name });
        }
    }

    return try buffer.toOwnedSlice(allocator);
}

fn formatAstFunction(allocator: std.mem.Allocator, function: *ast.FunctionDef) ![]const u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.print("def {s}", .{function.name});
    if (function.params.len > 0) {
        try writer.writeByte('(');
        for (function.params, 0..) |param, index| {
            if (index != 0) try writer.writeAll(", ");
            try writer.print("{s}: {s}", .{ param.name, param.type_name });
        }
        try writer.writeByte(')');
    }
    if (function.return_type) |return_type| {
        try writer.print(" -> {s}", .{return_type});
    }
    return try buffer.toOwnedSlice(allocator);
}

pub fn formatType(allocator: std.mem.Allocator, ty: types.Type) ![]const u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    defer buffer.deinit(allocator);
    try writeType(buffer.writer(allocator), ty);
    return try buffer.toOwnedSlice(allocator);
}

fn writeType(writer: anytype, ty: types.Type) !void {
    switch (ty) {
        .builtin => |builtin_ty| try writer.writeAll(switch (builtin_ty) {
            .float => "Float",
            .int => "Int",
            .uint => "UInt",
            .bool => "Bool",
            .symbol => "Symbol",
            .vec2 => "Vec2",
            .vec3 => "Vec3",
            .vec4 => "Vec4",
            .ivec2 => "IVec2",
            .ivec3 => "IVec3",
            .ivec4 => "IVec4",
            .uvec2 => "UVec2",
            .uvec3 => "UVec3",
            .uvec4 => "UVec4",
            .bvec2 => "BVec2",
            .bvec3 => "BVec3",
            .bvec4 => "BVec4",
            .mat2 => "Mat2",
            .mat3 => "Mat3",
            .mat4 => "Mat4",
            .sampler2d => "Sampler2D",
            .sampler_cube => "SamplerCube",
            .sampler3d => "Sampler3D",
            .void => "Void",
            .error_type => "Error",
        }),
        .struct_type => |name| try writer.writeAll(name),
        .function => |fn_ty| {
            try writer.writeAll("fn(");
            for (fn_ty.params, 0..) |param, index| {
                if (index != 0) try writer.writeAll(", ");
                try writeType(writer, param);
            }
            try writer.writeAll(") -> ");
            try writeType(writer, fn_ty.return_type.*);
        },
        .type_var => |id| try writer.print("T{d}", .{id}),
        .type_app => |app_ty| {
            try writer.print("{s}(", .{app_ty.name});
            for (app_ty.args, 0..) |arg, index| {
                if (index != 0) try writer.writeAll(", ");
                try writeType(writer, arg);
            }
            try writer.writeByte(')');
        },
        .nat => |value| try writer.print("{d}", .{value}),
    }
}

fn parseTypeShallow(allocator: std.mem.Allocator, input: []const u8) !types.Type {
    var parser_state = TypeParser{
        .allocator = allocator,
        .input = input,
    };
    const ty = try parser_state.parseType();
    parser_state.skipSpaces();
    return ty;
}

const TypeParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,

    fn parseType(self: *TypeParser) !types.Type {
        self.skipSpaces();
        if (self.index >= self.input.len) return types.builtinType(.error_type);
        if (std.ascii.isDigit(self.input[self.index])) {
            return .{ .nat = try self.parseNat() };
        }

        const name = try self.parseIdentifier();
        self.skipSpaces();
        if (!self.matchChar('(')) {
            return types.fromName(name) orelse .{ .struct_type = name };
        }

        var args: std.ArrayListUnmanaged(types.Type) = .{};
        defer args.deinit(self.allocator);

        self.skipSpaces();
        if (!self.peekChar(')')) {
            while (true) {
                try args.append(self.allocator, try self.parseType());
                self.skipSpaces();
                if (!self.matchChar(',')) break;
            }
        }
        _ = self.matchChar(')');
        return try types.typeApp(self.allocator, name, args.items);
    }

    fn parseNat(self: *TypeParser) !u32 {
        const start = self.index;
        while (self.index < self.input.len and std.ascii.isDigit(self.input[self.index])) : (self.index += 1) {}
        return try std.fmt.parseInt(u32, self.input[start..self.index], 10);
    }

    fn parseIdentifier(self: *TypeParser) ![]const u8 {
        const start = self.index;
        while (self.index < self.input.len and (std.ascii.isAlphanumeric(self.input[self.index]) or self.input[self.index] == '_')) : (self.index += 1) {}
        return self.input[start..self.index];
    }

    fn skipSpaces(self: *TypeParser) void {
        while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) : (self.index += 1) {}
    }

    fn matchChar(self: *TypeParser, ch: u8) bool {
        self.skipSpaces();
        if (self.index >= self.input.len or self.input[self.index] != ch) return false;
        self.index += 1;
        return true;
    }

    fn peekChar(self: *TypeParser, ch: u8) bool {
        self.skipSpaces();
        return self.index < self.input.len and self.input[self.index] == ch;
    }
};

fn functionEndLine(function: *ast.FunctionDef) u32 {
    var end_line = function.position.line;
    for (function.body) |stmt| end_line = @max(end_line, stmtEndLine(stmt));
    if (function.where_clause) |where_clause| {
        end_line = @max(end_line, where_clause.position.line);
        for (where_clause.bindings) |binding| {
            end_line = @max(end_line, binding.position.line);
        }
    }
    return end_line + 1;
}

fn stmtEndLine(stmt: *ast.Stmt) u32 {
    var end_line = stmt.position.line;
    switch (stmt.data) {
        .expression => |expr| end_line = @max(end_line, exprEndLine(expr)),
        .let_binding => |binding| end_line = @max(end_line, exprEndLine(binding.value)),
        .assignment => |assignment| {
            end_line = @max(end_line, exprEndLine(assignment.target));
            end_line = @max(end_line, exprEndLine(assignment.value));
        },
        .typed_assignment => |assignment| end_line = @max(end_line, exprEndLine(assignment.value)),
        .return_stmt => |expr| {
            if (expr) |value| end_line = @max(end_line, exprEndLine(value));
        },
        .if_stmt => |if_stmt| {
            for (if_stmt.branches) |branch| {
                end_line = @max(end_line, exprEndLine(branch.condition));
                for (branch.body) |branch_stmt| end_line = @max(end_line, stmtEndLine(branch_stmt));
            }
            for (if_stmt.else_body) |branch_stmt| end_line = @max(end_line, stmtEndLine(branch_stmt));
        },
        .conditional => |conditional| {
            end_line = @max(end_line, exprEndLine(conditional.condition));
            end_line = @max(end_line, stmtEndLine(conditional.body));
        },
        .times_loop => |loop| {
            end_line = @max(end_line, exprEndLine(loop.count));
            for (loop.body) |loop_stmt| end_line = @max(end_line, stmtEndLine(loop_stmt));
        },
        .each_loop => |loop| {
            end_line = @max(end_line, exprEndLine(loop.collection));
            for (loop.body) |loop_stmt| end_line = @max(end_line, stmtEndLine(loop_stmt));
        },
        .discard => {},
    }
    return end_line;
}

fn exprEndLine(expr: *ast.Expr) u32 {
    var end_line = expr.position.line;
    switch (expr.data) {
        .unary => |unary| end_line = @max(end_line, exprEndLine(unary.operand)),
        .binary => |binary| {
            end_line = @max(end_line, exprEndLine(binary.lhs));
            end_line = @max(end_line, exprEndLine(binary.rhs));
        },
        .member => |member| end_line = @max(end_line, exprEndLine(member.target)),
        .call => |call| {
            end_line = @max(end_line, exprEndLine(call.callee));
            for (call.args) |arg| end_line = @max(end_line, exprEndLine(arg));
        },
        .index => |index_expr| {
            end_line = @max(end_line, exprEndLine(index_expr.target));
            end_line = @max(end_line, exprEndLine(index_expr.index));
        },
        .lambda => |lambda| end_line = @max(end_line, exprEndLine(lambda.body)),
        .match_expr => |match_expr| {
            end_line = @max(end_line, exprEndLine(match_expr.value));
            for (match_expr.arms) |arm| {
                if (arm.guard) |guard| end_line = @max(end_line, exprEndLine(guard));
                for (arm.body) |stmt| end_line = @max(end_line, stmtEndLine(stmt));
            }
        },
        else => {},
    }
    return end_line;
}

fn collectComments(allocator: std.mem.Allocator, source: []const u8) ![]const CommentRange {
    var items: std.ArrayListUnmanaged(CommentRange) = .{};
    defer items.deinit(allocator);

    var line: u32 = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= source.len) : (index += 1) {
        if (index != source.len and source[index] != '\n') continue;
        const slice = source[start..index];
        if (std.mem.indexOfScalar(u8, slice, '#')) |comment_index| {
            try items.append(allocator, .{
                .line = line,
                .column = @intCast(comment_index),
                .len = @intCast(slice.len - comment_index),
            });
        }
        line += 1;
        start = index + 1;
    }

    return try items.toOwnedSlice(allocator);
}

fn looksLikeTypeName(name: []const u8) bool {
    return name.len > 0 and std.ascii.isUpper(name[0]);
}

fn isKeyword(tag: token.TokenTag) bool {
    return switch (tag) {
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
        .kw_let,
        .kw_where,
        .kw_type,
        .kw_match,
        .kw_when,
        .kw_trait,
        .kw_impl,
        .kw_for,
        => true,
        else => false,
    };
}

fn isSemanticToken(tag: token.TokenTag) bool {
    return switch (tag) {
        .newline,
        .virtual_indent,
        .virtual_dedent,
        .virtual_semi,
        .eof,
        .invalid,
        => false,
        else => true,
    };
}

test "document analysis resolves local definitions and completions" {
    const source =
        \\uniform :mvp, Mat4
        \\
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\
        \\  def shade(pos: Vec3) -> Vec4
        \\    let normal = normalize(pos)
        \\    normal.xyz
        \\  end
        \\end
    ;

    var document = try Document.init(std.testing.allocator, source);
    defer document.deinit();

    const local = document.resolveDefinition("normal", 6, 8) orelse return error.TestExpectedDefinition;
    try std.testing.expectEqualStrings("normal: Vec3", local.detail);

    const completions = try document.memberCompletionItems(6, 12);
    try std.testing.expect(completions.len > 0);
    try std.testing.expectEqualStrings("xyz", completions[6].label);
}
