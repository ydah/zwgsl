const std = @import("std");
const types = @import("types.zig");

pub const TraitMethod = struct {
    name: []const u8,
    params: []const types.Type,
    return_type: types.Type,
};

pub const TraitDef = struct {
    name: []const u8,
    methods: []const TraitMethod,
};

pub const TraitImpl = struct {
    trait_name: []const u8,
    for_type: types.Type,
};

pub const TraitRegistry = struct {
    allocator: std.mem.Allocator,
    traits: std.StringHashMap(TraitDef),
    impls: std.ArrayListUnmanaged(TraitImpl) = .{},

    pub fn init(allocator: std.mem.Allocator) TraitRegistry {
        return .{
            .allocator = allocator,
            .traits = std.StringHashMap(TraitDef).init(allocator),
        };
    }

    pub fn deinit(self: *TraitRegistry) void {
        self.traits.deinit();
        self.impls.deinit(self.allocator);
    }

    pub fn hasImpl(self: *const TraitRegistry, trait_name: []const u8, ty: types.Type) bool {
        for (self.impls.items) |impl_info| {
            if (std.mem.eql(u8, impl_info.trait_name, trait_name) and impl_info.for_type.eql(ty)) {
                return true;
            }
        }
        return false;
    }
};
