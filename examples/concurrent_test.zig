const std = @import("std");

// Note: To build this example, copy it to the project root and build with:
// zig build-exe concurrent_test.zig -I src/
const Database = @import("src/database.zig").Database;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Concurrent Database Test ===\n", .{});
    
    // Create database
    var db = try Database.create("concurrent_test.db", allocator);
    defer {
        db.close();
        std.fs.cwd().deleteFile("concurrent_test.db") catch {};
    }

    // Test concurrent operations
    const num_threads = 4;
    const operations_per_thread = 10;
    
    std.debug.print("Starting {} threads with {} operations each...\n", .{ num_threads, operations_per_thread });
    
    var threads: [num_threads]std.Thread = undefined;
    
    // Start worker threads
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerThread, .{ &db, allocator, i, operations_per_thread });
    }
    
    // Wait for all threads to complete
    for (0..num_threads) |i| {
        threads[i].join();
    }
    
    std.debug.print("All threads completed!\n", .{});
    std.debug.print("Final key count: {}\n", .{db.getKeyCount()});
    
    // Verify some of the inserted data
    std.debug.print("Verifying inserted data...\n", .{});
    for (0..num_threads) |thread_id| {
        for (0..operations_per_thread) |op_id| {
            var key_buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "thread{}_key{}", .{ thread_id, op_id });
            
            const result = db.get(key, allocator) catch |err| {
                std.debug.print("Error getting {s}: {}\n", .{ key, err });
                continue;
            };
            
            if (result) |value| {
                defer allocator.free(value);
                var expected_buffer: [32]u8 = undefined;
                const expected = try std.fmt.bufPrint(&expected_buffer, "value{}", .{op_id});
                
                if (!std.mem.eql(u8, value, expected)) {
                    std.debug.print("Value mismatch for {s}: got '{s}', expected '{s}'\n", .{ key, value, expected });
                }
            } else {
                std.debug.print("Key not found: {s}\n", .{key});
            }
        }
    }
    
    std.debug.print("Concurrent test completed successfully!\n", .{});
}

fn workerThread(db: *Database, allocator: std.mem.Allocator, thread_id: usize, num_operations: usize) !void {
    std.debug.print("Thread {} starting...\n", .{thread_id});
    
    for (0..num_operations) |i| {
        // Create unique keys for this thread
        var key_buffer: [32]u8 = undefined;
        var value_buffer: [32]u8 = undefined;
        
        const key = try std.fmt.bufPrint(&key_buffer, "thread{}_key{}", .{ thread_id, i });
        const value = try std.fmt.bufPrint(&value_buffer, "value{}", .{i});
        
        // Insert key-value pair
        db.put(key, value) catch |err| {
            std.debug.print("Thread {} put error: {}\n", .{ thread_id, err });
            continue;
        };
        
        // Immediately try to read it back
        const result = db.get(key, allocator) catch |err| {
            std.debug.print("Thread {} get error: {}\n", .{ thread_id, err });
            continue;
        };
        
        if (result) |retrieved_value| {
            defer allocator.free(retrieved_value);
            if (!std.mem.eql(u8, retrieved_value, value)) {
                std.debug.print("Thread {} value mismatch!\n", .{thread_id});
            }
        } else {
            std.debug.print("Thread {} could not retrieve key immediately after put!\n", .{thread_id});
        }
        
        // Small delay to allow interleaving
        std.time.sleep(1000000); // 1ms
    }
    
    std.debug.print("Thread {} completed\n", .{thread_id});
}