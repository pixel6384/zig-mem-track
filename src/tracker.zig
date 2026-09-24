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

    /// Returns a std.mem.Allocator that wraps the tracker
    pub fn allocator(self: *MemoryTracker) std.mem.Allocator {
        return .{ 
            .ptr = self, 
            .vtable = &std.mem.Allocator.VTable {
                .alloc = alloc,
                .resize = realloc,
                .free = free,
            }
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *MemoryTracker = @ptrCast(@alignCast(ctx));
        
        // Note: In a real-world scenario, we'd use ret_addr to resolve file/line
        // via debug symbols. For this library, we provide a manual helper or
        // mark it as "unknown" when using the generic interface.
        const bytes = self.allocator.allocWithOptions(u8, ptr_align, len) catch return null;
        const ptr = @intFromPtr(bytes.ptr);
        
        self.allocations.put(ptr, .{ 
            .ptr = ptr, 
            .size = len, 
            .line = 0, 
            .file = "unknown" 
        }) catch return null;
        
        self.total_allocated += len;
        return bytes.ptr;
    }

    fn realloc(ctx: *anyopaque, ptr: [*]u8, ptr_align: u8, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *MemoryTracker = @ptrCast(@alignCast(ctx));
        const old_ptr = @intFromPtr(ptr);
        
        const old_slice = ptr[0..0] ++ ptr[0..0]; // This is a simplification for the interface
        // Since the VTable resize provides a pointer, we must treat it carefully
        // In this implementation, we leverage the internal allocator's realloc
        
        // We first find the old size to update totals
        if (self.allocations.get(old_ptr)) |info| {
            self.total_freed += info.size;
        }

        const new_ptr = self.allocator.reallocWithOptions(u8, ptr_align, ptr[0..0], new_len) catch return null;
        const new_ptr_val = @intFromPtr(new_ptr.ptr);

        _ = self.allocations.remove(old_ptr);
        
        self.allocations.put(new_ptr_val, .{ 
            .ptr = new_ptr_val, 
            .size = new_len, 
            .line = 0, 
            .file = "unknown" 
        }) catch return null;
        
        self.total_allocated += new_len;
        return new_ptr.ptr;
    }

    fn free(ctx: *anyopaque, ptr: [*]u8, ptr_align: u8, ret_addr: usize) void {
        const self: *MemoryTracker = @ptrCast(@alignCast(ctx));
        const ptr_val = @intFromPtr(ptr);
        
        if (self.allocations.remove(ptr_val)) |info| {
            self.total_freed += info.size;
            // We must reconstruct a slice for the underlying allocator
            self.allocator.free(ptr[0..info.size]);
        } else {
            std.debug.print("Warning: Attempted to free untracked pointer at 0x{x}\n", .{ptr_val});
        }
    }

    pub fn alloc_tracked(self: *MemoryTracker, size: usize, alignment: u8, file: []const u8, line: u32) ![]u8 {
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

    pub fn realloc_tracked(self: *MemoryTracker, bytes: []u8, alignment: u8, new_size: usize, file: []const u8, line: u32) ![]u8 {
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

    pub fn free_tracked(self: *MemoryTracker, bytes: []u8, file: []const u8, line: u32) void {
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