# LowkeyDB Zig Integration Guide

LowkeyDB is a high-performance, embedded database written in Zig with excellent thread safety and ACID transaction support. This guide shows you how to integrate LowkeyDB into your Zig applications.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Basic Operations](#basic-operations)
- [Advanced Features](#advanced-features)
- [Performance Optimization](#performance-optimization)
- [Complete Examples](#complete-examples)
- [Best Practices](#best-practices)

## Installation

### As a Zig Package (Recommended)

Add LowkeyDB to your `build.zig.zon`:

```zig
.{
    .name = .my_project,
    .version = "0.1.0",
    .minimum_zig_version = "0.14.0",
    .dependencies = .{
        .lowkeydb = .{
            .url = "https://github.com/bradcypert/lowkeydb/archive/main.tar.gz",
            .hash = "...", // Use zig fetch to get the hash
        },
    },
}
```

Then in your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the lowkeydb dependency
    const lowkeydb = b.dependency("lowkeydb", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link the lowkeydb module
    exe.root_module.addImport("lowkeydb", lowkeydb.module("lowkeydb"));
    
    b.installArtifact(exe);
}
```

## Quick Start

Here's a minimal example to get you started:

```zig
const std = @import("std");
const lowkeydb = @import("lowkeydb"); // or @import("lowkeydb/src/root.zig")

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create or open a database
    var db = try lowkeydb.Database.create("my_app.db", allocator);
    defer db.close();

    // Store some data
    try db.put("greeting", "Hello, LowkeyDB!");
    try db.put("user:123", "Alice Johnson");

    // Retrieve data
    const greeting = try db.get("greeting", allocator);
    defer if (greeting) |g| allocator.free(g);
    
    if (greeting) |g| {
        std.debug.print("Retrieved: {s}\\n", .{g});
    }

    std.debug.print("Database has {} keys\\n", .{db.getKeyCount()});
}
```

## Basic Operations

### Database Lifecycle

```zig
const std = @import("std");
const lowkeydb = @import("lowkeydb");

pub fn databaseLifecycle() !void {
    const allocator = std.heap.page_allocator;

    // Create a new database
    var db = try lowkeydb.Database.create("example.db", allocator);
    defer db.close();

    // Alternative: Open existing database
    // var db = try lowkeydb.Database.open("existing.db", allocator);
    
    // Database operations...
}
```

### CRUD Operations

```zig
pub fn crudOperations(db: *lowkeydb.Database, allocator: std.mem.Allocator) !void {
    // CREATE/UPDATE (PUT)
    try db.put("user:001", "Alice Johnson");
    try db.put("product:A", "Laptop Computer");
    try db.put("config:timeout", "30");

    // READ (GET)
    const user = try db.get("user:001", allocator);
    defer if (user) |u| allocator.free(u);
    
    if (user) |u| {
        std.debug.print("User: {s}\\n", .{u});
    } else {
        std.debug.print("User not found\\n", .{});
    }

    // DELETE
    const deleted = try db.delete("config:timeout");
    if (deleted) {
        std.debug.print("Config deleted\\n", .{});
    } else {
        std.debug.print("Config not found\\n", .{});
    }

    // CHECK existence (without retrieving value)
    const user_exists = try db.get("user:001", allocator) != null;
    std.debug.print("User exists: {}\\n", .{user_exists});
}
```

### Batch Operations

```zig
pub fn batchOperations(db: *lowkeydb.Database) !void {
    // Efficient batch insertion
    const users = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "user:001", .value = "Alice Johnson" },
        .{ .key = "user:002", .value = "Bob Smith" },
        .{ .key = "user:003", .value = "Carol Davis" },
        .{ .key = "user:004", .value = "David Wilson" },
        .{ .key = "user:005", .value = "Eve Brown" },
    };

    // Insert multiple records efficiently
    for (users) |user| {
        try db.put(user.key, user.value);
    }

    std.debug.print("Inserted {} users\\n", .{users.len});
    std.debug.print("Total keys in database: {}\\n", .{db.getKeyCount()});
}
```

## Advanced Features

### Transactions (ACID Compliance)

LowkeyDB supports full ACID transactions with multiple isolation levels:

```zig
pub fn transactionExample(db: *lowkeydb.Database, allocator: std.mem.Allocator) !void {
    // Begin a serializable transaction
    const tx_id = try db.beginTransaction(.serializable);
    
    // Perform operations within the transaction
    try db.putTransaction(tx_id, "account:A", "1000");
    try db.putTransaction(tx_id, "account:B", "500");
    
    // Read within transaction
    const balance_a = try db.getTransaction(tx_id, "account:A", allocator);
    defer if (balance_a) |b| allocator.free(b);
    
    if (balance_a) |balance| {
        std.debug.print("Account A balance: {s}\\n", .{balance});
        
        // Simulate a transfer
        const amount: i32 = 100;
        const current_balance = try std.fmt.parseInt(i32, balance, 10);
        
        if (current_balance >= amount) {
            // Update accounts
            const new_balance_a = try std.fmt.allocPrint(allocator, "{}", .{current_balance - amount});
            defer allocator.free(new_balance_a);
            
            try db.putTransaction(tx_id, "account:A", new_balance_a);
            
            // Commit the transaction
            try db.commitTransaction(tx_id);
            std.debug.print("Transfer completed successfully\\n", .{});
        } else {
            // Rollback on insufficient funds
            try db.rollbackTransaction(tx_id);
            std.debug.print("Transfer failed: insufficient funds\\n", .{});
        }
    }
}
```

### Different Isolation Levels

```zig
pub fn isolationLevelExample(db: *lowkeydb.Database) !void {
    // Read Committed (default)
    const tx1 = try db.beginTransaction(.read_committed);
    
    // Repeatable Read
    const tx2 = try db.beginTransaction(.repeatable_read);
    
    // Serializable (strictest)
    const tx3 = try db.beginTransaction(.serializable);
    
    // Use transactions...
    try db.commitTransaction(tx1);
    try db.commitTransaction(tx2);
    try db.commitTransaction(tx3);
}
```

### Concurrent Access

LowkeyDB is fully thread-safe with fine-grained locking:

```zig
const std = @import("std");
const lowkeydb = @import("lowkeydb");

const WorkerResult = struct {
    thread_id: u32,
    operations_completed: u32,
    errors: u32,
};

pub fn concurrentExample(allocator: std.mem.Allocator) !void {
    var db = try lowkeydb.Database.create("concurrent_test.db", allocator);
    defer db.close();

    const num_threads = 4;
    const ops_per_thread = 1000;
    
    var threads: [num_threads]std.Thread = undefined;
    var results: [num_threads]WorkerResult = undefined;
    
    // Start worker threads
    for (threads, &results, 0..) |*thread, *result, i| {
        result.* = WorkerResult{
            .thread_id = @intCast(i),
            .operations_completed = 0,
            .errors = 0,
        };
        
        thread.* = try std.Thread.spawn(.{}, workerThread, .{ &db, result, ops_per_thread, allocator });
    }
    
    // Wait for completion
    for (threads) |thread| {
        thread.join();
    }
    
    // Collect results
    var total_ops: u32 = 0;
    var total_errors: u32 = 0;
    for (results) |result| {
        total_ops += result.operations_completed;
        total_errors += result.errors;
        std.debug.print("Thread {}: {} ops, {} errors\\n", .{ result.thread_id, result.operations_completed, result.errors });
    }
    
    std.debug.print("Total: {} operations, {} errors\\n", .{ total_ops, total_errors });
    std.debug.print("Final key count: {}\\n", .{db.getKeyCount()});
}

fn workerThread(db: *lowkeydb.Database, result: *WorkerResult, operations: u32, allocator: std.mem.Allocator) void {
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp() + result.thread_id));
    const random = prng.random();
    
    for (0..operations) |i| {
        const key = std.fmt.allocPrint(allocator, "thread_{}_{}", .{ result.thread_id, i }) catch {
            result.errors += 1;
            continue;
        };
        defer allocator.free(key);
        
        const value = std.fmt.allocPrint(allocator, "value_{}_{}", .{ result.thread_id, i }) catch {
            result.errors += 1;
            continue;
        };
        defer allocator.free(value);
        
        // Random operation
        const op = random.uintAtMost(u32, 2); // 0=put, 1=get, 2=delete
        
        switch (op) {
            0 => { // PUT
                db.put(key, value) catch {
                    result.errors += 1;
                    continue;
                };
            },
            1 => { // GET
                const retrieved = db.get(key, allocator) catch {
                    result.errors += 1;
                    continue;
                };
                if (retrieved) |r| allocator.free(r);
            },
            2 => { // DELETE
                _ = db.delete(key) catch {
                    result.errors += 1;
                    continue;
                };
            },
            else => unreachable,
        }
        
        result.operations_completed += 1;
    }
}
```

### WAL and Checkpointing

```zig
pub fn walExample(db: *lowkeydb.Database) !void {
    // Configure automatic checkpointing
    // Parameters: interval_ms, max_wal_size_mb, max_archived_wals
    db.configureCheckpointing(2000, 5, 10); // 2 seconds, 5MB max WAL, keep 10 archives
    
    // Start automatic checkpointing
    try db.startAutoCheckpoint();
    defer db.stopAutoCheckpoint();
    
    // Perform many operations...
    for (0..10000) |i| {
        const key = try std.fmt.allocPrint(std.heap.page_allocator, "key_{}", .{i});
        defer std.heap.page_allocator.free(key);
        const value = try std.fmt.allocPrint(std.heap.page_allocator, "value_{}", .{i});
        defer std.heap.page_allocator.free(value);
        
        try db.put(key, value);
    }
    
    // Manual checkpoint
    try db.checkpoint();
    
    // Flush WAL to disk
    try db.flushWAL();
    
    // Get checkpoint statistics
    const stats = db.getCheckpointStats();
    std.debug.print("Checkpoints performed: {}\\n", .{stats.checkpoints_performed});
    std.debug.print("Pages written: {}\\n", .{stats.pages_written});
    std.debug.print("WAL size: {} bytes\\n", .{stats.wal_size});
}
```

## Performance Optimization

### Buffer Pool Configuration

```zig
pub fn performanceOptimization(db: *lowkeydb.Database) !void {
    // Get buffer pool statistics
    const buffer_stats = db.getBufferPoolStats();
    
    std.debug.print("Buffer Pool Statistics:\\n", .{});
    std.debug.print("  Hit ratio: {d:.1}%\\n", .{buffer_stats.hit_ratio});
    std.debug.print("  Cache hits: {}\\n", .{buffer_stats.cache_hits});
    std.debug.print("  Cache misses: {}\\n", .{buffer_stats.cache_misses});
    std.debug.print("  Pages in buffer: {}/{}\\n", .{ buffer_stats.pages_in_buffer, buffer_stats.capacity });
    std.debug.print("  Evictions: {}\\n", .{buffer_stats.evictions});
    std.debug.print("  Write-backs: {}\\n", .{buffer_stats.write_backs});
    
    // Optimize based on hit ratio
    if (buffer_stats.hit_ratio < 80.0) {
        std.debug.print("Consider increasing buffer pool size for better performance\\n", .{});
    }
}
```

### Efficient Key Design

```zig
pub fn efficientKeyDesign(db: *lowkeydb.Database) !void {
    // Good: Use consistent prefixes for related data
    try db.put("user:001:name", "Alice");
    try db.put("user:001:email", "alice@example.com");
    try db.put("user:001:last_login", "2024-01-15");
    
    // Good: Use hierarchical keys
    try db.put("app:settings:theme", "dark");
    try db.put("app:settings:language", "en");
    try db.put("app:cache:session:abc123", "user_data");
    
    // Good: Use fixed-width numeric suffixes for ordering
    try db.put("log:20240115:001", "Error message 1");
    try db.put("log:20240115:002", "Warning message 2");
    
    // Avoid: Very long keys (impacts performance)
    // Avoid: Keys with random prefixes (impacts cache locality)
}
```

## Complete Examples

### Simple Key-Value Store

```zig
const std = @import("std");
const lowkeydb = @import("lowkeydb");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db = try lowkeydb.Database.create("keyvalue_store.db", allocator);
    defer {
        db.close();
        // Clean up database files if needed
        std.fs.cwd().deleteFile("keyvalue_store.db") catch {};
        std.fs.cwd().deleteFile("keyvalue_store.db.wal") catch {};
    }

    // Simple CLI interface
    while (true) {
        std.debug.print("\\nLowkeyDB CLI (put/get/delete/quit): ");
        
        var buffer: [256]u8 = undefined;
        if (try std.io.getStdIn().readUntilDelimiterOrEof(buffer[0..], '\\n')) |input| {
            const trimmed = std.mem.trim(u8, input, " \\n\\r");
            
            if (std.mem.eql(u8, trimmed, "quit")) {
                break;
            }
            
            var parts = std.mem.split(u8, trimmed, " ");
            const command = parts.next() orelse continue;
            
            if (std.mem.eql(u8, command, "put")) {
                const key = parts.next() orelse {
                    std.debug.print("Usage: put <key> <value>\\n", .{});
                    continue;
                };
                const value = parts.rest();
                
                try db.put(key, value);
                std.debug.print("OK\\n", .{});
                
            } else if (std.mem.eql(u8, command, "get")) {
                const key = parts.next() orelse {
                    std.debug.print("Usage: get <key>\\n", .{});
                    continue;
                };
                
                const value = try db.get(key, allocator);
                defer if (value) |v| allocator.free(v);
                
                if (value) |v| {
                    std.debug.print("{s}\\n", .{v});
                } else {
                    std.debug.print("(null)\\n", .{});
                }
                
            } else if (std.mem.eql(u8, command, "delete")) {
                const key = parts.next() orelse {
                    std.debug.print("Usage: delete <key>\\n", .{});
                    continue;
                };
                
                const deleted = try db.delete(key);
                if (deleted) {
                    std.debug.print("OK\\n", .{});
                } else {
                    std.debug.print("Key not found\\n", .{});
                }
            } else {
                std.debug.print("Unknown command: {s}\\n", .{command});
            }
        }
    }
}
```

### Configuration Manager

```zig
const std = @import("std");
const lowkeydb = @import("lowkeydb");

const ConfigManager = struct {
    db: lowkeydb.Database,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(db_path: []const u8, allocator: std.mem.Allocator) !Self {
        const db = try lowkeydb.Database.create(db_path, allocator);
        return Self{
            .db = db,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.db.close();
    }
    
    pub fn setString(self: *Self, section: []const u8, key: []const u8, value: []const u8) !void {
        const full_key = try std.fmt.allocPrint(self.allocator, "config:{}:{}", .{ section, key });
        defer self.allocator.free(full_key);
        try self.db.put(full_key, value);
    }
    
    pub fn getString(self: *Self, section: []const u8, key: []const u8) !?[]u8 {
        const full_key = try std.fmt.allocPrint(self.allocator, "config:{}:{}", .{ section, key });
        defer self.allocator.free(full_key);
        return try self.db.get(full_key, self.allocator);
    }
    
    pub fn setInt(self: *Self, section: []const u8, key: []const u8, value: i64) !void {
        const value_str = try std.fmt.allocPrint(self.allocator, "{}", .{value});
        defer self.allocator.free(value_str);
        try self.setString(section, key, value_str);
    }
    
    pub fn getInt(self: *Self, section: []const u8, key: []const u8, default_value: i64) !i64 {
        const value_str = try self.getString(section, key);
        if (value_str) |str| {
            defer self.allocator.free(str);
            return std.fmt.parseInt(i64, str, 10) catch default_value;
        }
        return default_value;
    }
    
    pub fn setBool(self: *Self, section: []const u8, key: []const u8, value: bool) !void {
        try self.setString(section, key, if (value) "true" else "false");
    }
    
    pub fn getBool(self: *Self, section: []const u8, key: []const u8, default_value: bool) !bool {
        const value_str = try self.getString(section, key);
        if (value_str) |str| {
            defer self.allocator.free(str);
            return std.mem.eql(u8, str, "true");
        }
        return default_value;
    }
};

pub fn configExample() !void {
    const allocator = std.heap.page_allocator;
    
    var config = try ConfigManager.init("app_config.db", allocator);
    defer config.deinit();
    
    // Set configuration values
    try config.setString("database", "host", "localhost");
    try config.setInt("database", "port", 5432);
    try config.setBool("database", "ssl", true);
    
    try config.setString("ui", "theme", "dark");
    try config.setInt("ui", "window_width", 1200);
    try config.setInt("ui", "window_height", 800);
    
    // Read configuration values
    const host = try config.getString("database", "host");
    defer if (host) |h| allocator.free(h);
    
    const port = try config.getInt("database", "port", 3306);
    const ssl = try config.getBool("database", "ssl", false);
    
    std.debug.print("Database Config:\\n", .{});
    std.debug.print("  Host: {s}\\n", .{host orelse "unknown"});
    std.debug.print("  Port: {}\\n", .{port});
    std.debug.print("  SSL: {}\\n", .{ssl});
}
```

## Best Practices

### 1. Resource Management

```zig
// Always use defer for cleanup
var db = try lowkeydb.Database.create("app.db", allocator);
defer db.close();

// Free retrieved values
const value = try db.get("key", allocator);
defer if (value) |v| allocator.free(v);
```

### 2. Error Handling

```zig
// Handle specific database errors
const value = db.get("key", allocator) catch |err| switch (err) {
    lowkeydb.DatabaseError.KeyNotFound => null,
    lowkeydb.DatabaseError.TransactionConflict => {
        // Retry logic here
        return err;
    },
    else => return err,
};
```

### 3. Transaction Management

```zig
// Always handle transaction cleanup
const tx_id = try db.beginTransaction(.serializable);
errdefer db.rollbackTransaction(tx_id) catch {};

// ... transaction operations ...

try db.commitTransaction(tx_id);
```

### 4. Performance Monitoring

```zig
// Regular statistics monitoring
const stats = db.getBufferPoolStats();
if (stats.hit_ratio < 80.0) {
    std.log.warn("Low cache hit ratio: {d:.1}%", .{stats.hit_ratio});
}
```

### 5. Graceful Shutdown

```zig
// Proper shutdown sequence
try db.checkpoint(); // Ensure data is persisted
try db.flushWAL();   // Flush any pending writes
db.stopAutoCheckpoint(); // Stop background threads
db.close(); // Close database
```

## Troubleshooting

### Common Issues

1. **Memory Leaks**: Always free retrieved values and deinitialize allocators
2. **Transaction Deadlocks**: Use shorter transactions and consistent key ordering
3. **Performance Issues**: Monitor buffer pool hit ratios and adjust accordingly
4. **File Locking**: Ensure only one process accesses the database at a time

### Debug Information

```zig
// Enable debug logging
const logging = @import("lowkeydb").logging;
try logging.initGlobalLogger(allocator, .{
    .level = .debug,
    .enable_colors = true,
    .enable_timestamps = true,
});
defer logging.deinitGlobalLogger(allocator);
```

This guide covers the essential aspects of integrating LowkeyDB into your Zig applications. The database provides excellent performance (>25,000 write ops/sec) with full ACID compliance and thread safety.