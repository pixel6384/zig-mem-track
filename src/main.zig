const std = @import("std");
const tracker = @import("tracker.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mem_tracker = tracker.MemoryTracker.init(allocator);
    defer mem_tracker.deinit();

    const tracked_alloc = mem_tracker.allocator();

    std.debug.print("Allocating memory using tracked allocator...\n", .{});

    // Use as a standard allocator
    const buf1 = try tracked_alloc.alloc(u8, 100);
    const buf2 = try tracked_alloc.alloc(u8, 250);

    std.debug.print("Reallocating buf1...\n", .{});
    const buf1_new = try tracked_alloc.realloc(buf1, 200);

    std.debug.print("Freeing some memory...\n", .{});
    tracked_alloc.free(buf1_new);

    // We can still use the manual tracking for better file/line info
    const buf3 = try mem_tracker.alloc_tracked(50, 8, "main.zig", 30);
    mem_tracker.free_tracked(buf3, "main.zig", 31);

    // Intentional leak: buf2 is not freed
    
    mem_tracker.printSummary();
    std.debug.print("Running leak report...\n", .{});
    mem_tracker.reportLeaks();
}