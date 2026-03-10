const std = @import("std");

pub const DocumentStore = struct {
    allocator: std.mem.Allocator,
    documents: std.StringHashMap([]u8),

    pub fn init(allocator: std.mem.Allocator) DocumentStore {
        return .{
            .allocator = allocator,
            .documents = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *DocumentStore) void {
        var iterator = self.documents.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.documents.deinit();
    }

    pub fn put(self: *DocumentStore, uri: []const u8, text: []const u8) !void {
        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);

        if (self.documents.fetchRemove(uri)) |existing| {
            self.allocator.free(existing.key);
            self.allocator.free(existing.value);
        }
        try self.documents.put(owned_uri, owned_text);
    }

    pub fn remove(self: *DocumentStore, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |existing| {
            self.allocator.free(existing.key);
            self.allocator.free(existing.value);
        }
    }

    pub fn get(self: *const DocumentStore, uri: []const u8) ?[]const u8 {
        return self.documents.get(uri);
    }
};
