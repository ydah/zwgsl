const std = @import("std");
const ast = @import("ast.zig");
const builtins = @import("builtins.zig");
const diagnostics = @import("diagnostics.zig");
const hm = @import("hm.zig");
const string_pool = @import("string_pool.zig");
const types = @import("types.zig");

const SymbolKind = enum {
    uniform,
    input,
    output,
    varying,
    local,
    param,
    builtin,
};

const WhereVisitState = enum {
    visiting,
    visited,
};

const SymbolInfo = struct {
    ty: types.Type,
    kind: SymbolKind,
    mutable: bool,
    scheme: ?hm.TypeScheme = null,
};

const Scope = struct {
    allocator: std.mem.Allocator,
    parent: ?*const Scope,
    symbols: std.StringHashMap(SymbolInfo),

    fn init(allocator: std.mem.Allocator, parent: ?*const Scope) Scope {
        return .{
            .allocator = allocator,
            .parent = parent,
            .symbols = std.StringHashMap(SymbolInfo).init(allocator),
        };
    }

    fn put(self: *Scope, name: []const u8, info: SymbolInfo) !bool {
        if (self.symbols.contains(name)) return false;
        try self.symbols.put(name, info);
        return true;
    }

    fn get(self: *const Scope, name: []const u8) ?SymbolInfo {
        if (self.symbols.get(name)) |symbol| return symbol;
        if (self.parent) |parent| return parent.get(name);
        return null;
    }

    fn getLocal(self: *const Scope, name: []const u8) ?SymbolInfo {
        return self.symbols.get(name);
    }
};

pub const ParamInfo = struct {
    name: []const u8,
    ty: types.Type,
    is_inout: bool,
};

pub const FunctionSignature = struct {
    function: *ast.FunctionDef,
    name: []const u8,
    params: []const ParamInfo,
    return_type: types.Type,
    stage: ?ast.Stage = null,
};

pub const TypedProgram = struct {
    allocator: std.mem.Allocator,
    program: *ast.Program,
    expr_types: std.AutoHashMap(*ast.Expr, types.Type),
    function_signatures: std.AutoHashMap(*ast.FunctionDef, FunctionSignature),
    where_bindings: std.AutoHashMap(*ast.FunctionDef, []const *const ast.LetBinding),
    global_functions: []const *ast.FunctionDef = &.{},
    vertex_functions: []const *ast.FunctionDef = &.{},
    fragment_functions: []const *ast.FunctionDef = &.{},
    compute_functions: []const *ast.FunctionDef = &.{},
    vertex_block: ?*ast.ShaderBlock = null,
    fragment_block: ?*ast.ShaderBlock = null,
    compute_block: ?*ast.ShaderBlock = null,

    pub fn exprType(self: *const TypedProgram, expr: *ast.Expr) types.Type {
        return self.expr_types.get(expr) orelse types.builtinType(.error_type);
    }

    pub fn functionSignature(self: *const TypedProgram, function: *ast.FunctionDef) ?FunctionSignature {
        return self.function_signatures.get(function);
    }

    pub fn whereBindings(self: *const TypedProgram, function: *ast.FunctionDef) []const *const ast.LetBinding {
        return self.where_bindings.get(function) orelse &.{};
    }
};

pub fn analyze(
    allocator: std.mem.Allocator,
    program: *ast.Program,
    diagnostic_list: *diagnostics.DiagnosticList,
) anyerror!*TypedProgram {
    return analyzeWithPool(allocator, null, program, diagnostic_list);
}

pub fn analyzeWithPool(
    allocator: std.mem.Allocator,
    pool: ?*string_pool.StringPool,
    program: *ast.Program,
    diagnostic_list: *diagnostics.DiagnosticList,
) anyerror!*TypedProgram {
    var analyzer = try Analyzer.init(allocator, pool, program, diagnostic_list);
    return try analyzer.run();
}

const Analyzer = struct {
    allocator: std.mem.Allocator,
    pool: ?*string_pool.StringPool,
    program: *ast.Program,
    diagnostics: *diagnostics.DiagnosticList,
    typed: *TypedProgram,
    struct_fields: std.StringHashMap([]const ast.StructField),
    global_scope: Scope,
    global_functions: std.ArrayListUnmanaged(*ast.FunctionDef) = .{},
    vertex_functions: std.ArrayListUnmanaged(*ast.FunctionDef) = .{},
    fragment_functions: std.ArrayListUnmanaged(*ast.FunctionDef) = .{},
    compute_functions: std.ArrayListUnmanaged(*ast.FunctionDef) = .{},

    fn init(
        allocator: std.mem.Allocator,
        pool: ?*string_pool.StringPool,
        program: *ast.Program,
        diagnostic_list: *diagnostics.DiagnosticList,
    ) !Analyzer {
        const typed = try allocator.create(TypedProgram);
        typed.* = .{
            .allocator = allocator,
            .program = program,
            .expr_types = std.AutoHashMap(*ast.Expr, types.Type).init(allocator),
            .function_signatures = std.AutoHashMap(*ast.FunctionDef, FunctionSignature).init(allocator),
            .where_bindings = std.AutoHashMap(*ast.FunctionDef, []const *const ast.LetBinding).init(allocator),
        };

        return .{
            .allocator = allocator,
            .pool = pool,
            .program = program,
            .diagnostics = diagnostic_list,
            .typed = typed,
            .struct_fields = std.StringHashMap([]const ast.StructField).init(allocator),
            .global_scope = Scope.init(allocator, null),
        };
    }

    fn run(self: *Analyzer) anyerror!*TypedProgram {
        try self.collectTopLevel();
        try self.registerFunctions();
        try self.validateVaryings();
        try self.analyzeGlobalFunctions();
        if (self.typed.vertex_block) |vertex| try self.analyzeStage(vertex, self.vertex_functions.items);
        if (self.typed.fragment_block) |fragment| try self.analyzeStage(fragment, self.fragment_functions.items);
        if (self.typed.compute_block) |compute| try self.analyzeStage(compute, self.compute_functions.items);

        self.typed.global_functions = try self.global_functions.toOwnedSlice(self.allocator);
        self.typed.vertex_functions = try self.vertex_functions.toOwnedSlice(self.allocator);
        self.typed.fragment_functions = try self.fragment_functions.toOwnedSlice(self.allocator);
        self.typed.compute_functions = try self.compute_functions.toOwnedSlice(self.allocator);
        return self.typed;
    }

    fn collectTopLevel(self: *Analyzer) anyerror!void {
        for (self.program.items) |item| {
            switch (item) {
                .uniform => |uniform| {
                    const ty = try self.resolveTypeName(uniform.type_name, uniform.position);
                    if (!try self.global_scope.put(uniform.name, .{
                        .ty = ty,
                        .kind = .uniform,
                        .mutable = false,
                    })) {
                        try self.report(uniform.position, "redefinition of uniform '{s}'", .{uniform.name});
                    }
                },
                .struct_def => |struct_def| {
                    if (self.struct_fields.contains(struct_def.name)) {
                        try self.report(struct_def.position, "redefinition of struct '{s}'", .{struct_def.name});
                    } else {
                        try self.struct_fields.put(struct_def.name, struct_def.fields);
                    }
                },
                .function => |function| try self.global_functions.append(self.allocator, function),
                .shader_block => |block| switch (block.stage) {
                    .vertex => {
                        if (self.typed.vertex_block == null) {
                            self.typed.vertex_block = block;
                        } else {
                            try self.report(block.position, "multiple vertex shader blocks are not supported", .{});
                        }
                    },
                    .fragment => {
                        if (self.typed.fragment_block == null) {
                            self.typed.fragment_block = block;
                        } else {
                            try self.report(block.position, "multiple fragment shader blocks are not supported", .{});
                        }
                    },
                    .compute => {
                        if (self.typed.compute_block == null) {
                            self.typed.compute_block = block;
                        } else {
                            try self.report(block.position, "multiple compute shader blocks are not supported", .{});
                        }
                    },
                },
                else => {},
            }
        }

        if (self.typed.compute_block != null and (self.typed.vertex_block != null or self.typed.fragment_block != null)) {
            try self.report(self.typed.compute_block.?.position, "compute shaders cannot be combined with vertex/fragment stages", .{});
        }
    }

    fn registerFunctions(self: *Analyzer) anyerror!void {
        for (self.global_functions.items) |function| {
            try self.registerFunction(function, null);
        }

        if (self.typed.vertex_block) |block| {
            for (block.items) |item| {
                if (item == .function) {
                    try self.vertex_functions.append(self.allocator, item.function);
                    try self.registerFunction(item.function, .vertex);
                }
            }
        }

        if (self.typed.fragment_block) |block| {
            for (block.items) |item| {
                if (item == .function) {
                    try self.fragment_functions.append(self.allocator, item.function);
                    try self.registerFunction(item.function, .fragment);
                }
            }
        }

        if (self.typed.compute_block) |block| {
            for (block.items) |item| {
                if (item == .function) {
                    try self.compute_functions.append(self.allocator, item.function);
                    try self.registerFunction(item.function, .compute);
                }
            }
        }
    }

    fn registerFunction(self: *Analyzer, function: *ast.FunctionDef, stage: ?ast.Stage) anyerror!void {
        var params = std.ArrayListUnmanaged(ParamInfo){};
        defer params.deinit(self.allocator);

        for (function.params) |param| {
            try params.append(self.allocator, .{
                .name = param.name,
                .ty = try self.resolveTypeName(param.type_name, param.position),
                .is_inout = param.is_inout,
            });
        }

        const return_type = if (function.return_type) |name|
            try self.resolveTypeName(name, function.position)
        else if (sameName(function.name, "main"))
            types.builtinType(.void)
        else
            types.builtinType(.error_type);

        try self.typed.function_signatures.put(function, .{
            .function = function,
            .name = function.name,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .stage = stage,
        });
    }

    fn validateVaryings(self: *Analyzer) anyerror!void {
        if (self.typed.vertex_block == null or self.typed.fragment_block == null) return;

        var vertex_varyings = std.StringHashMap(types.Type).init(self.allocator);
        var fragment_varyings = std.StringHashMap(types.Type).init(self.allocator);

        try self.collectVaryings(self.typed.vertex_block.?, &vertex_varyings);
        try self.collectVaryings(self.typed.fragment_block.?, &fragment_varyings);

        var vertex_it = vertex_varyings.iterator();
        while (vertex_it.next()) |entry| {
            const fragment_type = fragment_varyings.get(entry.key_ptr.*) orelse {
                try self.report(self.typed.fragment_block.?.position, "fragment shader is missing varying '{s}'", .{entry.key_ptr.*});
                continue;
            };
            if (!entry.value_ptr.*.eql(fragment_type)) {
                try self.report(self.typed.fragment_block.?.position, "varying '{s}' has mismatched type between vertex and fragment stages", .{entry.key_ptr.*});
            }
        }

        var fragment_it = fragment_varyings.iterator();
        while (fragment_it.next()) |entry| {
            if (!vertex_varyings.contains(entry.key_ptr.*)) {
                try self.report(self.typed.vertex_block.?.position, "vertex shader is missing varying '{s}'", .{entry.key_ptr.*});
            }
        }
    }

    fn collectVaryings(self: *Analyzer, block: *ast.ShaderBlock, map: *std.StringHashMap(types.Type)) anyerror!void {
        for (block.items) |item| {
            if (item == .varying) {
                try map.put(item.varying.name, try self.resolveTypeName(item.varying.type_name, item.varying.position));
            }
        }
    }

    fn analyzeGlobalFunctions(self: *Analyzer) anyerror!void {
        for (self.global_functions.items) |function| {
            try self.analyzeFunction(function, &self.global_scope, null, self.global_functions.items, &self.global_scope);
        }
    }

    fn analyzeStage(self: *Analyzer, block: *ast.ShaderBlock, stage_functions: []const *ast.FunctionDef) anyerror!void {
        var stage_scope = Scope.init(self.allocator, &self.global_scope);

        if (block.stage == .vertex) {
            _ = try stage_scope.put(try self.intern("gl_Position"), .{
                .ty = types.builtinType(.vec4),
                .kind = .builtin,
                .mutable = true,
            });
        }
        if (block.stage == .compute) {
            _ = try stage_scope.put(try self.intern("global_invocation_id"), .{
                .ty = types.builtinType(.uvec3),
                .kind = .builtin,
                .mutable = false,
            });
            _ = try stage_scope.put(try self.intern("local_invocation_id"), .{
                .ty = types.builtinType(.uvec3),
                .kind = .builtin,
                .mutable = false,
            });
            _ = try stage_scope.put(try self.intern("workgroup_id"), .{
                .ty = types.builtinType(.uvec3),
                .kind = .builtin,
                .mutable = false,
            });
            _ = try stage_scope.put(try self.intern("num_workgroups"), .{
                .ty = types.builtinType(.uvec3),
                .kind = .builtin,
                .mutable = false,
            });
            _ = try stage_scope.put(try self.intern("local_invocation_index"), .{
                .ty = types.builtinType(.uint),
                .kind = .builtin,
                .mutable = false,
            });
        }

        for (block.items) |item| {
            switch (item) {
                .input, .output, .varying => if (block.stage == .compute) {
                    const decl = switch (item) {
                        .input => item.input,
                        .output => item.output,
                        .varying => item.varying,
                        else => unreachable,
                    };
                    try self.report(decl.position, "compute shaders do not support stage I/O declarations", .{});
                } else switch (item) {
                    .input => |decl| try self.bindStageDecl(&stage_scope, decl, .input, false),
                    .output => |decl| try self.bindStageDecl(&stage_scope, decl, .output, true),
                    .varying => |decl| {
                        const mutable = block.stage == .vertex;
                        try self.bindStageDecl(&stage_scope, decl, .varying, mutable);
                    },
                    else => unreachable,
                },
                .precision => |decl| if (block.stage == .compute) {
                    try self.report(decl.position, "compute shaders do not use precision qualifiers", .{});
                },
                else => {},
            }
        }

        for (block.items) |item| {
            if (item == .function) {
                try self.analyzeFunction(item.function, &stage_scope, block.stage, stage_functions, &stage_scope);
            }
        }
    }

    fn intern(self: *Analyzer, value: []const u8) ![]const u8 {
        if (self.pool) |pool| return try pool.intern(value);
        return value;
    }

    fn bindStageDecl(
        self: *Analyzer,
        scope: *Scope,
        decl: ast.IoDecl,
        kind: SymbolKind,
        mutable: bool,
    ) anyerror!void {
        const ty = try self.resolveTypeName(decl.type_name, decl.position);
        const name = try self.intern(decl.name);
        if (!try scope.put(name, .{
            .ty = ty,
            .kind = kind,
            .mutable = mutable,
        })) {
            try self.report(decl.position, "redefinition of '{s}'", .{decl.name});
        }
    }

    fn analyzeFunction(
        self: *Analyzer,
        function: *ast.FunctionDef,
        parent_scope: *const Scope,
        stage: ?ast.Stage,
        stage_functions: []const *ast.FunctionDef,
        stage_scope: *const Scope,
    ) anyerror!void {
        var scope = Scope.init(self.allocator, parent_scope);
        const signature = self.typed.function_signatures.getPtr(function).?;

        for (signature.params) |param| {
            if (!try scope.put(param.name, .{
                .ty = param.ty,
                .kind = .param,
                .mutable = param.is_inout,
            })) {
                try self.report(function.position, "duplicate parameter '{s}'", .{param.name});
            }
        }

        var hm_engine = hm.Engine.init(self.allocator);
        defer hm_engine.deinit();

        var context = FunctionContext{
            .analyzer = self,
            .signature = signature,
            .stage = stage,
            .stage_scope = stage_scope,
            .stage_functions = stage_functions,
            .hm_engine = &hm_engine,
        };

        if (function.where_clause) |where_clause| {
            try self.analyzeWhereClause(function, &scope, where_clause, &context);
        }

        var last_expr_type: ?types.Type = null;
        for (function.body, 0..) |statement, index| {
            const stmt_type = try self.analyzeStmt(&scope, statement, &context);
            if (index + 1 == function.body.len) last_expr_type = stmt_type;
        }

        if (sameName(function.name, "main") and !signature.return_type.isVoid()) {
            try self.report(function.position, "main must not declare a return type", .{});
            signature.return_type = types.builtinType(.void);
        }

        if (signature.return_type.isError() and !sameName(function.name, "main")) {
            signature.return_type = last_expr_type orelse types.builtinType(.void);
        }

        if (signature.return_type.isVoid()) {
            for (context.return_types.items) |return_type| {
                if (!return_type.isVoid()) {
                    try self.report(function.position, "void function '{s}' must not return a value", .{function.name});
                }
            }
            return;
        }

        var saw_value_return = false;
        for (context.return_types.items) |return_type| {
            saw_value_return = true;
            if (!types.isAssignable(signature.return_type, return_type)) {
                try self.report(function.position, "return type mismatch in '{s}'", .{function.name});
            }
        }

        if (!saw_value_return) {
            if (last_expr_type) |expr_type| {
                if (!types.isAssignable(signature.return_type, expr_type)) {
                    try self.report(function.position, "implicit return type mismatch in '{s}'", .{function.name});
                }
            } else {
                try self.report(function.position, "function '{s}' does not produce a value", .{function.name});
            }
        }
    }

    fn analyzeStmt(
        self: *Analyzer,
        scope: *Scope,
        stmt: *ast.Stmt,
        context: *FunctionContext,
    ) anyerror!?types.Type {
        switch (stmt.data) {
            .expression => |expr| {
                return try self.analyzeExpr(scope, expr, context);
            },
            .let_binding => |binding| {
                try self.analyzeLetBinding(scope, binding, true, context);
                return null;
            },
            .typed_assignment => |typed_assignment| {
                const target_type = try self.resolveTypeName(typed_assignment.type_name, stmt.position);
                const value_type = try self.analyzeExpr(scope, typed_assignment.value, context);
                if (!types.isAssignable(target_type, value_type)) {
                    try self.report(stmt.position, "cannot assign value of type {s} to {s}", .{ value_type.glslName(), target_type.glslName() });
                }
                if (!try scope.put(typed_assignment.name, .{
                    .ty = target_type,
                    .kind = .local,
                    .mutable = true,
                })) {
                    try self.report(stmt.position, "redefinition of local '{s}'", .{typed_assignment.name});
                }
                return null;
            },
            .assignment => |assignment| {
                try self.analyzeAssignment(scope, assignment, context);
                return null;
            },
            .return_stmt => |value| {
                const return_type = if (value) |expr|
                    try self.analyzeExpr(scope, expr, context)
                else
                    types.builtinType(.void);
                try context.return_types.append(self.allocator, return_type);
                return null;
            },
            .discard => {
                if (context.stage != .fragment) {
                    try self.report(stmt.position, "discard is only valid in fragment shaders", .{});
                }
                return null;
            },
            .if_stmt => |if_stmt| {
                for (if_stmt.branches, 0..) |branch, index| {
                    const condition_type = try self.analyzeExpr(scope, branch.condition, context);
                    if (!condition_type.isBuiltin(.bool)) {
                        try self.report(branch.condition.position, "conditional expression must be Bool", .{});
                    }
                    var branch_scope = Scope.init(self.allocator, scope);
                    for (branch.body) |branch_stmt| {
                        _ = try self.analyzeStmt(&branch_scope, branch_stmt, context);
                    }
                    if (index == 0 and if_stmt.negate_first and !condition_type.isBuiltin(.bool)) {
                        try self.report(branch.condition.position, "unless condition must be Bool", .{});
                    }
                }
                var else_scope = Scope.init(self.allocator, scope);
                for (if_stmt.else_body) |branch_stmt| {
                    _ = try self.analyzeStmt(&else_scope, branch_stmt, context);
                }
                return null;
            },
            .conditional => |conditional| {
                const condition_type = try self.analyzeExpr(scope, conditional.condition, context);
                if (!condition_type.isBuiltin(.bool)) {
                    try self.report(conditional.condition.position, "postfix conditional expression must be Bool", .{});
                }
                var nested_scope = Scope.init(self.allocator, scope);
                _ = try self.analyzeStmt(&nested_scope, conditional.body, context);
                return null;
            },
            .times_loop => |times_loop| {
                const count_type = try self.analyzeExpr(scope, times_loop.count, context);
                if (!count_type.isBuiltin(.int)) {
                    try self.report(times_loop.count.position, "times loop count must be Int", .{});
                }
                var loop_scope = Scope.init(self.allocator, scope);
                if (times_loop.binding) |binding| {
                    _ = try loop_scope.put(binding, .{
                        .ty = types.builtinType(.int),
                        .kind = .local,
                        .mutable = false,
                    });
                }
                for (times_loop.body) |body_stmt| {
                    _ = try self.analyzeStmt(&loop_scope, body_stmt, context);
                }
                return null;
            },
            .each_loop => |each_loop| {
                const collection_type = try self.analyzeExpr(scope, each_loop.collection, context);
                if (!collection_type.isVector()) {
                    try self.report(each_loop.collection.position, "each loops are only supported on vectors in phase 1", .{});
                    return null;
                }

                var loop_scope = Scope.init(self.allocator, scope);
                if (each_loop.binding) |binding| {
                    _ = try loop_scope.put(binding, .{
                        .ty = collection_type.componentType().?,
                        .kind = .local,
                        .mutable = false,
                    });
                }
                for (each_loop.body) |body_stmt| {
                    _ = try self.analyzeStmt(&loop_scope, body_stmt, context);
                }
                return null;
            },
        }
    }

    fn analyzeLetBinding(
        self: *Analyzer,
        scope: *Scope,
        binding: ast.LetBinding,
        immutable: bool,
        context: *FunctionContext,
    ) anyerror!void {
        const scheme = try self.inferLetScheme(scope, binding, context);
        const value_type = scheme.ty;
        const target_type = if (binding.type_name) |type_name| blk: {
            const annotated = try self.resolveTypeName(type_name, binding.position);
            if (!types.isAssignable(annotated, value_type)) {
                try self.report(binding.position, "cannot assign value of type {s} to {s}", .{ value_type.glslName(), annotated.glslName() });
            }
            break :blk annotated;
        } else value_type;

        if (!try scope.put(binding.name, .{
            .ty = target_type,
            .kind = .local,
            .mutable = !immutable,
            .scheme = if (binding.type_name == null) scheme else hm.Engine.monomorphic(target_type),
        })) {
            try self.report(binding.position, "redefinition of local '{s}'", .{binding.name});
        }
    }

    fn analyzeWhereClause(
        self: *Analyzer,
        function: *ast.FunctionDef,
        scope: *Scope,
        where_clause: ast.WhereClause,
        context: *FunctionContext,
    ) anyerror!void {
        const ordered = try self.sortWhereBindings(where_clause.bindings);
        try self.typed.where_bindings.put(function, ordered);

        for (ordered) |binding| {
            try self.analyzeLetBinding(scope, binding.*, true, context);
        }
    }

    fn sortWhereBindings(self: *Analyzer, bindings: []const ast.LetBinding) anyerror![]const *const ast.LetBinding {
        var binding_map = std.StringHashMap(*const ast.LetBinding).init(self.allocator);
        defer binding_map.deinit();
        for (bindings) |*binding| {
            if (binding_map.contains(binding.name)) {
                try self.report(binding.position, "redefinition of local '{s}'", .{binding.name});
                continue;
            }
            try binding_map.put(binding.name, binding);
        }

        var states = std.StringHashMap(WhereVisitState).init(self.allocator);
        defer states.deinit();

        var ordered: std.ArrayListUnmanaged(*const ast.LetBinding) = .{};
        defer ordered.deinit(self.allocator);

        var iterator = binding_map.iterator();
        while (iterator.next()) |entry| {
            try self.visitWhereBinding(&binding_map, &states, &ordered, entry.value_ptr.*);
        }

        return try ordered.toOwnedSlice(self.allocator);
    }

    fn visitWhereBinding(
        self: *Analyzer,
        binding_map: *const std.StringHashMap(*const ast.LetBinding),
        states: *std.StringHashMap(WhereVisitState),
        ordered: *std.ArrayListUnmanaged(*const ast.LetBinding),
        binding: *const ast.LetBinding,
    ) anyerror!void {
        if (states.get(binding.name)) |state| {
            switch (state) {
                .visited => return,
                .visiting => {
                    try self.report(binding.position, "circular dependency in where clause for '{s}'", .{binding.name});
                    return;
                },
            }
        }

        try states.put(binding.name, .visiting);

        var identifiers: std.StringHashMapUnmanaged(void) = .{};
        defer identifiers.deinit(self.allocator);
        try collectExprIdentifiers(self.allocator, binding.value, &identifiers);

        var iterator = identifiers.iterator();
        while (iterator.next()) |entry| {
            if (binding_map.get(entry.key_ptr.*)) |dependency| {
                try self.visitWhereBinding(binding_map, states, ordered, dependency);
            }
        }

        try states.put(binding.name, .visited);
        try ordered.append(self.allocator, binding);
    }

    fn inferLetScheme(
        self: *Analyzer,
        scope: *const Scope,
        binding: ast.LetBinding,
        context: *FunctionContext,
    ) anyerror!hm.TypeScheme {
        if (binding.value.data != .lambda) {
            const value_type = try self.analyzeExpr(@constCast(scope), binding.value, context);
            return hm.Engine.monomorphic(value_type);
        }

        var env = try self.buildHmEnv(scope);
        defer env.deinit();

        const inferred = context.hm_engine.inferExpr(&env, binding.value) catch {
            try self.report(binding.position, "failed to infer let binding '{s}'", .{binding.name});
            return hm.Engine.monomorphic(types.builtinType(.error_type));
        };
        return try context.hm_engine.generalize(&env, inferred);
    }

    fn buildHmEnv(self: *Analyzer, scope: *const Scope) anyerror!hm.TypeEnv {
        var env = hm.TypeEnv.init(self.allocator);
        try self.populateHmEnv(scope, &env);
        return env;
    }

    fn populateHmEnv(self: *Analyzer, scope: *const Scope, env: *hm.TypeEnv) anyerror!void {
        if (scope.parent) |parent| {
            try self.populateHmEnv(parent, env);
        }

        var iterator = scope.symbols.iterator();
        while (iterator.next()) |entry| {
            try env.put(entry.key_ptr.*, entry.value_ptr.scheme orelse hm.Engine.monomorphic(entry.value_ptr.ty));
        }
    }

    fn resolveInferredCall(
        self: *Analyzer,
        position: ast.Position,
        callable: types.Type,
        arg_types: []const types.Type,
        context: *FunctionContext,
    ) anyerror!types.Type {
        return context.hm_engine.resolveCallable(callable, arg_types) catch {
            try self.report(position, "call has incompatible argument types", .{});
            return types.builtinType(.error_type);
        };
    }

    fn analyzeAssignment(
        self: *Analyzer,
        scope: *Scope,
        assignment: ast.Assignment,
        context: *FunctionContext,
    ) anyerror!void {
        const value_type = try self.analyzeExpr(scope, assignment.value, context);

        switch (assignment.target.data) {
            .identifier => |name| {
                const existing = scope.get(name);
                if (existing) |symbol| {
                    if (!symbol.mutable) {
                        try self.report(assignment.target.position, "cannot assign to immutable symbol '{s}'", .{name});
                    }
                    try self.rememberExprType(assignment.target, symbol.ty);
                    if (assignment.operator == .assign) {
                        if (!types.isAssignable(symbol.ty, value_type)) {
                            try self.report(assignment.target.position, "cannot assign value of type {s} to {s}", .{ value_type.glslName(), symbol.ty.glslName() });
                        }
                    } else {
                        const result_type = types.resolveOp(compoundOperator(assignment.operator), symbol.ty, value_type) orelse types.builtinType(.error_type);
                        if (!types.isAssignable(symbol.ty, result_type)) {
                            try self.report(assignment.target.position, "compound assignment has incompatible types", .{});
                        }
                    }
                    return;
                }

                if (assignment.operator != .assign) {
                    try self.report(assignment.target.position, "cannot use compound assignment on undeclared symbol '{s}'", .{name});
                    return;
                }

                _ = try scope.put(name, .{
                    .ty = value_type,
                    .kind = .local,
                    .mutable = true,
                });
                try self.rememberExprType(assignment.target, value_type);
            },
            else => {
                const target_type = try self.analyzeExpr(scope, assignment.target, context);
                if (assignment.operator == .assign) {
                    if (!types.isAssignable(target_type, value_type)) {
                        try self.report(assignment.target.position, "cannot assign value of type {s} to {s}", .{ value_type.glslName(), target_type.glslName() });
                    }
                } else {
                    if (types.resolveOp(compoundOperator(assignment.operator), target_type, value_type) == null) {
                        try self.report(assignment.target.position, "compound assignment has incompatible types", .{});
                    }
                }
            },
        }
    }

    fn analyzeExpr(
        self: *Analyzer,
        scope: *Scope,
        expr: *ast.Expr,
        context: *FunctionContext,
    ) anyerror!types.Type {
        if (self.typed.expr_types.get(expr)) |existing| return existing;

        const resolved = switch (expr.data) {
            .integer => types.builtinType(.int),
            .float => types.builtinType(.float),
            .bool => types.builtinType(.bool),
            .string => types.builtinType(.error_type),
            .symbol => types.builtinType(.error_type),
            .identifier => |name| blk: {
                const symbol = scope.get(name) orelse {
                    try self.report(expr.position, "use of undeclared symbol '{s}'", .{name});
                    break :blk types.builtinType(.error_type);
                };
                if (symbol.scheme) |scheme| {
                    break :blk context.hm_engine.instantiate(scheme) catch symbol.ty;
                }
                break :blk symbol.ty;
            },
            .self_ref => blk: {
                try self.report(expr.position, "self must be followed by a member access", .{});
                break :blk types.builtinType(.error_type);
            },
            .unary => |unary| blk: {
                const operand_type = try self.analyzeExpr(scope, unary.operand, context);
                if (unary.operator == .bang) {
                    if (!operand_type.isBuiltin(.bool)) {
                        try self.report(expr.position, "'!' expects Bool", .{});
                        break :blk types.builtinType(.error_type);
                    }
                    break :blk types.builtinType(.bool);
                }
                if (!operand_type.isNumeric()) {
                    try self.report(expr.position, "unary '-' expects numeric operand", .{});
                    break :blk types.builtinType(.error_type);
                }
                break :blk operand_type;
            },
            .binary => |binary| blk: {
                const lhs = try self.analyzeExpr(scope, binary.lhs, context);
                const rhs = try self.analyzeExpr(scope, binary.rhs, context);
                const result = types.resolveOp(binary.operator, lhs, rhs) orelse {
                    try self.report(expr.position, "operator {s} is not valid for {s} and {s}", .{ @tagName(binary.operator), lhs.glslName(), rhs.glslName() });
                    break :blk types.builtinType(.error_type);
                };
                break :blk result;
            },
            .member => |member| blk: {
                if (member.target.data == .self_ref) {
                    if (context.stage == null) {
                        try self.report(expr.position, "self is only valid inside shader stages", .{});
                        break :blk types.builtinType(.error_type);
                    }
                    const symbol = context.stage_scope.getLocal(member.name) orelse {
                        try self.report(expr.position, "self.{s} is not declared in this stage", .{member.name});
                        break :blk types.builtinType(.error_type);
                    };
                    break :blk symbol.ty;
                }

                const target_type = try self.analyzeExpr(scope, member.target, context);
                if (types.isValidSwizzle(target_type, member.name)) |swizzle_type| {
                    break :blk swizzle_type;
                }
                if (builtins.resolveMethod(member.name, target_type, &.{})) |builtin_resolution| {
                    break :blk builtin_resolution.return_type;
                }
                if (target_type == .struct_type) {
                    const fields = self.struct_fields.get(target_type.struct_type) orelse {
                        try self.report(expr.position, "unknown struct type '{s}'", .{target_type.struct_type});
                        break :blk types.builtinType(.error_type);
                    };
                    for (fields) |field| {
                        if (sameName(field.name, member.name)) {
                            break :blk try self.resolveTypeName(field.type_name, field.position);
                        }
                    }
                }
                try self.report(expr.position, "member '{s}' does not exist on {s}", .{ member.name, target_type.glslName() });
                break :blk types.builtinType(.error_type);
            },
            .call => |call| blk: {
                var arg_types = std.ArrayListUnmanaged(types.Type){};
                defer arg_types.deinit(self.allocator);

                for (call.args) |arg| {
                    try arg_types.append(self.allocator, try self.analyzeExpr(scope, arg, context));
                }

                switch (call.callee.data) {
                    .identifier => |name| {
                        if (scope.get(name)) |symbol| {
                            const callable = if (symbol.scheme) |scheme|
                                context.hm_engine.instantiate(scheme) catch symbol.ty
                            else
                                symbol.ty;
                            if (callable == .function) {
                                break :blk try self.resolveInferredCall(expr.position, callable, arg_types.items, context);
                            }
                        }
                        if (builtins.resolve(name, arg_types.items)) |resolution| {
                            break :blk resolution.return_type;
                        }
                        if (self.findFunction(name, arg_types.items, context.stage_functions)) |signature| {
                            break :blk signature.return_type;
                        }
                        if (self.findFunction(name, arg_types.items, self.global_functions.items)) |signature| {
                            break :blk signature.return_type;
                        }
                        try self.report(expr.position, "unknown function '{s}'", .{name});
                        break :blk types.builtinType(.error_type);
                    },
                    .member => |member| {
                        const receiver_type = try self.analyzeExpr(scope, member.target, context);
                        if (builtins.resolveMethod(member.name, receiver_type, arg_types.items)) |resolution| {
                            break :blk resolution.return_type;
                        }
                        try self.report(expr.position, "unknown method '{s}' for {s}", .{ member.name, receiver_type.glslName() });
                        break :blk types.builtinType(.error_type);
                    },
                    else => {
                        const callee_type = try self.analyzeExpr(scope, call.callee, context);
                        if (callee_type == .function) {
                            break :blk try self.resolveInferredCall(expr.position, callee_type, arg_types.items, context);
                        }
                        try self.report(expr.position, "expression is not callable", .{});
                        break :blk types.builtinType(.error_type);
                    },
                }
            },
            .index => |index_expr| blk: {
                const target_type = try self.analyzeExpr(scope, index_expr.target, context);
                const index_type = try self.analyzeExpr(scope, index_expr.index, context);
                if (!index_type.isBuiltin(.int)) {
                    try self.report(index_expr.index.position, "index expression must be Int", .{});
                    break :blk types.builtinType(.error_type);
                }
                if (target_type.isVector()) {
                    break :blk target_type.componentType().?;
                }
                try self.report(expr.position, "indexing is only supported on vectors in phase 1", .{});
                break :blk types.builtinType(.error_type);
            },
            .lambda => blk: {
                var env = try self.buildHmEnv(scope);
                defer env.deinit();
                break :blk context.hm_engine.inferExpr(&env, expr) catch {
                    try self.report(expr.position, "failed to infer lambda type", .{});
                    break :blk types.builtinType(.error_type);
                };
            },
        };

        try self.rememberExprType(expr, resolved);
        return resolved;
    }

    fn findFunction(
        self: *Analyzer,
        name: []const u8,
        arg_types: []const types.Type,
        functions: []const *ast.FunctionDef,
    ) ?FunctionSignature {
        for (functions) |function| {
            const signature = self.typed.function_signatures.get(function) orelse continue;
            if (!sameName(signature.name, name)) continue;
            if (signature.params.len != arg_types.len) continue;

            var matched = true;
            for (signature.params, arg_types) |param, arg_type| {
                if (!types.isAssignable(param.ty, arg_type)) {
                    matched = false;
                    break;
                }
            }
            if (matched) return signature;
        }
        return null;
    }

    fn resolveTypeName(self: *Analyzer, name: []const u8, position: ast.Position) anyerror!types.Type {
        if (types.fromName(name)) |builtin| return builtin;
        if (self.struct_fields.contains(name)) return .{ .struct_type = name };
        try self.report(position, "unknown type '{s}'", .{name});
        return types.builtinType(.error_type);
    }

    fn rememberExprType(self: *Analyzer, expr: *ast.Expr, ty: types.Type) anyerror!void {
        try self.typed.expr_types.put(expr, ty);
    }

    fn report(self: *Analyzer, position: ast.Position, comptime fmt: []const u8, args: anytype) anyerror!void {
        try self.diagnostics.appendFmt(.@"error", position.line, position.column, fmt, args);
    }
};

const FunctionContext = struct {
    analyzer: *Analyzer,
    signature: *FunctionSignature,
    stage: ?ast.Stage,
    stage_scope: *const Scope,
    stage_functions: []const *ast.FunctionDef,
    hm_engine: *hm.Engine,
    return_types: std.ArrayListUnmanaged(types.Type) = .{},
};

fn compoundOperator(tag: @import("token.zig").TokenTag) @import("token.zig").TokenTag {
    return switch (tag) {
        .plus_assign => .plus,
        .minus_assign => .minus,
        .star_assign => .star,
        .slash_assign => .slash,
        else => .assign,
    };
}

fn sameName(lhs: []const u8, rhs: []const u8) bool {
    return (lhs.len == rhs.len and lhs.ptr == rhs.ptr) or std.mem.eql(u8, lhs, rhs);
}

fn collectExprIdentifiers(
    allocator: std.mem.Allocator,
    expr: *ast.Expr,
    names: *std.StringHashMapUnmanaged(void),
) anyerror!void {
    switch (expr.data) {
        .identifier => |name| try names.put(allocator, name, {}),
        .unary => |unary| try collectExprIdentifiers(allocator, unary.operand, names),
        .binary => |binary| {
            try collectExprIdentifiers(allocator, binary.lhs, names);
            try collectExprIdentifiers(allocator, binary.rhs, names);
        },
        .member => |member| try collectExprIdentifiers(allocator, member.target, names),
        .call => |call| {
            try collectExprIdentifiers(allocator, call.callee, names);
            for (call.args) |arg| {
                try collectExprIdentifiers(allocator, arg, names);
            }
        },
        .index => |index_expr| {
            try collectExprIdentifiers(allocator, index_expr.target, names);
            try collectExprIdentifiers(allocator, index_expr.index, names);
        },
        .lambda => |lambda| try collectExprIdentifiers(allocator, lambda.body, names),
        else => {},
    }
}
