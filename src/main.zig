const std = @import("std");
const tracker = @import("tracker.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mem_tracker = tracker.MemoryTracker.init(allocator);
    defer mem_tracker.deinit();

    const tracked_alloc = mem_tracker.allocator();

    std.debug.print("--- Block 1: Normal allocation ---\n", .{});
    const buf1 = try tracked_alloc.alloc(u8, 100);
    const buf2 = try tracked_alloc.alloc(u8, 250);
    
    if (mem_tracker.getAllocationInfo(buf1)) |info| {
        std.debug.print("Verified buf1 size: {d} bytes\n", .{info.size});
    }

    std.debug.print("Active allocations before free: {d}\n", .{mem_tracker.count()});
    tracked_alloc.free(buf1);
    std.debug.print("Active allocations after free: {d}\n", .{mem_tracker.count()});
    mem_tracker.printSummary();

    std.debug.print("\nResetting tracker...\n", .{});
    mem_tracker.reset();

    std.debug.print("--- Block 2: New tracking session ---\n", .{});
    const buf3 = try tracked_alloc.alloc(u8, 500);
    mem_tracker.printSummary();
    
    std.debug.print("\nRunning leak report (expecting buf2 and buf3 to be leaked)...\n", .{});
    // Note: buf2 is untracked now because of reset(), but still exists in memory
    mem_tracker.reportLeaks();
    
    tracked_alloc.free(buf3);
}