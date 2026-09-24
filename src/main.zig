const std = @import("std");
const tracker = @import("tracker.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mem_tracker = tracker.MemoryTracker.init(allocator);
    defer mem_tracker.deinit();

    std.debug.print("Allocating memory...\n", .{});

    // Simulate some allocations
    var buf1 = try mem_tracker.alloc(100, 8, "main.zig", 15);
    const buf2 = try mem_tracker.alloc(250, 8, "main.zig", 16);

    std.debug.print("Reallocating buf1...\n", .{});
    buf1 = try mem_tracker.realloc(buf1, 8, 200, "main.zig", 21);

    std.debug.print("Freeing some memory...\n", .{});
    mem_tracker.free(buf1, "main.zig", 24);

    // Intentional leak: buf2 is not freed
    
    mem_tracker.printSummary();
    std.debug.print("Running leak report...\n", .{});
    mem_tracker.reportLeaks();
}