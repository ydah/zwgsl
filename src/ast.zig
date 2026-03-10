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
    params: []const []const u8 = &.{},
    fields: []const StructField,
};

pub const VariantField = struct {
    position: Position,
    name: []const u8,
    type_name: []const u8,
};

pub const Variant = struct {
    position: Position,
    name: []const u8,
    fields: []const VariantField,
};

pub const TypeDef = struct {
    position: Position,
    name: []const u8,
    params: []const []const u8,
    variants: []const Variant,
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
    constraints: []const TypeConstraint = &.{},
    body: []const *Stmt,
    where_clause: ?WhereClause = null,
};

pub const TypeConstraint = struct {
    position: Position,
    param_name: []const u8,
    trait_name: []const u8,
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

pub const TraitDef = struct {
    position: Position,
    name: []const u8,
    methods: []const *FunctionDef,
};

pub const ImplDef = struct {
    position: Position,
    trait_name: []const u8,
    for_type_name: []const u8,
    methods: []const *FunctionDef,
};

pub const Item = union(enum) {
    version: VersionDecl,
    precision: PrecisionDecl,
    uniform: UniformDecl,
    struct_def: StructDef,
    type_def: TypeDef,
    trait_def: TraitDef,
    impl_def: ImplDef,
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
        lambda: Lambda,
        match_expr: MatchExpr,
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

    pub const Lambda = struct {
        params: []const []const u8,
        body: *Expr,
    };

    pub const MatchExpr = struct {
        value: *Expr,
        arms: []const MatchArm,
    };
};

pub const MatchArm = struct {
    pattern: Pattern,
    guard: ?*Expr = null,
    body: []const *Stmt,
};

pub const Pattern = union(enum) {
    constructor: ConstructorPattern,
    wildcard: void,
    binding: []const u8,
    integer: i64,
    float: f64,
    bool: bool,
    symbol: []const u8,
};

pub const ConstructorPattern = struct {
    name: []const u8,
    args: []const Pattern,
};
