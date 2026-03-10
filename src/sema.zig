const std = @import("std");
const ast = @import("ast.zig");
const builtins = @import("builtins.zig");
const diagnostics = @import("diagnostics.zig");
const hm = @import("hm.zig");
const string_pool = @import("string_pool.zig");
const types = @import("types.zig");
const unify = @import("unify.zig");

const SymbolKind = enum {
    uniform,
    input,
    output,
    varying,
    local,
    param,
    builtin,
    constructor,
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

pub const VariantInfo = struct {
    name: []const u8,
    field_names: []const []const u8,
    field_types: []const types.Type,
    tag: u32,
};

pub const TypeDefInfo = struct {
    name: []const u8,
    params: []const []const u8,
    variants: []const VariantInfo,
};

pub const ConstructorInfo = struct {
    name: []const u8,
    parent_name: []const u8,
    tag: u32,
    field_names: []const []const u8,
    field_types: []const types.Type,
    return_type: types.Type,
    scheme: hm.TypeScheme,
};

pub const TypedProgram = struct {
    allocator: std.mem.Allocator,
    program: *ast.Program,
    expr_types: std.AutoHashMap(*ast.Expr, types.Type),
    function_signatures: std.AutoHashMap(*ast.FunctionDef, FunctionSignature),
    where_bindings: std.AutoHashMap(*ast.FunctionDef, []const *const ast.LetBinding),
    type_defs: std.StringHashMap(TypeDefInfo),
    constructors: std.StringHashMap(ConstructorInfo),
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

    pub fn typeDef(self: *const TypedProgram, name: []const u8) ?TypeDefInfo {
        return self.type_defs.get(name);
    }

    pub fn constructor(self: *const TypedProgram, name: []const u8) ?ConstructorInfo {
        return self.constructors.get(name);
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
    type_defs: std.StringHashMap(TypeDefInfo),
    constructors: std.StringHashMap(ConstructorInfo),
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
            .type_defs = std.StringHashMap(TypeDefInfo).init(allocator),
            .constructors = std.StringHashMap(ConstructorInfo).init(allocator),
        };

        return .{
            .allocator = allocator,
            .pool = pool,
            .program = program,
            .diagnostics = diagnostic_list,
            .typed = typed,
            .struct_fields = std.StringHashMap([]const ast.StructField).init(allocator),
            .type_defs = std.StringHashMap(TypeDefInfo).init(allocator),
            .constructors = std.StringHashMap(ConstructorInfo).init(allocator),
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
                .type_def => |type_def| try self.registerTypeDef(type_def),
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

    fn registerTypeDef(self: *Analyzer, type_def: ast.TypeDef) anyerror!void {
        if (self.type_defs.contains(type_def.name)) {
            try self.report(type_def.position, "redefinition of type '{s}'", .{type_def.name});
            return;
        }

        var variants = std.ArrayListUnmanaged(VariantInfo){};
        defer variants.deinit(self.allocator);

        const quantified = try self.allocator.alloc(u32, type_def.params.len);
        for (type_def.params, 0..) |_, index| {
            quantified[index] = @intCast(index);
        }

        for (type_def.variants, 0..) |variant, tag_index| {
            const field_names = try self.allocator.alloc([]const u8, variant.fields.len);
            const field_types = try self.allocator.alloc(types.Type, variant.fields.len);
            for (variant.fields, 0..) |field, field_index| {
                field_names[field_index] = field.name;
                field_types[field_index] = try self.resolveTypeNameWithParams(field.type_name, field.position, type_def.params);
            }

            const variant_info: VariantInfo = .{
                .name = variant.name,
                .field_names = field_names,
                .field_types = field_types,
                .tag = @intCast(tag_index),
            };
            try variants.append(self.allocator, variant_info);

            const return_type = try self.makeGenericType(type_def.name, type_def.params);
            const symbol_type = if (field_types.len == 0) return_type else blk: {
                const params = try self.allocator.alloc(types.Type, field_types.len);
                @memcpy(params, field_types);
                const return_ptr = try self.allocator.create(types.Type);
                return_ptr.* = return_type;
                break :blk types.Type{
                    .function = .{
                        .params = params,
                        .return_type = return_ptr,
                    },
                };
            };

            const constructor_info: ConstructorInfo = .{
                .name = variant.name,
                .parent_name = type_def.name,
                .tag = @intCast(tag_index),
                .field_names = field_names,
                .field_types = field_types,
                .return_type = return_type,
                .scheme = .{
                    .quantified = quantified,
                    .ty = symbol_type,
                },
            };

            if (self.constructors.contains(variant.name)) {
                try self.report(variant.position, "redefinition of constructor '{s}'", .{variant.name});
            } else {
                try self.constructors.put(variant.name, constructor_info);
                try self.typed.constructors.put(variant.name, constructor_info);
                if (!try self.global_scope.put(variant.name, .{
                    .ty = symbol_type,
                    .kind = .constructor,
                    .mutable = false,
                    .scheme = constructor_info.scheme,
                })) {
                    try self.report(variant.position, "redefinition of symbol '{s}'", .{variant.name});
                }
            }
        }

        const type_info: TypeDefInfo = .{
            .name = type_def.name,
            .params = type_def.params,
            .variants = try variants.toOwnedSlice(self.allocator),
        };
        try self.type_defs.put(type_def.name, type_info);
        try self.typed.type_defs.put(type_def.name, type_info);
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
        var generic_params = std.ArrayListUnmanaged([]const u8){};
        defer generic_params.deinit(self.allocator);

        for (function.params) |param| {
            try params.append(self.allocator, .{
                .name = param.name,
                .ty = try self.resolveTypeNameCollectingParams(param.type_name, param.position, &generic_params),
                .is_inout = param.is_inout,
            });
        }

        const return_type = if (function.return_type) |name|
            try self.resolveTypeNameCollectingParams(name, function.position, &generic_params)
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
            if (!self.typesCompatible(signature.return_type, return_type)) {
                try self.report(function.position, "return type mismatch in '{s}'", .{function.name});
            }
        }

        if (!saw_value_return) {
            if (last_expr_type) |expr_type| {
                if (!self.typesCompatible(signature.return_type, expr_type)) {
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
                if (!self.typesCompatible(target_type, value_type)) {
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
            if (!self.typesCompatible(annotated, value_type)) {
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
        var env = try self.buildHmEnv(scope);
        defer env.deinit();

        if (binding.value.data != .lambda) {
            const value_type = try self.analyzeExpr(@constCast(scope), binding.value, context);
            return try context.hm_engine.generalize(&env, value_type);
        }

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
                        if (!self.typesCompatible(symbol.ty, value_type)) {
                            try self.report(assignment.target.position, "cannot assign value of type {s} to {s}", .{ value_type.glslName(), symbol.ty.glslName() });
                        }
                    } else {
                        const result_type = types.resolveOp(compoundOperator(assignment.operator), symbol.ty, value_type) orelse types.builtinType(.error_type);
                        if (!self.typesCompatible(symbol.ty, result_type)) {
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
                    if (!self.typesCompatible(target_type, value_type)) {
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
                        if (self.findFunction(name, arg_types.items, context.stage_functions)) |return_type| {
                            break :blk return_type;
                        }
                        if (self.findFunction(name, arg_types.items, self.global_functions.items)) |return_type| {
                            break :blk return_type;
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
            .match_expr => try self.analyzeMatchExpr(scope, expr.data.match_expr, context, expr.position),
        };

        try self.rememberExprType(expr, resolved);
        return resolved;
    }

    fn analyzeMatchExpr(
        self: *Analyzer,
        scope: *Scope,
        match_expr: ast.Expr.MatchExpr,
        context: *FunctionContext,
        position: ast.Position,
    ) anyerror!types.Type {
        const value_type = try self.analyzeExpr(scope, match_expr.value, context);
        var result_type: ?types.Type = null;
        var exhaustive = false;
        var seen_constructors = std.StringHashMapUnmanaged(void){};
        defer seen_constructors.deinit(self.allocator);

        for (match_expr.arms) |arm| {
            var arm_scope = Scope.init(self.allocator, scope);
            const summary = try self.bindPattern(&arm_scope, arm.pattern, value_type, position);
            if (summary.matches_all) exhaustive = true;
            if (summary.constructor_name) |constructor_name| {
                try seen_constructors.put(self.allocator, constructor_name, {});
            }

            if (arm.guard) |guard| {
                const guard_type = try self.analyzeExpr(&arm_scope, guard, context);
                if (!guard_type.isBuiltin(.bool)) {
                    try self.report(guard.position, "match guard must be Bool", .{});
                }
            }

            var arm_result: ?types.Type = null;
            for (arm.body, 0..) |statement, index| {
                const stmt_type = try self.analyzeStmt(&arm_scope, statement, context);
                if (index + 1 == arm.body.len) {
                    arm_result = stmt_type orelse types.builtinType(.void);
                }
            }

            const body_type = arm_result orelse types.builtinType(.void);
            if (result_type) |existing| {
                if (!self.typesCompatible(existing, body_type) and !self.typesCompatible(body_type, existing)) {
                    try self.report(position, "match arms must evaluate to compatible types", .{});
                    result_type = types.builtinType(.error_type);
                }
            } else {
                result_type = body_type;
            }
        }

        if (!exhaustive) {
            if (self.typeInfoFor(value_type)) |type_info| {
                var missing = false;
                for (type_info.variants) |variant| {
                    if (!seen_constructors.contains(variant.name)) {
                        missing = true;
                        break;
                    }
                }
                if (missing) {
                    try self.diagnostics.appendFmt(
                        .warning,
                        position.line,
                        position.column,
                        "match on '{s}' is not exhaustive",
                        .{type_info.name},
                    );
                }
            }
        }

        return result_type orelse types.builtinType(.void);
    }

    fn bindPattern(
        self: *Analyzer,
        scope: *Scope,
        pattern: ast.Pattern,
        expected_type: types.Type,
        position: ast.Position,
    ) anyerror!struct { matches_all: bool, constructor_name: ?[]const u8 } {
        return switch (pattern) {
            .wildcard => .{ .matches_all = true, .constructor_name = null },
            .binding => |name| blk: {
                if (!try scope.put(name, .{
                    .ty = expected_type,
                    .kind = .local,
                    .mutable = false,
                })) {
                    try self.report(position, "duplicate pattern binding '{s}'", .{name});
                }
                break :blk .{ .matches_all = true, .constructor_name = null };
            },
            .integer => blk: {
                if (!expected_type.isBuiltin(.int)) {
                    try self.report(position, "integer pattern expects Int", .{});
                }
                break :blk .{ .matches_all = false, .constructor_name = null };
            },
            .float => blk: {
                if (!expected_type.isBuiltin(.float)) {
                    try self.report(position, "float pattern expects Float", .{});
                }
                break :blk .{ .matches_all = false, .constructor_name = null };
            },
            .bool => blk: {
                if (!expected_type.isBuiltin(.bool)) {
                    try self.report(position, "bool pattern expects Bool", .{});
                }
                break :blk .{ .matches_all = false, .constructor_name = null };
            },
            .symbol => .{ .matches_all = false, .constructor_name = null },
            .constructor => |constructor| blk: {
                const info = self.constructors.get(constructor.name) orelse {
                    try self.report(position, "unknown constructor '{s}'", .{constructor.name});
                    break :blk .{ .matches_all = false, .constructor_name = null };
                };

                if (constructor.args.len != info.field_types.len) {
                    try self.report(position, "constructor '{s}' expects {d} fields", .{ constructor.name, info.field_types.len });
                    break :blk .{ .matches_all = false, .constructor_name = null };
                }

                var substitution = unify.Substitution.init(self.allocator);
                defer substitution.deinit();
                unify.unify(&substitution, info.return_type, expected_type) catch {
                    try self.report(position, "constructor '{s}' does not match {s}", .{ constructor.name, expected_type.glslName() });
                    break :blk .{ .matches_all = false, .constructor_name = null };
                };

                for (constructor.args, info.field_types) |arg_pattern, field_type| {
                    const resolved_field_type = try substitution.apply(field_type);
                    _ = try self.bindPattern(scope, arg_pattern, resolved_field_type, position);
                }

                break :blk .{ .matches_all = false, .constructor_name = constructor.name };
            },
        };
    }

    fn typeInfoFor(self: *Analyzer, ty: types.Type) ?TypeDefInfo {
        return switch (ty) {
            .struct_type => |name| self.type_defs.get(name),
            .type_app => |app_ty| self.type_defs.get(app_ty.name),
            else => null,
        };
    }

    fn findFunction(
        self: *Analyzer,
        name: []const u8,
        arg_types: []const types.Type,
        functions: []const *ast.FunctionDef,
    ) ?types.Type {
        function_loop: for (functions) |function| {
            const signature = self.typed.function_signatures.get(function) orelse continue;
            if (!sameName(signature.name, name)) continue;
            if (signature.params.len != arg_types.len) continue;

            var substitution = unify.Substitution.init(self.allocator);
            defer substitution.deinit();

            for (signature.params, arg_types) |param, arg_type| {
                unify.unify(&substitution, param.ty, arg_type) catch continue :function_loop;
            }
            return substitution.apply(signature.return_type) catch signature.return_type;
        }
        return null;
    }

    fn resolveTypeName(self: *Analyzer, name: []const u8, position: ast.Position) anyerror!types.Type {
        return try self.resolveTypeNameWithParams(name, position, &.{});
    }

    fn resolveTypeNameWithParams(
        self: *Analyzer,
        name: []const u8,
        position: ast.Position,
        params: []const []const u8,
    ) anyerror!types.Type {
        var parser = TypeSpecParser{
            .analyzer = self,
            .input = name,
            .position = position,
            .params = params,
        };
        const resolved = try parser.parseType();
        parser.skipSpaces();
        if (!parser.eof()) {
            try self.report(position, "invalid type annotation '{s}'", .{name});
            return types.builtinType(.error_type);
        }
        return resolved;
    }

    fn resolveTypeNameCollectingParams(
        self: *Analyzer,
        name: []const u8,
        position: ast.Position,
        params: *std.ArrayListUnmanaged([]const u8),
    ) anyerror!types.Type {
        var parser = TypeSpecParser{
            .analyzer = self,
            .input = name,
            .position = position,
            .params = &.{},
            .param_sink = params,
        };
        const resolved = try parser.parseType();
        parser.skipSpaces();
        if (!parser.eof()) {
            try self.report(position, "invalid type annotation '{s}'", .{name});
            return types.builtinType(.error_type);
        }
        return resolved;
    }

    fn makeGenericType(self: *Analyzer, name: []const u8, params: []const []const u8) anyerror!types.Type {
        if (params.len == 0) return .{ .struct_type = name };

        const args = try self.allocator.alloc(types.Type, params.len);
        for (params, 0..) |_, index| {
            args[index] = types.typeVar(@intCast(index));
        }
        return .{
            .type_app = .{
                .name = name,
                .args = args,
            },
        };
    }

    fn typesCompatible(self: *Analyzer, expected: types.Type, actual: types.Type) bool {
        var substitution = unify.Substitution.init(self.allocator);
        defer substitution.deinit();
        unify.unify(&substitution, expected, actual) catch return false;
        return true;
    }

    fn rememberExprType(self: *Analyzer, expr: *ast.Expr, ty: types.Type) anyerror!void {
        try self.typed.expr_types.put(expr, ty);
    }

    fn report(self: *Analyzer, position: ast.Position, comptime fmt: []const u8, args: anytype) anyerror!void {
        try self.diagnostics.appendFmt(.@"error", position.line, position.column, fmt, args);
    }
};

const TypeSpecParser = struct {
    analyzer: *Analyzer,
    input: []const u8,
    index: usize = 0,
    position: ast.Position,
    params: []const []const u8,
    param_sink: ?*std.ArrayListUnmanaged([]const u8) = null,

    fn parseType(self: *TypeSpecParser) anyerror!types.Type {
        self.skipSpaces();
        if (self.eof()) return error.ParseFailed;

        if (std.ascii.isDigit(self.input[self.index])) {
            return .{ .nat = try self.parseNat() };
        }

        const name = try self.parseIdentifier();
        self.skipSpaces();
        if (self.matchChar('(')) {
            var args = std.ArrayListUnmanaged(types.Type){};
            defer args.deinit(self.analyzer.allocator);

            self.skipSpaces();
            if (!self.matchChar(')')) {
                while (true) {
                    try args.append(self.analyzer.allocator, try self.parseType());
                    self.skipSpaces();
                    if (self.matchChar(',')) {
                        self.skipSpaces();
                        continue;
                    }
                    if (!self.matchChar(')')) return error.ParseFailed;
                    break;
                }
            }
            return try self.finishApplication(name, args.items);
        }

        if (types.fromName(name)) |builtin| return builtin;
        if (self.paramIndex(name)) |id| return types.typeVar(id);
        if (self.analyzer.struct_fields.contains(name) or self.analyzer.type_defs.contains(name)) {
            return .{ .struct_type = name };
        }
        if (self.param_sink) |sink| {
            try sink.append(self.analyzer.allocator, name);
            return types.typeVar(@intCast(sink.items.len - 1));
        }
        try self.analyzer.report(self.position, "unknown type '{s}'", .{name});
        return types.builtinType(.error_type);
    }

    fn finishApplication(self: *TypeSpecParser, name: []const u8, args: []const types.Type) anyerror!types.Type {
        if (std.mem.eql(u8, name, "Vec") and args.len == 1 and args[0] == .nat) {
            return switch (args[0].nat) {
                2 => types.builtinType(.vec2),
                3 => types.builtinType(.vec3),
                4 => types.builtinType(.vec4),
                else => try types.typeApp(self.analyzer.allocator, name, args),
            };
        }

        if (std.mem.eql(u8, name, "Mat") and args.len == 2 and args[0] == .nat and args[1] == .nat and args[0].nat == args[1].nat) {
            return switch (args[0].nat) {
                2 => types.builtinType(.mat2),
                3 => types.builtinType(.mat3),
                4 => types.builtinType(.mat4),
                else => try types.typeApp(self.analyzer.allocator, name, args),
            };
        }

        if (!self.analyzer.struct_fields.contains(name) and !self.analyzer.type_defs.contains(name) and !std.mem.eql(u8, name, "Vec") and !std.mem.eql(u8, name, "Mat") and !std.mem.eql(u8, name, "Ten") and !std.mem.eql(u8, name, "Tensor")) {
            try self.analyzer.report(self.position, "unknown type '{s}'", .{name});
            return types.builtinType(.error_type);
        }
        return try types.typeApp(self.analyzer.allocator, name, args);
    }

    fn parseIdentifier(self: *TypeSpecParser) anyerror![]const u8 {
        const start = self.index;
        while (!self.eof()) {
            const ch = self.input[self.index];
            if (std.ascii.isAlphanumeric(ch) or ch == '_') {
                self.index += 1;
            } else {
                break;
            }
        }
        if (start == self.index) return error.ParseFailed;
        return self.input[start..self.index];
    }

    fn parseNat(self: *TypeSpecParser) anyerror!u32 {
        const start = self.index;
        while (!self.eof() and std.ascii.isDigit(self.input[self.index])) : (self.index += 1) {}
        return try std.fmt.parseInt(u32, self.input[start..self.index], 10);
    }

    fn paramIndex(self: *TypeSpecParser, name: []const u8) ?u32 {
        if (self.param_sink) |sink| {
            for (sink.items, 0..) |param, index| {
                if (sameName(param, name)) return @intCast(index);
            }
        }
        for (self.params, 0..) |param, index| {
            if (sameName(param, name)) return @intCast(index);
        }
        return null;
    }

    fn matchChar(self: *TypeSpecParser, ch: u8) bool {
        self.skipSpaces();
        if (self.eof() or self.input[self.index] != ch) return false;
        self.index += 1;
        return true;
    }

    fn skipSpaces(self: *TypeSpecParser) void {
        while (!self.eof() and std.ascii.isWhitespace(self.input[self.index])) : (self.index += 1) {}
    }

    fn eof(self: *TypeSpecParser) bool {
        return self.index >= self.input.len;
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
        .match_expr => |match_expr| {
            try collectExprIdentifiers(allocator, match_expr.value, names);
            for (match_expr.arms) |arm| {
                if (arm.guard) |guard| {
                    try collectExprIdentifiers(allocator, guard, names);
                }
                for (arm.body) |stmt| {
                    if (stmt.data == .expression) {
                        try collectExprIdentifiers(allocator, stmt.data.expression, names);
                    }
                }
            }
        },
        else => {},
    }
}
