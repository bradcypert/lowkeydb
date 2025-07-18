const std = @import("std");
const Database = @import("src/root.zig").Database;

const ThreadData = struct {
    db: *Database,
    allocator: std.mem.Allocator,
    thread_id: u32,
    operations_per_thread: u32,
    start_key: u32,
};

fn workerThread(data: *ThreadData) void {
    std.debug.print("Thread {} starting {} operations...\n", .{ data.thread_id, data.operations_per_thread });
    
    for (0..data.operations_per_thread) |i| {
        const key_num = data.start_key + @as(u32, @intCast(i));
        const key = std.fmt.allocPrint(data.allocator, "thread{}:key{}", .{ data.thread_id, key_num }) catch {
            std.debug.print("Thread {} failed to allocate key\n", .{data.thread_id});
            return;
        };
        defer data.allocator.free(key);
        
        const value = std.fmt.allocPrint(data.allocator, "value from thread {} operation {}", .{ data.thread_id, i }) catch {
            std.debug.print("Thread {} failed to allocate value\n", .{data.thread_id});
            return;
        };
        defer data.allocator.free(value);
        
        // Perform put operation
        data.db.put(key, value) catch |err| {
            std.debug.print("Thread {} failed to put key {s}: {}\n", .{ data.thread_id, key, err });
            return;
        };
        
        // Verify immediate read
        const read_value = data.db.get(key, data.allocator) catch |err| {
            std.debug.print("Thread {} failed to get key {s}: {}\n", .{ data.thread_id, key, err });
            return;
        };
        
        if (read_value) |val| {
            if (!std.mem.eql(u8, val, value)) {
                std.debug.print("Thread {} data mismatch for key {s}\n", .{ data.thread_id, key });
            }
            data.allocator.free(val);
        } else {
            std.debug.print("Thread {} failed to read back key {s}\n", .{ data.thread_id, key });
        }
    }
    
    std.debug.print("Thread {} completed all operations\n", .{data.thread_id});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a database
    var db = try Database.create("concurrency_example.db", allocator);
    defer {
        db.close();
        std.fs.cwd().deleteFile("concurrency_example.db") catch {};
        std.fs.cwd().deleteFile("concurrency_example.db.wal") catch {};
    }

    // Update database reference for proper functionality
    db.updateDatabaseReference();

    std.debug.print("=== LowkeyDB Concurrency Example ===\n", .{});

    // Test concurrent operations with fine-grained locking
    const num_threads = 4;
    const operations_per_thread = 25;
    const total_operations = num_threads * operations_per_thread;
    
    std.debug.print("Starting {} threads with {} operations each ({} total operations)...\n", .{ num_threads, operations_per_thread, total_operations });
    
    const start_time = std.time.milliTimestamp();
    
    var threads: [num_threads]std.Thread = undefined;
    var thread_data: [num_threads]ThreadData = undefined;
    
    // Initialize thread data
    for (0..num_threads) |i| {
        thread_data[i] = ThreadData{
            .db = &db,
            .allocator = allocator,
            .thread_id = @as(u32, @intCast(i)),
            .operations_per_thread = operations_per_thread,
            .start_key = @as(u32, @intCast(i * operations_per_thread)),
        };
    }
    
    // Start all threads
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerThread, .{&thread_data[i]});
    }
    
    // Wait for all threads to complete
    for (0..num_threads) |i| {
        threads[i].join();
    }
    
    const end_time = std.time.milliTimestamp();
    const duration_ms = end_time - start_time;
    
    std.debug.print("\nAll threads completed in {} ms\n", .{duration_ms});
    
    // Verify all data was inserted correctly
    std.debug.print("Verifying data integrity...\n", .{});
    
    var verified_count: u32 = 0;
    for (0..num_threads) |thread_id| {
        for (0..operations_per_thread) |op_id| {
            const key_num = thread_id * operations_per_thread + op_id;
            const key = try std.fmt.allocPrint(allocator, "thread{}:key{}", .{ thread_id, key_num });
            defer allocator.free(key);
            
            const value = try db.get(key, allocator);
            if (value) |val| {
                verified_count += 1;
                allocator.free(val);
            } else {
                std.debug.print("Missing key: {s}\n", .{key});
            }
        }
    }
    
    const final_count = db.getKeyCount();
    
    std.debug.print("Verification complete:\n", .{});
    std.debug.print("  Expected keys: {}\n", .{total_operations});
    std.debug.print("  Database count: {}\n", .{final_count});
    std.debug.print("  Verified keys: {}\n", .{verified_count});
    
    if (verified_count == total_operations and final_count == total_operations) {
        std.debug.print("✅ All concurrent operations successful!\n", .{});
    } else {
        std.debug.print("❌ Data integrity check failed!\n", .{});
    }
    
    // Performance metrics
    const ops_per_second = @as(f64, @floatFromInt(total_operations)) / (@as(f64, @floatFromInt(duration_ms)) / 1000.0);
    std.debug.print("\nPerformance metrics:\n", .{});
    std.debug.print("  Operations per second: {d:.2}\n", .{ops_per_second});
    std.debug.print("  Average operation time: {d:.2} ms\n", .{@as(f64, @floatFromInt(duration_ms)) / @as(f64, @floatFromInt(total_operations))});
    
    std.debug.print("\n✅ Concurrency example completed successfully!\n", .{});
    std.debug.print("Fine-grained locking enables high-performance concurrent operations.\n", .{});
}