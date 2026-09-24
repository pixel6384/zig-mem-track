const std = @import("std");

pub const AllocationInfo = struct {
    ptr: usize,
    size: usize,
    line: u32,
    file: []const u8,
};

pub const MemoryTracker = struct {
    allocator: std.mem.Allocator,
    allocations: std.AutoHashMap(usize, AllocationInfo),
    total_allocated: usize,
    total_freed: usize,

    pub fn init(allocator: std.mem.Allocator) MemoryTracker {
        return .{
            .allocator = allocator,
            .allocations = std.AutoHashMap(usize, AllocationInfo).init(allocator),
            .total_allocated = 0,
            .total_freed = 0,
        };
    }

    pub fn deinit(self: *MemoryTracker) void {
        self.allocations.deinit();
    }

    pub fn alloc(self: *MemoryTracker, size: usize, alignment: u8, file: []const u8, line: u32) ![]u8 {
        const bytes = try self.allocator.allocWithOptions(u8, alignment, size);
        const ptr = @intFromPtr(bytes.ptr);
        
        try self.allocations.put(ptr, .{ 
            .ptr = ptr, 
            .size = size, 
            .line = line, 
            .file = file 
        });
        
        self.total_allocated += size;
        return bytes;
    }

    pub fn realloc(self: *MemoryTracker, bytes: []u8, alignment: u8, new_size: usize, file: []const u8, line: u32) ![]u8 {
        const old_ptr = @intFromPtr(bytes.ptr);
        const new_bytes = try self.allocator.reallocWithOptions(u8, alignment, bytes, new_size);
        const new_ptr = @intFromPtr(new_bytes.ptr);

        if (self.allocations.remove(old_ptr)) |old_info| {
            self.total_freed += old_info.size;
        } else {
            std.debug.print("Warning: Reallocating untracked pointer at {s}:{d}\n", .{ file, line });
        }

        try self.allocations.put(new_ptr, .{ 
            .ptr = new_ptr, 
            .size = new_size, 
            .line = line, 
            .file = file 
        });
        
        self.total_allocated += new_size;
        return new_bytes;
    }

    pub fn free(self: *MemoryTracker, bytes: []u8, file: []const u8, line: u32) void {
        const ptr = @intFromPtr(bytes.ptr);
        if (self.allocations.remove(ptr)) |info| {
            self.total_freed += info.size;
            self.allocator.free(bytes);
        } else {
            std.debug.print("Warning: Attempted to free untracked pointer at {s}:{d}\n", .{ file, line });
        }
    }

    pub fn printSummary(self: *MemoryTracker) void {
        const current_usage = self.total_allocated - self.total_freed;
        std.debug.print("--- Memory Summary ---\n", .{});
        std.debug.print("Total Allocated: {d} bytes\n", .{self.total_allocated});
        std.debug.print("Total Freed:     {d} bytes\n", .{self.total_freed});
        std.debug.print("Current Usage:   {d} bytes\n", .{current_usage});
        std.debug.print("Active Allocs:   {d}\n", .{self.allocations.count()});
        std.debug.print("----------------------\n", .{});
    }

    pub fn reportLeaks(self: *MemoryTracker) void {
        if (self.allocations.count() == 0) {
            std.debug.print("No memory leaks detected.\n", .{});
            return;
        }

        std.debug.print("--- Memory Leak Report ---\n", .{});
        var total_leaked: usize = 0;
        var it = self.allocations.iterator();
        while (it.next()) |entry| {
            const info = entry.value_ptr.*;
            std.debug.print("Leak: {d} bytes at address 0x{x} (allocated at {s}:{d})\n", .{ 
                info.size, info.ptr, info.file, info.line 
            });
            total_leaked += info.size;
        }
        std.debug.print("Total leaked: {d} bytes ({d} allocations)\n", .{total_leaked, self.allocations.count()});
    }
};