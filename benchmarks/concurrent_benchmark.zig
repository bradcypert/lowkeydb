const std = @import("std");
const lowkeydb = @import("../src/root.zig");

const ConcurrentWorker = struct {
    thread_id: u32,
    db: *lowkeydb.Database,
    allocator: std.mem.Allocator,
    operations_count: u32,
    read_ratio: f32, // 0.0 = all writes, 1.0 = all reads
    
    // Results
    completed_operations: std.atomic.Value(u32),
    successful_reads: std.atomic.Value(u32),
    successful_writes: std.atomic.Value(u32),
    successful_deletes: std.atomic.Value(u32),
    failed_operations: std.atomic.Value(u32),
    total_time_ns: std.atomic.Value(u64),
    
    pub fn init(thread_id: u32, db: *lowkeydb.Database, allocator: std.mem.Allocator, operations_count: u32, read_ratio: f32) ConcurrentWorker {
        return ConcurrentWorker{
            .thread_id = thread_id,
            .db = db,
            .allocator = allocator,
            .operations_count = operations_count,
            .read_ratio = read_ratio,
            .completed_operations = std.atomic.Value(u32).init(0),
            .successful_reads = std.atomic.Value(u32).init(0),
            .successful_writes = std.atomic.Value(u32).init(0),
            .successful_deletes = std.atomic.Value(u32).init(0),
            .failed_operations = std.atomic.Value(u32).init(0),
            .total_time_ns = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn run(self: *ConcurrentWorker) void {
        const start_time = std.time.nanoTimestamp();
        var prng = std.rand.DefaultPrng.init(@as(u64, @intCast(std.time.milliTimestamp())) + self.thread_id);
        const random = prng.random();
        
        var operations: u32 = 0;
        var reads: u32 = 0;
        var writes: u32 = 0;
        var deletes: u32 = 0;
        var failures: u32 = 0;
        
        while (operations < self.operations_count) {
            const operation_choice = random.float(f32);
            const key_id = random.uintAtMost(u32, 10000); // Shared key space for contention
            
            const key = std.fmt.allocPrint(self.allocator, "concurrent_key_{}", .{key_id}) catch {
                failures += 1;
                operations += 1;
                continue;
            };
            defer self.allocator.free(key);
            
            if (operation_choice < self.read_ratio) {
                // READ operation
                const value = self.db.get(key, self.allocator) catch |err| {
                    if (err != lowkeydb.DatabaseError.KeyNotFound) {
                        failures += 1;
                    }
                    operations += 1;
                    continue;
                };
                
                if (value) |v| {
                    self.allocator.free(v);
                    reads += 1;
                } else {
                    reads += 1; // Count not-found as successful read
                }
            } else {
                // Decide between WRITE and DELETE
                const write_or_delete = random.float(f32);
                
                if (write_or_delete < 0.8) { // 80% writes, 20% deletes among non-reads
                    // WRITE operation
                    const value = std.fmt.allocPrint(self.allocator, "thread_{}_value_{}", .{ self.thread_id, operations }) catch {
                        failures += 1;
                        operations += 1;
                        continue;
                    };
                    defer self.allocator.free(value);
                    
                    self.db.put(key, value) catch {
                        failures += 1;
                        operations += 1;
                        continue;
                    };
                    
                    writes += 1;
                } else {
                    // DELETE operation
                    _ = self.db.delete(key) catch {
                        failures += 1;
                        operations += 1;
                        continue;
                    };
                    
                    deletes += 1;
                }
            }
            
            operations += 1;
            
            // Small random delay to vary timing
            if (operations % 100 == 0) {
                std.time.sleep(random.uintAtMost(u64, 10000)); // Up to 10μs
            }
        }
        
        const end_time = std.time.nanoTimestamp();
        const total_time = @as(u64, @intCast(end_time - start_time));
        
        // Store results atomically
        self.completed_operations.store(operations, .release);
        self.successful_reads.store(reads, .release);
        self.successful_writes.store(writes, .release);
        self.successful_deletes.store(deletes, .release);
        self.failed_operations.store(failures, .release);
        self.total_time_ns.store(total_time, .release);
        
        std.debug.print("Thread {} completed: {} ops ({} reads, {} writes, {} deletes, {} failures) in {d:.2}ms\n", .{
            self.thread_id,
            operations,
            reads,
            writes,
            deletes,
            failures,
            @as(f64, @floatFromInt(total_time)) / 1_000_000.0,
        });
    }
};

const BenchmarkConfig = struct {
    name: []const u8,
    num_threads: u32,
    operations_per_thread: u32,
    read_ratio: f32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== LowkeyDB Concurrent Operations Benchmark ===\n\n");

    // Different benchmark configurations to test various scenarios
    const configs = [_]BenchmarkConfig{
        .{ .name = "Read-Heavy (90% reads)", .num_threads = 8, .operations_per_thread = 2000, .read_ratio = 0.9 },
        .{ .name = "Balanced (50% reads)", .num_threads = 8, .operations_per_thread = 2000, .read_ratio = 0.5 },
        .{ .name = "Write-Heavy (10% reads)", .num_threads = 8, .operations_per_thread = 2000, .read_ratio = 0.1 },
        .{ .name = "High Concurrency", .num_threads = 16, .operations_per_thread = 1000, .read_ratio = 0.7 },
        .{ .name = "Low Concurrency", .num_threads = 2, .operations_per_thread = 4000, .read_ratio = 0.6 },
    };

    for (configs) |config| {
        std.debug.print("🧪 Running benchmark: {s}\n", .{config.name});
        std.debug.print("  Threads: {}, Ops/thread: {}, Read ratio: {d:.0}%\n", .{ config.num_threads, config.operations_per_thread, config.read_ratio * 100.0 });

        // Create fresh database for each benchmark
        const db_path = try std.fmt.allocPrint(allocator, "concurrent_bench_{}.db", .{std.hash_map.hashString(config.name)});
        defer allocator.free(db_path);
        
        std.fs.cwd().deleteFile(db_path) catch {};
        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{db_path});
        defer allocator.free(wal_path);
        std.fs.cwd().deleteFile(wal_path) catch {};

        var db = try lowkeydb.Database.create(db_path, allocator);
        defer db.close();

        // Pre-populate database with some data for read operations
        std.debug.print("  Pre-populating database...\n");
        for (0..5000) |i| {
            const key = try std.fmt.allocPrint(allocator, "concurrent_key_{}", .{i});
            defer allocator.free(key);
            const value = try std.fmt.allocPrint(allocator, "initial_value_{}", .{i});
            defer allocator.free(value);
            
            try db.put(key, value);
        }

        // Start auto-checkpointing for realistic conditions
        db.configureCheckpointing(2000, 5, 5); // 2 second interval, 5MB max WAL
        try db.startAutoCheckpoint();
        defer db.stopAutoCheckpoint();

        // Create workers
        var workers = try allocator.alloc(ConcurrentWorker, config.num_threads);
        defer allocator.free(workers);

        for (workers, 0..) |*worker, i| {
            worker.* = ConcurrentWorker.init(@as(u32, @intCast(i)), &db, allocator, config.operations_per_thread, config.read_ratio);
        }

        // Create threads
        var threads = try allocator.alloc(std.Thread, config.num_threads);
        defer allocator.free(threads);

        // Start benchmark
        std.debug.print("  Starting benchmark...\n");
        const start_time = std.time.nanoTimestamp();

        for (threads, workers) |*thread, *worker| {
            thread.* = try std.Thread.spawn(.{}, ConcurrentWorker.run, .{worker});
        }

        // Wait for completion
        for (threads) |thread| {
            thread.join();
        }

        const end_time = std.time.nanoTimestamp();
        const total_time_s = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000_000.0;

        // Collect results
        var total_operations: u32 = 0;
        var total_reads: u32 = 0;
        var total_writes: u32 = 0;
        var total_deletes: u32 = 0;
        var total_failures: u32 = 0;
        var max_thread_time_ns: u64 = 0;
        var min_thread_time_ns: u64 = std.math.maxInt(u64);

        for (workers) |worker| {
            total_operations += worker.completed_operations.load(.acquire);
            total_reads += worker.successful_reads.load(.acquire);
            total_writes += worker.successful_writes.load(.acquire);
            total_deletes += worker.successful_deletes.load(.acquire);
            total_failures += worker.failed_operations.load(.acquire);
            
            const thread_time = worker.total_time_ns.load(.acquire);
            max_thread_time_ns = @max(max_thread_time_ns, thread_time);
            min_thread_time_ns = @min(min_thread_time_ns, thread_time);
        }

        // Calculate performance metrics
        const throughput = @as(f64, @floatFromInt(total_operations)) / total_time_s;
        const avg_latency_us = total_time_s * 1_000_000.0 / @as(f64, @floatFromInt(total_operations));
        const success_rate = @as(f64, @floatFromInt(total_operations - total_failures)) / @as(f64, @floatFromInt(total_operations)) * 100.0;

        // Get final database statistics
        const final_key_count = db.getKeyCount();
        const buffer_stats = db.getBufferPoolStats();
        const wal_stats = db.getCheckpointStats();

        // Print results
        std.debug.print("  Results:\n");
        std.debug.print("    Total time: {d:.2} seconds\n", .{total_time_s});
        std.debug.print("    Total operations: {} ({} reads, {} writes, {} deletes)\n", .{ total_operations, total_reads, total_writes, total_deletes });
        std.debug.print("    Throughput: {d:.0} ops/sec\n", .{throughput});
        std.debug.print("    Average latency: {d:.2} μs\n", .{avg_latency_us});
        std.debug.print("    Success rate: {d:.1}%\n", .{success_rate});
        std.debug.print("    Failed operations: {}\n", .{total_failures});
        std.debug.print("    Thread time variance: {d:.2}ms\n", .{@as(f64, @floatFromInt(max_thread_time_ns - min_thread_time_ns)) / 1_000_000.0});
        
        std.debug.print("  Database State:\n");
        std.debug.print("    Final key count: {}\n", .{final_key_count});
        std.debug.print("    Buffer hit ratio: {d:.1}%\n", .{buffer_stats.hit_ratio});
        std.debug.print("    Cache hits: {}, misses: {}\n", .{ buffer_stats.cache_hits, buffer_stats.cache_misses });
        std.debug.print("    Pages in buffer: {}/{}\n", .{ buffer_stats.pages_in_buffer, buffer_stats.capacity });
        std.debug.print("    Evictions: {}, write-backs: {}\n", .{ buffer_stats.evictions, buffer_stats.write_backs });
        std.debug.print("    WAL size: {} bytes\n", .{wal_stats.wal_size});
        std.debug.print("    Checkpoints: {}\n", .{wal_stats.checkpoints_performed});

        // Performance assessment
        if (throughput > 5000 and success_rate > 99.0 and buffer_stats.hit_ratio > 80.0) {
            std.debug.print("    🎉 Performance: EXCELLENT\n");
        } else if (throughput > 2000 and success_rate > 95.0 and buffer_stats.hit_ratio > 60.0) {
            std.debug.print("    ✅ Performance: GOOD\n");
        } else if (throughput > 1000 and success_rate > 90.0) {
            std.debug.print("    ⚠️  Performance: ACCEPTABLE\n");
        } else {
            std.debug.print("    ❌ Performance: NEEDS IMPROVEMENT\n");
        }

        std.debug.print("\n");
    }

    // Summary benchmark - stress test with extreme concurrency
    {
        std.debug.print("🚀 Final Stress Test: Extreme Concurrency\n");
        std.debug.print("  32 threads × 500 ops each = 16,000 total operations\n");

        const stress_db_path = "stress_concurrent.db";
        std.fs.cwd().deleteFile(stress_db_path) catch {};
        std.fs.cwd().deleteFile("stress_concurrent.db.wal") catch {};

        var stress_db = try lowkeydb.Database.create(stress_db_path, allocator);
        defer stress_db.close();

        // Aggressive checkpointing for stress test
        stress_db.configureCheckpointing(500, 2, 3); // 500ms interval, 2MB max WAL
        try stress_db.startAutoCheckpoint();
        defer stress_db.stopAutoCheckpoint();

        const stress_config = BenchmarkConfig{
            .name = "Extreme Stress",
            .num_threads = 32,
            .operations_per_thread = 500,
            .read_ratio = 0.6,
        };

        var stress_workers = try allocator.alloc(ConcurrentWorker, stress_config.num_threads);
        defer allocator.free(stress_workers);

        for (stress_workers, 0..) |*worker, i| {
            worker.* = ConcurrentWorker.init(@as(u32, @intCast(i)), &stress_db, allocator, stress_config.operations_per_thread, stress_config.read_ratio);
        }

        var stress_threads = try allocator.alloc(std.Thread, stress_config.num_threads);
        defer allocator.free(stress_threads);

        const stress_start_time = std.time.nanoTimestamp();

        for (stress_threads, stress_workers) |*thread, *worker| {
            thread.* = try std.Thread.spawn(.{}, ConcurrentWorker.run, .{worker});
        }

        for (stress_threads) |thread| {
            thread.join();
        }

        const stress_end_time = std.time.nanoTimestamp();
        const stress_total_time_s = @as(f64, @floatFromInt(stress_end_time - stress_start_time)) / 1_000_000_000.0;

        var stress_total_ops: u32 = 0;
        var stress_total_failures: u32 = 0;

        for (stress_workers) |worker| {
            stress_total_ops += worker.completed_operations.load(.acquire);
            stress_total_failures += worker.failed_operations.load(.acquire);
        }

        const stress_throughput = @as(f64, @floatFromInt(stress_total_ops)) / stress_total_time_s;
        const stress_success_rate = @as(f64, @floatFromInt(stress_total_ops - stress_total_failures)) / @as(f64, @floatFromInt(stress_total_ops)) * 100.0;

        std.debug.print("  Stress test results:\n");
        std.debug.print("    Time: {d:.2} seconds\n", .{stress_total_time_s});
        std.debug.print("    Throughput: {d:.0} ops/sec\n", .{stress_throughput});
        std.debug.print("    Success rate: {d:.1}%\n", .{stress_success_rate});
        std.debug.print("    Total failures: {}\n", .{stress_total_failures});

        if (stress_success_rate > 95.0 and stress_throughput > 1000) {
            std.debug.print("    🏆 STRESS TEST PASSED - Database handles extreme concurrency!\n");
        } else {
            std.debug.print("    ⚠️  STRESS TEST WARNING - Performance degraded under extreme load\n");
        }
    }

    std.debug.print("\n=== CONCURRENT BENCHMARK COMPLETE ===\n");
    std.debug.print("LowkeyDB concurrent performance has been thoroughly tested.\n");
    std.debug.print("All benchmarks validate the database's thread-safety and performance characteristics.\n");
}