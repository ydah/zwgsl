const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const types = @import("types.zig");

pub const BindingKind = enum {
    uniform,
    texture,
    sampler,
};

pub const Binding = struct {
    name: []const u8,
    ty: types.Type,
    kind: BindingKind,
    group: u32 = 0,
    binding: u32,
    source_line: ?u32 = null,
    source_column: ?u32 = null,
};

pub const Module = struct {
    version: []const u8 = "300 es",
    uniforms: []const Global = &.{},
    bindings: []const Binding = &.{},
    structs: []const StructDecl = &.{},
    global_functions: []const Function = &.{},
    entry_points: []const EntryPoint = &.{},

    pub fn entryPoint(self: *const Module, stage: ast.Stage) ?EntryPoint {
        for (self.entry_points) |entry_point| {
            if (entry_point.stage == stage) return entry_point;
        }
        return null;
    }
};

pub const Global = struct {
    name: []const u8,
    ty: types.Type,
    location: ?u32 = null,
    source_line: ?u32 = null,
    source_column: ?u32 = null,
};

pub const StructField = struct {
    name: []const u8,
    ty: types.Type,
    source_line: ?u32 = null,
    source_column: ?u32 = null,
};

pub const StructDecl = struct {
    name: []const u8,
    fields: []const StructField,
    source_line: ?u32 = null,
    source_column: ?u32 = null,
};

pub const StageInterface = struct {
    inputs: []const Global = &.{},
    outputs: []const Global = &.{},
    varyings: []const Global = &.{},
};

pub const Param = struct {
    name: []const u8,
    ty: types.Type,
    is_inout: bool = false,
    source_line: ?u32 = null,
    source_column: ?u32 = null,
};

pub const Function = struct {
    name: []const u8,
    return_type: types.Type,
    params: []const Param,
    entry_block: []const u8,
    blocks: []const BasicBlock,
    stage: ?ast.Stage = null,
    source_line: ?u32 = null,
    source_column: ?u32 = null,

    pub fn isMain(self: Function) bool {
        return std.mem.eql(u8, self.name, "main");
    }
};

pub const EntryPoint = struct {
    stage: ast.Stage,
    precision: ?[]const u8 = null,
    interface: StageInterface = .{},
    functions: []const Function = &.{},
    main_function_index: usize = 0,
    source_line: ?u32 = null,
    source_column: ?u32 = null,

    pub fn mainFunction(self: EntryPoint) Function {
        return self.functions[self.main_function_index];
    }
};

pub const BasicBlock = struct {
    label: []const u8,
    instructions: []const Instruction,
    terminator: Terminator = .{ .none = {} },
    source_line: ?u32 = null,
    source_column: ?u32 = null,
};

pub const Instruction = struct {
    result: ?Result = null,
    source_line: ?u32 = null,
    source_column: ?u32 = null,
    data: Data,

    pub const Result = struct {
        name: []const u8,
        ty: types.Type,
    };

    pub const Data = union(enum) {
        phi: Phi,
        local_alloc: LocalAlloc,
        copy: Copy,
        load: *Place,
        store: Store,
        unary: Unary,
        binary: Binary,
        call: Call,
        field: ValueField,
        index: ValueIndex,
    };
};

pub const LocalAlloc = struct {
    name: []const u8,
    ty: types.Type,
    mutable: bool = true,
    init: ?*Value = null,
};

pub const Copy = struct {
    value: *Value,
};

pub const PhiIncoming = struct {
    label: []const u8,
    value: *Value,
};

pub const Phi = struct {
    incomings: []const PhiIncoming,
};

pub const Terminator = union(enum) {
    none: void,
    jump: []const u8,
    return_stmt: ?*Value,
    discard: void,
    if_term: IfTerm,
    switch_term: SwitchTerm,
};

pub const IfTerm = struct {
    condition: *Value,
    then_block: []const u8,
    else_block: []const u8,
    merge_block: []const u8,
};

pub const SwitchTarget = struct {
    value: i64,
    block: []const u8,
    source_line: ?u32 = null,
    source_column: ?u32 = null,
};

pub const SwitchTerm = struct {
    selector: *Value,
    cases: []const SwitchTarget,
    default_block: []const u8,
    merge_block: []const u8,
};

pub const Value = struct {
    ty: types.Type,
    source_line: ?u32 = null,
    source_column: ?u32 = null,
    data: Data,

    pub const Data = union(enum) {
        integer: i64,
        float: f64,
        bool: bool,
        identifier: []const u8,
    };
};

pub const Place = struct {
    ty: types.Type,
    source_line: ?u32 = null,
    source_column: ?u32 = null,
    data: Data,

    pub const Data = union(enum) {
        identifier: []const u8,
        field: Field,
        index: Index,
    };

    pub const Field = struct {
        target: *Place,
        name: []const u8,
    };

    pub const Index = struct {
        target: *Place,
        index: *Value,
    };
};

pub const Store = struct {
    target: *Place,
    value: *Value,
};

pub const Unary = struct {
    operator: token.TokenTag,
    operand: *Value,
};

pub const Binary = struct {
    operator: token.TokenTag,
    lhs: *Value,
    rhs: *Value,
};

pub const Call = struct {
    name: []const u8,
    args: []const *Value,
};

pub const ValueField = struct {
    target: *Value,
    name: []const u8,
};

pub const ValueIndex = struct {
    target: *Value,
    index: *Value,
};

pub fn resultValue(
    allocator: std.mem.Allocator,
    result: Instruction.Result,
    source_line: ?u32,
    source_column: ?u32,
) !*Value {
    const value = try allocator.create(Value);
    value.* = .{
        .ty = result.ty,
        .source_line = source_line,
        .source_column = source_column,
        .data = .{ .identifier = result.name },
    };
    return value;
}
