const token = @import("token.zig");

pub const Position = struct {
    line: u32,
    column: u32,
};

pub const Program = struct {
    items: []const Item,
};

pub const Stage = enum {
    vertex,
    fragment,
    compute,
};

pub const VersionDecl = struct {
    position: Position,
    value: []const u8,
};

pub const PrecisionDecl = struct {
    position: Position,
    stage: []const u8,
    precision: []const u8,
};

pub const UniformDecl = struct {
    position: Position,
    name: []const u8,
    type_name: []const u8,
};

pub const IoDecl = struct {
    position: Position,
    name: []const u8,
    type_name: []const u8,
    location: ?u32 = null,
};

pub const StructField = struct {
    position: Position,
    name: []const u8,
    type_name: []const u8,
};

pub const StructDef = struct {
    position: Position,
    name: []const u8,
    fields: []const StructField,
};

pub const Param = struct {
    position: Position,
    name: []const u8,
    type_name: []const u8,
    is_inout: bool = false,
};

pub const FunctionDef = struct {
    position: Position,
    name: []const u8,
    params: []const Param,
    return_type: ?[]const u8,
    body: []const *Stmt,
    where_clause: ?WhereClause = null,
};

pub const LetBinding = struct {
    position: Position,
    name: []const u8,
    type_name: ?[]const u8 = null,
    value: *Expr,
};

pub const WhereClause = struct {
    position: Position,
    bindings: []const LetBinding,
};

pub const ShaderBlock = struct {
    position: Position,
    stage: Stage,
    items: []const StageItem,
};

pub const Item = union(enum) {
    version: VersionDecl,
    precision: PrecisionDecl,
    uniform: UniformDecl,
    struct_def: StructDef,
    function: *FunctionDef,
    shader_block: *ShaderBlock,
};

pub const StageItem = union(enum) {
    input: IoDecl,
    output: IoDecl,
    varying: IoDecl,
    function: *FunctionDef,
    precision: PrecisionDecl,
};

pub const Branch = struct {
    condition: *Expr,
    body: []const *Stmt,
};

pub const Assignment = struct {
    target: *Expr,
    operator: token.TokenTag,
    value: *Expr,
};

pub const TypedAssignment = struct {
    name: []const u8,
    type_name: []const u8,
    value: *Expr,
};

pub const IfStmt = struct {
    branches: []const Branch,
    else_body: []const *Stmt,
    negate_first: bool = false,
};

pub const ConditionalStmt = struct {
    condition: *Expr,
    body: *Stmt,
    negate: bool = false,
};

pub const TimesLoop = struct {
    count: *Expr,
    binding: ?[]const u8,
    body: []const *Stmt,
};

pub const EachLoop = struct {
    collection: *Expr,
    binding: ?[]const u8,
    body: []const *Stmt,
};

pub const Stmt = struct {
    position: Position,
    data: Data,

    pub const Data = union(enum) {
        expression: *Expr,
        let_binding: LetBinding,
        assignment: Assignment,
        typed_assignment: TypedAssignment,
        return_stmt: ?*Expr,
        discard: void,
        if_stmt: IfStmt,
        conditional: ConditionalStmt,
        times_loop: TimesLoop,
        each_loop: EachLoop,
    };
};

pub const Expr = struct {
    position: Position,
    data: Data,

    pub const Data = union(enum) {
        integer: i64,
        float: f64,
        bool: bool,
        string: []const u8,
        symbol: []const u8,
        identifier: []const u8,
        self_ref: void,
        unary: Unary,
        binary: Binary,
        member: Member,
        call: Call,
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

    pub const Member = struct {
        target: *Expr,
        name: []const u8,
    };

    pub const Call = struct {
        callee: *Expr,
        args: []const *Expr,
    };

    pub const Index = struct {
        target: *Expr,
        index: *Expr,
    };
};
