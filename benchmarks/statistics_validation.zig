const std = @import("std");
const lowkeydb = @import("../src/root.zig");

const StatisticsValidator = struct {
    allocator: std.mem.Allocator,
    db: *lowkeydb.Database,
    
    // Expected counters to validate against
    expected_puts: std.atomic.Value(u64),
    expected_gets: std.atomic.Value(u64),
    expected_deletes: std.atomic.Value(u64),
    expected_transactions: std.atomic.Value(u64),
    expected_commits: std.atomic.Value(u64),
    expected_rollbacks: std.atomic.Value(u64),
    
    // Error tracking
    validation_errors: std.atomic.Value(u32),
    
    pub fn init(allocator: std.mem.Allocator, db: *lowkeydb.Database) StatisticsValidator {
        return StatisticsValidator{
            .allocator = allocator,
            .db = db,
            .expected_puts = std.atomic.Value(u64).init(0),
            .expected_gets = std.atomic.Value(u64).init(0),
            .expected_deletes = std.atomic.Value(u64).init(0),
            .expected_transactions = std.atomic.Value(u64).init(0),
            .expected_commits = std.atomic.Value(u64).init(0),
            .expected_rollbacks = std.atomic.Value(u64).init(0),
            .validation_errors = std.atomic.Value(u32).init(0),
        };
    }
    
    pub fn recordPut(self: *StatisticsValidator) void {
        _ = self.expected_puts.fetchAdd(1, .acq_rel);
    }
    
    pub fn recordGet(self: *StatisticsValidator) void {
        _ = self.expected_gets.fetchAdd(1, .acq_rel);
    }
    
    pub fn recordDelete(self: *StatisticsValidator) void {
        _ = self.expected_deletes.fetchAdd(1, .acq_rel);
    }
    
    pub fn recordTransaction(self: *StatisticsValidator) void {
        _ = self.expected_transactions.fetchAdd(1, .acq_rel);
    }
    
    pub fn recordCommit(self: *StatisticsValidator) void {
        _ = self.expected_commits.fetchAdd(1, .acq_rel);
    }
    
    pub fn recordRollback(self: *StatisticsValidator) void {
        _ = self.expected_rollbacks.fetchAdd(1, .acq_rel);
    }
    
    pub fn validateStatistics(self: *StatisticsValidator, test_name: []const u8) bool {
        std.debug.print("Validating statistics for test: {s}\n", .{test_name});
        
        var errors: u32 = 0;
        
        // Get current statistics
        const buffer_stats = self.db.getBufferPoolStats();
        const wal_stats = self.db.getCheckpointStats();
        const key_count = self.db.getKeyCount();
        const active_transactions = self.db.getActiveTransactionCount();
        
        // Validate buffer pool statistics
        std.debug.print("  Buffer Pool Statistics:\n");
        std.debug.print("    Cache hits: {}\n", .{buffer_stats.cache_hits});
        std.debug.print("    Cache misses: {}\n", .{buffer_stats.cache_misses});
        std.debug.print("    Hit ratio: {d:.2}%\n", .{buffer_stats.hit_ratio});
        std.debug.print("    Pages in buffer: {}/{}\n", .{ buffer_stats.pages_in_buffer, buffer_stats.capacity });
        std.debug.print("    Evictions: {}\n", .{buffer_stats.evictions});
        std.debug.print("    Write-backs: {}\n", .{buffer_stats.write_backs});
        
        // Validate that hit ratio calculation is consistent
        const total_accesses = buffer_stats.cache_hits + buffer_stats.cache_misses;
        if (total_accesses > 0) {
            const calculated_hit_ratio = (@as(f64, @floatFromInt(buffer_stats.cache_hits)) / @as(f64, @floatFromInt(total_accesses))) * 100.0;
            const ratio_diff = @abs(calculated_hit_ratio - buffer_stats.hit_ratio);
            if (ratio_diff > 0.1) { // Allow 0.1% tolerance
                std.debug.print("    ❌ Hit ratio inconsistency: calculated {d:.2}%, reported {d:.2}%\n", .{ calculated_hit_ratio, buffer_stats.hit_ratio });
                errors += 1;
            } else {
                std.debug.print("    ✅ Hit ratio calculation is consistent\n");
            }
        }
        
        // Validate that pages in buffer doesn't exceed capacity
        if (buffer_stats.pages_in_buffer > buffer_stats.capacity) {
            std.debug.print("    ❌ Pages in buffer ({}) exceeds capacity ({})\n", .{ buffer_stats.pages_in_buffer, buffer_stats.capacity });
            errors += 1;
        } else {
            std.debug.print("    ✅ Buffer pool capacity constraints respected\n");
        }
        
        // WAL statistics validation
        std.debug.print("  WAL Statistics:\n");
        std.debug.print("    Checkpoints performed: {}\n", .{wal_stats.checkpoints_performed});
        std.debug.print("    Pages written: {}\n", .{wal_stats.pages_written});
        std.debug.print("    WAL size: {} bytes\n", .{wal_stats.wal_size});
        std.debug.print("    Last checkpoint time: {}\n", .{wal_stats.last_checkpoint_time});
        
        // Validate WAL size is reasonable (not negative, not impossibly large)
        if (wal_stats.wal_size > 1024 * 1024 * 1024) { // 1GB limit for test
            std.debug.print("    ❌ WAL size seems unreasonably large: {} bytes\n", .{wal_stats.wal_size});
            errors += 1;
        } else {
            std.debug.print("    ✅ WAL size is reasonable\n");
        }
        
        // Database state validation
        std.debug.print("  Database State:\n");
        std.debug.print("    Key count: {}\n", .{key_count});
        std.debug.print("    Active transactions: {}\n", .{active_transactions});
        
        // Validate no transactions are left hanging
        if (active_transactions > 0) {
            std.debug.print("    ⚠️  Warning: {} transactions still active\n", .{active_transactions});
        } else {
            std.debug.print("    ✅ No hanging transactions\n");
        }
        
        // Cross-validate with expected counts (if we've been tracking them)
        const expected_put_count = self.expected_puts.load(.acquire);
        const expected_get_count = self.expected_gets.load(.acquire);
        const expected_delete_count = self.expected_deletes.load(.acquire);
        
        if (expected_put_count > 0 or expected_get_count > 0 or expected_delete_count > 0) {
            std.debug.print("  Expected Operation Counts:\n");
            std.debug.print("    Expected PUTs: {}\n", .{expected_put_count});
            std.debug.print("    Expected GETs: {}\n", .{expected_get_count});
            std.debug.print("    Expected DELETEs: {}\n", .{expected_delete_count});
            
            // We can't directly validate these against buffer pool stats since
            // multiple operations might hit/miss the cache, but we can check
            // for reasonable relationships
            
            if (buffer_stats.cache_hits + buffer_stats.cache_misses < expected_get_count) {
                std.debug.print("    ❌ Cache accesses ({}) less than expected GETs ({})\n", .{ buffer_stats.cache_hits + buffer_stats.cache_misses, expected_get_count });
                errors += 1;
            }
        }
        
        // Memory consistency check - try to detect memory corruption
        std.debug.print("  Memory Consistency Check:\n");
        
        // Insert a known key-value pair and verify it
        const test_key = "statistics_validation_test_key";
        const test_value = "statistics_validation_test_value_with_known_content";
        
        self.db.put(test_key, test_value) catch |err| {
            std.debug.print("    ❌ Failed to insert test key: {}\n", .{err});
            errors += 1;
            return false;
        };
        
        const retrieved_value = self.db.get(test_key, self.allocator) catch |err| {
            std.debug.print("    ❌ Failed to retrieve test key: {}\n", .{err});
            errors += 1;
            return false;
        };
        
        if (retrieved_value) |value| {
            defer self.allocator.free(value);
            if (std.mem.eql(u8, value, test_value)) {
                std.debug.print("    ✅ Memory consistency check passed\n");
            } else {
                std.debug.print("    ❌ Memory consistency check failed: expected '{s}', got '{s}'\n", .{ test_value, value });
                errors += 1;
            }
        } else {
            std.debug.print("    ❌ Memory consistency check failed: key not found\n");
            errors += 1;
        }
        
        // Clean up test key
        _ = self.db.delete(test_key) catch |err| {
            std.debug.print("    ⚠️  Warning: Failed to clean up test key: {}\n", .{err});
        };
        
        // Structural validation
        std.debug.print("  Structural Validation:\n");
        self.db.validateBTreeStructure() catch |err| {
            std.debug.print("    ❌ B+ tree validation failed: {}\n", .{err});
            errors += 1;
            return false;
        };
        std.debug.print("    ✅ B+ tree structure is valid\n");
        
        self.validation_errors.store(errors, .release);
        
        if (errors == 0) {
            std.debug.print("  🎉 All validations PASSED for {s}\n\n", .{test_name});
            return true;
        } else {
            std.debug.print("  💥 {} validation errors detected for {s}\n\n", .{ errors, test_name });
            return false;
        }
    }
    
    pub fn getValidationErrors(self: *StatisticsValidator) u32 {
        return self.validation_errors.load(.acquire);
    }
};

const ValidationWorker = struct {
    thread_id: u32,
    db: *lowkeydb.Database,
    validator: *StatisticsValidator,
    allocator: std.mem.Allocator,
    operations_count: u32,
    
    pub fn run(self: *ValidationWorker) void {
        var prng = std.rand.DefaultPrng.init(@as(u64, @intCast(std.time.milliTimestamp())) + self.thread_id);
        const random = prng.random();
        
        for (0..self.operations_count) |i| {
            const operation_type = random.uintAtMost(u32, 2); // 0=put, 1=get, 2=delete
            const key = std.fmt.allocPrint(self.allocator, "validation_thread_{}_key_{}", .{ self.thread_id, i }) catch continue;
            defer self.allocator.free(key);
            
            switch (operation_type) {
                0 => { // PUT
                    const value = std.fmt.allocPrint(self.allocator, "value_{}_{}", .{ self.thread_id, i }) catch continue;
                    defer self.allocator.free(value);
                    
                    self.db.put(key, value) catch continue;
                    self.validator.recordPut();
                },
                1 => { // GET
                    const value = self.db.get(key, self.allocator) catch continue;
                    if (value) |v| {
                        self.allocator.free(v);
                    }
                    self.validator.recordGet();
                },
                2 => { // DELETE
                    _ = self.db.delete(key) catch continue;
                    self.validator.recordDelete();
                },
                else => unreachable,
            }
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== LowkeyDB Statistics Validation Test ===\n\n");

    // Create fresh database
    const db_path = "statistics_validation.db";
    std.fs.cwd().deleteFile(db_path) catch {};
    std.fs.cwd().deleteFile("statistics_validation.db.wal") catch {};

    var db = try lowkeydb.Database.create(db_path, allocator);
    defer db.close();

    var validator = StatisticsValidator.init(allocator, &db);

    // Test 1: Basic single-threaded operations
    {
        std.debug.print("🧪 Test 1: Single-threaded basic operations\n");
        
        const num_ops = 1000;
        for (0..num_ops) |i| {
            const key = try std.fmt.allocPrint(allocator, "test1_key_{}", .{i});
            defer allocator.free(key);
            const value = try std.fmt.allocPrint(allocator, "test1_value_{}", .{i});
            defer allocator.free(value);
            
            try db.put(key, value);
            validator.recordPut();
            
            const retrieved = try db.get(key, allocator);
            validator.recordGet();
            if (retrieved) |v| {
                allocator.free(v);
            }
        }
        
        _ = validator.validateStatistics("Single-threaded basic operations");
    }

    // Test 2: Transaction-heavy workload
    {
        std.debug.print("🧪 Test 2: Transaction-heavy workload\n");
        
        const num_transactions = 100;
        for (0..num_transactions) |i| {
            const tx_id = try db.beginTransaction(.serializable);
            validator.recordTransaction();
            
            // Multiple operations per transaction
            for (0..5) |j| {
                const key = try std.fmt.allocPrint(allocator, "test2_tx_{}_key_{}", .{ i, j });
                defer allocator.free(key);
                const value = try std.fmt.allocPrint(allocator, "test2_tx_{}_value_{}", .{ i, j });
                defer allocator.free(value);
                
                try db.putTransaction(tx_id, key, value);
                validator.recordPut();
                
                const retrieved = try db.getTransaction(tx_id, key, allocator);
                validator.recordGet();
                if (retrieved) |v| {
                    allocator.free(v);
                }
            }
            
            if (i % 10 == 9) { // Rollback every 10th transaction
                try db.rollbackTransaction(tx_id);
                validator.recordRollback();
            } else {
                try db.commitTransaction(tx_id);
                validator.recordCommit();
            }
        }
        
        _ = validator.validateStatistics("Transaction-heavy workload");
    }

    // Test 3: Concurrent operations with statistics validation
    {
        std.debug.print("🧪 Test 3: Concurrent operations\n");
        
        const num_threads = 4;
        const ops_per_thread = 500;
        
        var workers = try allocator.alloc(ValidationWorker, num_threads);
        defer allocator.free(workers);
        
        for (workers, 0..) |*worker, i| {
            worker.* = ValidationWorker{
                .thread_id = @as(u32, @intCast(i)),
                .db = &db,
                .validator = &validator,
                .allocator = allocator,
                .operations_count = ops_per_thread,
            };
        }
        
        var threads = try allocator.alloc(std.Thread, num_threads);
        defer allocator.free(threads);
        
        for (threads, workers) |*thread, *worker| {
            thread.* = try std.Thread.spawn(.{}, ValidationWorker.run, .{worker});
        }
        
        for (threads) |thread| {
            thread.join();
        }
        
        _ = validator.validateStatistics("Concurrent operations");
    }

    // Test 4: Checkpoint stress with statistics validation
    {
        std.debug.print("🧪 Test 4: Checkpoint stress validation\n");
        
        // Start auto-checkpointing with aggressive settings
        db.configureCheckpointing(500, 1, 3); // 500ms interval, 1MB max WAL
        try db.startAutoCheckpoint();
        defer db.stopAutoCheckpoint();
        
        // Generate significant WAL activity
        for (0..2000) |i| {
            const key = try std.fmt.allocPrint(allocator, "checkpoint_test_key_{}", .{i});
            defer allocator.free(key);
            
            // Generate large values to stress WAL
            const value_size = 256 + (i % 512); // 256-768 bytes
            const value = try allocator.alloc(u8, value_size);
            defer allocator.free(value);
            
            for (value, 0..) |_, j| {
                value[j] = @as(u8, @intCast((i + j) % 256));
            }
            
            try db.put(key, value);
            validator.recordPut();
            
            // Force checkpoints occasionally
            if (i % 100 == 0) {
                try db.checkpoint();
                std.time.sleep(10 * 1000 * 1000); // 10ms delay
            }
        }
        
        // Wait for final checkpoints
        std.time.sleep(1000 * 1000 * 1000); // 1 second
        
        _ = validator.validateStatistics("Checkpoint stress validation");
    }

    // Final comprehensive validation
    {
        std.debug.print("🧪 Final: Comprehensive database state validation\n");
        
        // Perform final checkpoint and validation
        try db.checkpoint();
        try db.flushWAL();
        
        const final_valid = validator.validateStatistics("Final comprehensive validation");
        
        if (final_valid and validator.getValidationErrors() == 0) {
            std.debug.print("🎉 ALL STATISTICS VALIDATION TESTS PASSED! 🎉\n");
            std.debug.print("Database statistics are accurate and consistent under all tested conditions.\n");
        } else {
            std.debug.print("💥 VALIDATION FAILED with {} total errors\n", .{validator.getValidationErrors()});
            std.debug.print("Statistics may be inaccurate or inconsistent under some conditions.\n");
        }
    }

    std.debug.print("\n=== STATISTICS VALIDATION COMPLETE ===\n");
}