const std = @import("std");
const Database = @import("src/root.zig").Database;

const BenchmarkResult = struct {
    name: []const u8,
    operations: u32,
    duration_ms: i64,
    ops_per_sec: u32,
    memory_used_mb: f64,
    
    pub fn print(self: *const BenchmarkResult) void {
        std.debug.print("  {s}: {} ops in {}ms = {} ops/sec (Memory: {d:.1}MB)\n", .{
            self.name, self.operations, self.duration_ms, self.ops_per_sec, self.memory_used_mb
        });
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("=== LowkeyDB Performance Benchmark Suite ===\n", .{});
    
    var results = std.ArrayList(BenchmarkResult).init(allocator);
    defer results.deinit();
    
    // Benchmark 1: Sequential Insertions
    {
        std.debug.print("\n--- Benchmark 1: Sequential Insertions ---\n", .{});
        
        var db = try Database.create("benchmark_sequential.db", allocator);
        defer {
            db.close();
            cleanupFile("benchmark_sequential.db");
        }
        db.updateDatabaseReference();
        
        const operations = 10000;
        const start_time = std.time.milliTimestamp();
        
        for (0..operations) |i| {
            const tx = try db.beginTransaction(.read_committed);
            const key = try std.fmt.allocPrint(allocator, "seq_key_{:08}", .{i});
            defer allocator.free(key);
            const value = try std.fmt.allocPrint(allocator, "seq_value_{:08}_with_some_data", .{i});
            defer allocator.free(value);
            
            try db.putTransaction(tx, key, value);
            try db.commitTransaction(tx);
        }
        
        const end_time = std.time.milliTimestamp();
        const duration = end_time - start_time;
        const ops_per_sec = if (duration > 0) @as(u32, @intCast((operations * 1000) / @as(u32, @intCast(duration)))) else 0;
        
        const stats = db.getBufferPoolStats();
        const memory_mb = @as(f64, @floatFromInt(stats.pages_in_buffer * 4096)) / (1024.0 * 1024.0);
        
        try results.append(BenchmarkResult{
            .name = "Sequential Insertions",
            .operations = operations,
            .duration_ms = duration,
            .ops_per_sec = ops_per_sec,
            .memory_used_mb = memory_mb,
        });
        
        std.debug.print("Buffer pool hit ratio: {d:.1}%\n", .{stats.hit_ratio * 100});
        std.debug.print("Buffer pool evictions: {}\n", .{stats.evictions});
    }
    
    // Benchmark 2: Random Insertions
    {
        std.debug.print("\n--- Benchmark 2: Random Insertions ---\n", .{});
        
        var db = try Database.create("benchmark_random.db", allocator);
        defer {
            db.close();
            cleanupFile("benchmark_random.db");
        }
        db.updateDatabaseReference();
        
        const operations = 5000;
        var rng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const random = rng.random();
        
        const start_time = std.time.milliTimestamp();
        
        for (0..operations) |i| {
            const tx = try db.beginTransaction(.read_committed);
            const random_id = random.intRangeAtMost(u32, 0, 1000000);
            const key = try std.fmt.allocPrint(allocator, "rand_key_{:08}", .{random_id});
            defer allocator.free(key);
            const value = try std.fmt.allocPrint(allocator, "rand_value_{:08}_iteration_{}", .{ random_id, i });
            defer allocator.free(value);
            
            try db.putTransaction(tx, key, value);
            try db.commitTransaction(tx);
        }
        
        const end_time = std.time.milliTimestamp();
        const duration = end_time - start_time;
        const ops_per_sec = if (duration > 0) @as(u32, @intCast((operations * 1000) / @as(u32, @intCast(duration)))) else 0;
        
        const stats = db.getBufferPoolStats();
        const memory_mb = @as(f64, @floatFromInt(stats.pages_in_buffer * 4096)) / (1024.0 * 1024.0);
        
        try results.append(BenchmarkResult{
            .name = "Random Insertions",
            .operations = operations,
            .duration_ms = duration,
            .ops_per_sec = ops_per_sec,
            .memory_used_mb = memory_mb,
        });
        
        std.debug.print("Buffer pool hit ratio: {d:.1}%\n", .{stats.hit_ratio * 100});
        std.debug.print("Buffer pool evictions: {}\n", .{stats.evictions});
    }
    
    // Benchmark 3: Mixed Read/Write Workload
    {
        std.debug.print("\n--- Benchmark 3: Mixed Read/Write (70% Read, 30% Write) ---\n", .{});
        
        var db = try Database.create("benchmark_mixed.db", allocator);
        defer {
            db.close();
            cleanupFile("benchmark_mixed.db");
        }
        db.updateDatabaseReference();
        
        // Pre-populate with data
        const prepopulate_count = 1000;
        for (0..prepopulate_count) |i| {
            const tx = try db.beginTransaction(.read_committed);
            const key = try std.fmt.allocPrint(allocator, "mixed_key_{:04}", .{i});
            defer allocator.free(key);
            const value = try std.fmt.allocPrint(allocator, "mixed_value_{:04}", .{i});
            defer allocator.free(value);
            
            try db.putTransaction(tx, key, value);
            try db.commitTransaction(tx);
        }
        
        const operations = 5000;
        var rng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const random = rng.random();
        
        const start_time = std.time.milliTimestamp();
        
        for (0..operations) |i| {
            if (random.intRangeAtMost(u32, 0, 100) < 70) {
                // 70% Read operations
                const key_id = random.intRangeAtMost(u32, 0, prepopulate_count - 1);
                const key = try std.fmt.allocPrint(allocator, "mixed_key_{:04}", .{key_id});
                defer allocator.free(key);
                
                if (try db.get(key, allocator)) |value| {
                    allocator.free(value);
                }
            } else {
                // 30% Write operations
                const tx = try db.beginTransaction(.read_committed);
                const key = try std.fmt.allocPrint(allocator, "mixed_new_key_{}", .{i});
                defer allocator.free(key);
                const value = try std.fmt.allocPrint(allocator, "mixed_new_value_{}", .{i});
                defer allocator.free(value);
                
                try db.putTransaction(tx, key, value);
                try db.commitTransaction(tx);
            }
        }
        
        const end_time = std.time.milliTimestamp();
        const duration = end_time - start_time;
        const ops_per_sec = if (duration > 0) @as(u32, @intCast((operations * 1000) / @as(u32, @intCast(duration)))) else 0;
        
        const stats = db.getBufferPoolStats();
        const memory_mb = @as(f64, @floatFromInt(stats.pages_in_buffer * 4096)) / (1024.0 * 1024.0);
        
        try results.append(BenchmarkResult{
            .name = "Mixed Read/Write",
            .operations = operations,
            .duration_ms = duration,
            .ops_per_sec = ops_per_sec,
            .memory_used_mb = memory_mb,
        });
        
        std.debug.print("Buffer pool hit ratio: {d:.1}%\n", .{stats.hit_ratio * 100});
        std.debug.print("Buffer pool evictions: {}\n", .{stats.evictions});
    }
    
    // Benchmark 4: Transaction Rollback Performance
    {
        std.debug.print("\n--- Benchmark 4: Transaction Rollback Performance ---\n", .{});
        
        var db = try Database.create("benchmark_rollback.db", allocator);
        defer {
            db.close();
            cleanupFile("benchmark_rollback.db");
        }
        db.updateDatabaseReference();
        
        const operations = 1000;
        const start_time = std.time.milliTimestamp();
        
        for (0..operations) |i| {
            const tx = try db.beginTransaction(.read_committed);
            
            // Perform multiple operations in transaction
            for (0..5) |j| {
                const key = try std.fmt.allocPrint(allocator, "rollback_key_{}_{}", .{ i, j });
                defer allocator.free(key);
                const value = try std.fmt.allocPrint(allocator, "rollback_value_{}_{}", .{ i, j });
                defer allocator.free(value);
                
                try db.putTransaction(tx, key, value);
            }
            
            // Rollback the transaction
            try db.rollbackTransaction(tx);
        }
        
        const end_time = std.time.milliTimestamp();
        const duration = end_time - start_time;
        const ops_per_sec = if (duration > 0) @as(u32, @intCast((operations * 1000) / @as(u32, @intCast(duration)))) else 0;
        
        const stats = db.getBufferPoolStats();
        const memory_mb = @as(f64, @floatFromInt(stats.pages_in_buffer * 4096)) / (1024.0 * 1024.0);
        
        try results.append(BenchmarkResult{
            .name = "Transaction Rollbacks",
            .operations = operations,
            .duration_ms = duration,
            .ops_per_sec = ops_per_sec,
            .memory_used_mb = memory_mb,
        });
    }
    
    // Benchmark 5: Large Value Performance
    {
        std.debug.print("\n--- Benchmark 5: Large Value Performance ---\n", .{});
        
        var db = try Database.create("benchmark_large.db", allocator);
        defer {
            db.close();
            cleanupFile("benchmark_large.db");
        }
        db.updateDatabaseReference();
        
        const operations = 1000;
        const large_value = try allocator.alloc(u8, 4096); // 4KB values
        defer allocator.free(large_value);
        std.mem.set(u8, large_value, 'L');
        
        const start_time = std.time.milliTimestamp();
        
        for (0..operations) |i| {
            const tx = try db.beginTransaction(.read_committed);
            const key = try std.fmt.allocPrint(allocator, "large_key_{:04}", .{i});
            defer allocator.free(key);
            
            try db.putTransaction(tx, key, large_value);
            try db.commitTransaction(tx);
        }
        
        const end_time = std.time.milliTimestamp();
        const duration = end_time - start_time;
        const ops_per_sec = if (duration > 0) @as(u32, @intCast((operations * 1000) / @as(u32, @intCast(duration)))) else 0;
        
        const stats = db.getBufferPoolStats();
        const memory_mb = @as(f64, @floatFromInt(stats.pages_in_buffer * 4096)) / (1024.0 * 1024.0);
        
        try results.append(BenchmarkResult{
            .name = "Large Value Operations",
            .operations = operations,
            .duration_ms = duration,
            .ops_per_sec = ops_per_sec,
            .memory_used_mb = memory_mb,
        });
        
        std.debug.print("Buffer pool hit ratio: {d:.1}%\n", .{stats.hit_ratio * 100});
        std.debug.print("Buffer pool evictions: {}\n", .{stats.evictions});
    }
    
    // Benchmark 6: Recovery Performance
    {
        std.debug.print("\n--- Benchmark 6: Recovery Performance ---\n", .{});
        
        const db_path = "benchmark_recovery.db";
        
        // Setup: Create database with transactions
        {
            var db = try Database.create(db_path, allocator);
            db.updateDatabaseReference();
            
            for (0..2000) |i| {
                const tx = try db.beginTransaction(.read_committed);
                const key = try std.fmt.allocPrint(allocator, "recovery_key_{:04}", .{i});
                defer allocator.free(key);
                const value = try std.fmt.allocPrint(allocator, "recovery_value_{:04}", .{i});
                defer allocator.free(value);
                
                try db.putTransaction(tx, key, value);
                try db.commitTransaction(tx);
            }
            
            db.close();
        }
        
        // Benchmark: Recovery time
        const start_time = std.time.milliTimestamp();
        var db = try Database.open(db_path, allocator);
        defer {
            db.close();
            cleanupFile(db_path);
        }
        db.updateDatabaseReference();
        const end_time = std.time.milliTimestamp();
        
        const duration = end_time - start_time;
        const recovery_ops_per_sec = if (duration > 0) @as(u32, @intCast((2000 * 1000) / @as(u32, @intCast(duration)))) else 0;
        
        try results.append(BenchmarkResult{
            .name = "Recovery Performance",
            .operations = 2000,
            .duration_ms = duration,
            .ops_per_sec = recovery_ops_per_sec,
            .memory_used_mb = 0.0,
        });
    }
    
    // Benchmark Results Summary
    std.debug.print("\n=== Performance Benchmark Results ===\n", .{});
    
    var total_ops: u32 = 0;
    var total_time: i64 = 0;
    var max_ops_per_sec: u32 = 0;
    var min_ops_per_sec: u32 = std.math.maxInt(u32);
    
    for (results.items) |result| {
        result.print();
        total_ops += result.operations;
        total_time += result.duration_ms;
        max_ops_per_sec = @max(max_ops_per_sec, result.ops_per_sec);
        min_ops_per_sec = @min(min_ops_per_sec, result.ops_per_sec);
    }
    
    const avg_ops_per_sec = if (total_time > 0) @as(u32, @intCast((total_ops * 1000) / @as(u32, @intCast(total_time)))) else 0;
    
    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Total Operations: {}\n", .{total_ops});
    std.debug.print("Total Time: {}ms\n", .{total_time});
    std.debug.print("Average Performance: {} ops/sec\n", .{avg_ops_per_sec});
    std.debug.print("Peak Performance: {} ops/sec\n", .{max_ops_per_sec});
    std.debug.print("Minimum Performance: {} ops/sec\n", .{min_ops_per_sec});
    
    // Performance assessment
    std.debug.print("\n=== Performance Assessment ===\n", .{});
    if (avg_ops_per_sec > 1000) {
        std.debug.print("✅ EXCELLENT performance (>1000 ops/sec average)\n", .{});
    } else if (avg_ops_per_sec > 500) {
        std.debug.print("✅ GOOD performance (>500 ops/sec average)\n", .{});
    } else if (avg_ops_per_sec > 200) {
        std.debug.print("⚠️  MODERATE performance (>200 ops/sec average)\n", .{});
    } else {
        std.debug.print("❌ POOR performance (<200 ops/sec average)\n", .{});
    }
    
    std.debug.print("=== Benchmark Complete ===\n", .{});
}

fn cleanupFile(filename: []const u8) void {
    std.fs.cwd().deleteFile(filename) catch {};
    
    const wal_filename = std.fmt.allocPrint(std.heap.page_allocator, "{s}.wal", .{filename}) catch return;
    defer std.heap.page_allocator.free(wal_filename);
    std.fs.cwd().deleteFile(wal_filename) catch {};
}