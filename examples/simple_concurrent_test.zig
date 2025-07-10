const std = @import("std");

// Note: To build this example, copy it to the project root and build with:
// zig build-exe simple_concurrent_test.zig -I src/
const Database = @import("src/database.zig").Database;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Simple Concurrent Test ===\n", .{});
    
    // Create database
    var db = try Database.create("simple_concurrent.db", allocator);
    defer {
        db.close();
        std.fs.cwd().deleteFile("simple_concurrent.db") catch {};
    }

    // Test just 2 threads with 2 operations each to isolate the issue
    var thread1 = try std.Thread.spawn(.{}, simpleWorker, .{ &db, allocator, 1 });
    var thread2 = try std.Thread.spawn(.{}, simpleWorker, .{ &db, allocator, 2 });
    
    thread1.join();
    thread2.join();
    
    std.debug.print("Final key count: {}\n", .{db.getKeyCount()});
    
    // Check all keys
    const keys = [_][]const u8{ "key_1_0", "key_1_1", "key_2_0", "key_2_1" };
    for (keys) |key| {
        const result = db.get(key, allocator) catch |err| {
            std.debug.print("Error getting {s}: {}\n", .{ key, err });
            continue;
        };
        
        if (result) |value| {
            defer allocator.free(value);
            std.debug.print("Found {s} = {s}\n", .{ key, value });
        } else {
            std.debug.print("Missing: {s}\n", .{key});
        }
    }
}

fn simpleWorker(db: *Database, allocator: std.mem.Allocator, thread_id: usize) !void {
    for (0..2) |i| {
        var key_buf: [16]u8 = undefined;
        var value_buf: [16]u8 = undefined;
        
        const key = try std.fmt.bufPrint(&key_buf, "key_{}_{}", .{ thread_id, i });
        const value = try std.fmt.bufPrint(&value_buf, "val_{}_{}", .{ thread_id, i });
        
        std.debug.print("Thread {} inserting {s}\n", .{ thread_id, key });
        
        db.put(key, value) catch |err| {
            std.debug.print("Thread {} put error: {}\n", .{ thread_id, err });
            return;
        };
        
        // Verify immediately
        const result = db.get(key, allocator) catch |err| {
            std.debug.print("Thread {} get error for {s}: {}\n", .{ thread_id, key, err });
            return;
        };
        
        if (result) |retrieved| {
            defer allocator.free(retrieved);
            std.debug.print("Thread {} verified {s} = {s}\n", .{ thread_id, key, retrieved });
        } else {
            std.debug.print("Thread {} FAILED to retrieve {s}\n", .{ thread_id, key });
        }
    }
}