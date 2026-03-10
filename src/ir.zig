const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const types = @import("types.zig");

pub const Module = struct {
    version: []const u8 = "300 es",
    uniforms: []const Global = &.{},
    structs: []const StructDecl = &.{},
    global_functions: []const Function = &.{},
    vertex: ?Stage = null,
    fragment: ?Stage = null,
    compute: ?Stage = null,
};

pub const Global = struct {
    name: []const u8,
    ty: types.Type,
    location: ?u32 = null,
};

pub const StructField = struct {
    name: []const u8,
    ty: types.Type,
};

pub const StructDecl = struct {
    name: []const u8,
    fields: []const StructField,
};

pub const Param = struct {
    name: []const u8,
    ty: types.Type,
    is_inout: bool = false,
};

pub const Function = struct {
    name: []const u8,
    return_type: types.Type,
    params: []const Param,
    body: []const Statement,
    stage: ?ast.Stage = null,
    source_line: ?u32 = null,

    pub fn isMain(self: Function) bool {
        return std.mem.eql(u8, self.name, "main");
    }
};

pub const Stage = struct {
    stage: ast.Stage,
    precision: ?[]const u8 = null,
    inputs: []const Global = &.{},
    outputs: []const Global = &.{},
    varyings: []const Global = &.{},
    functions: []const Function = &.{},
};

pub const Statement = struct {
    source_line: ?u32 = null,
    data: Data,

    pub const Data = union(enum) {
        var_decl: VarDecl,
        assign: Assign,
        expr: *Expr,
        if_stmt: IfStmt,
        switch_stmt: SwitchStmt,
        return_stmt: ?*Expr,
        discard: void,
    };
};

pub const VarDecl = struct {
    name: []const u8,
    ty: types.Type,
    mutable: bool = true,
    value: ?*Expr = null,
};

pub const Assign = struct {
    target: *Expr,
    operator: token.TokenTag,
    value: *Expr,
};

pub const IfStmt = struct {
    condition: *Expr,
    then_body: []const Statement,
    else_body: []const Statement,
};

pub const SwitchCase = struct {
    value: i64,
    body: []const Statement,
};

pub const SwitchStmt = struct {
    selector: *Expr,
    cases: []const SwitchCase,
    default_body: []const Statement,
};

pub const Expr = struct {
    ty: types.Type,
    data: Data,

    pub const Data = union(enum) {
        integer: i64,
        float: f64,
        bool: bool,
        identifier: []const u8,
        unary: Unary,
        binary: Binary,
        call: Call,
        field: Field,
        index: Index,
    };

    pub const Unary = struct {
        operator: token.TokenTag,
        operand: *Expr,
    };

    pub const Binary = struct {
        operator: token.TokenTag,
        lhs: *Expr,
        rhs: *Expr,
    };

    pub const Call = struct {
        name: []const u8,
        args: []const *Expr,
    };

    pub const Field = struct {
        target: *Expr,
        name: []const u8,
    };

    pub const Index = struct {
        target: *Expr,
        index: *Expr,
    };
};
