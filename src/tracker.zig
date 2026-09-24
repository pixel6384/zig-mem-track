const std = @import("std");

pub const AllocationInfo = struct {
    ptr: usize,
    size: usize,
    line: u32,
    file: []const u8,
    ret_addr: usize,
};

pub const MemoryTracker = struct {
    allocator: std.mem.Allocator,
    allocations: std.AutoHashMap(usize, AllocationInfo),
    total_allocated: usize,
    total_freed: usize,
    peak_usage: usize,

    pub fn init(allocator: std.mem.Allocator) MemoryTracker {
        return .{
            .allocator = allocator,
            .allocations = std.AutoHashMap(usize, AllocationInfo).init(allocator),
            .total_allocated = 0,
            .total_freed = 0,
            .peak_usage = 0,
        };
    }

    pub fn deinit(self: *MemoryTracker) void {
        self.allocations.deinit();
    }

    pub fn count(self: *MemoryTracker) usize {
        return self.allocations.count();
    }

    /// Resets the tracker state. Warning: This does not free existing allocations,
    /// it only clears the tracking metadata. Use with caution.
    pub fn reset(self: *MemoryTracker) void {
        self.allocations.clear();
        self.total_allocated = 0;
        self.total_freed = 0;
        self.peak_usage = 0;
    }

    fn updatePeak(self: *MemoryTracker) void {
        const current_usage = self.total_allocated - self.total_freed;
        if (current_usage > self.peak_usage) {
            self.peak_usage = current_usage;
        }
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
        
        const bytes = self.allocator.allocWithOptions(u8, ptr_align, len) catch return null;
        const ptr = @intFromPtr(bytes.ptr);
        
        self.allocations.put(ptr, .{ 
            .ptr = ptr, 
            .size = len, 
            .line = 0, 
            .file = "unknown",
            .ret_addr = ret_addr,
        }) catch return null;
        
        self.total_allocated += len;
        self.updatePeak();
        return bytes.ptr;
    }

    fn realloc(ctx: *anyopaque, ptr: [*]u8, ptr_align: u8, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *MemoryTracker = @ptrCast(@alignCast(ctx));
        const old_ptr_val = @intFromPtr(ptr);
        
        // Find old size to calculate total_freed correctly
        const old_size = if (self.allocations.get(old_ptr_val)) |info| info.size else 0;

        // The VTable resize method requires us to pass the original pointer and current length
        // to the underlying allocator. Since we track size in the map, we use that.
        const old_slice = ptr[0..old_size];
        const new_ptr_slice = self.allocator.reallocWithOptions(u8, ptr_align, old_slice, new_len) catch return null;
        
        const new_ptr_val = @intFromPtr(new_ptr_slice.ptr);

        _ = self.allocations.remove(old_ptr_val);
        
        self.allocations.put(new_ptr_val, .{ 
            .ptr = new_ptr_val, 
            .size = new_len, 
            .line = 0, 
            .file = "unknown",
            .ret_addr = ret_addr,
        }) catch return null;
        
        self.total_freed += old_size;
        self.total_allocated += new_len;
        self.updatePeak();
        return new_ptr_slice.ptr;
    }

    fn free(ctx: *anyopaque, ptr: [*]u8, ptr_align: u8, ret_addr: usize) void {
        const self: *MemoryTracker = @ptrCast(@alignCast(ctx));
        const ptr_val = @intFromPtr(ptr);
        
        if (self.allocations.remove(ptr_val)) |info| {
            self.total_freed += info.size;
            self.allocator.free(ptr[0..info.size]);
        } else {
            std.debug.print("Warning: Attempted to free untracked pointer at 0x{x} (from 0x{x})\n", .{ptr_val, ret_addr});
        }
    }

    pub fn alloc_tracked(self: *MemoryTracker, size: usize, alignment: u8, file: []const u8, line: u32) ![]u8 {
        const bytes = try self.allocator.allocWithOptions(u8, alignment, size);
        const ptr = @intFromPtr(bytes.ptr);
        
        try self.allocations.put(ptr, .{ 
            .ptr = ptr, 
            .size = size, 
            .line = line, 
            .file = file, 
            .ret_addr = 0,
        });
        
        self.total_allocated += size;
        self.updatePeak();
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
            .file = file, 
            .ret_addr = 0,
        });
        
        self.total_allocated += new_size;
        self.updatePeak();
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
        std.debug.print("Peak Usage:      {d} bytes\n", .{self.peak_usage});
        std.debug.print("Active Allocs:   {d}\n", .{self.count()});
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
            if (std.mem.eq(u8, info.file, "unknown")) {
                std.debug.print("Leak: {d} bytes at address 0x{x} (allocated at return addr 0x{x})\n", .{ 
                    info.size, info.ptr, info.ret_addr 
                });
            } else {
                std.debug.print("Leak: {d} bytes at address 0x{x} (allocated at {s}:{d})\n", .{ 
                    info.size, info.ptr, info.file, info.line 
                });
            }
            total_leaked += info.size;
        }
        std.debug.print("Total leaked: {d} bytes ({d} allocations)\n", .{total_leaked, self.allocations.count()});
    }
};