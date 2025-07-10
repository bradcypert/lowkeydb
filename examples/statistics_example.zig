const std = @import("std");
const lowkeydb = @import("../src/root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create or open database
    const db_path = "statistics_example.db";
    var db = lowkeydb.Database.create(db_path, allocator) catch |err| switch (err) {
        lowkeydb.DatabaseError.FileAlreadyExists => try lowkeydb.Database.open(db_path, allocator),
        else => return err,
    };
    defer db.close();

    std.debug.print("=== LowkeyDB Statistics Example ===\n\n");

    // Add some sample data to generate statistics
    std.debug.print("1. Adding sample data...\n");
    try db.put("user:1", "Alice");
    try db.put("user:2", "Bob");
    try db.put("user:3", "Charlie");
    try db.put("product:1", "Laptop");
    try db.put("product:2", "Mouse");
    std.debug.print("   Added 5 key-value pairs\n\n");

    // Basic database statistics
    std.debug.print("2. Basic Database Statistics:\n");
    const key_count = db.getKeyCount();
    std.debug.print("   Total keys: {}\n", .{key_count});

    // Print comprehensive database statistics
    std.debug.print("\n3. Comprehensive Database Statistics:\n");
    try db.printDatabaseStats();

    // Buffer pool statistics
    std.debug.print("\n4. Buffer Pool Statistics:\n");
    try db.printBufferPoolStats();

    // Get buffer pool stats programmatically
    const buffer_stats = db.getBufferPoolStats();
    std.debug.print("\n5. Buffer Pool Stats (programmatic access):\n");
    std.debug.print("   Total pages: {}\n", .{buffer_stats.total_pages});
    std.debug.print("   Used pages: {}\n", .{buffer_stats.used_pages});
    std.debug.print("   Cache hits: {}\n", .{buffer_stats.cache_hits});
    std.debug.print("   Cache misses: {}\n", .{buffer_stats.cache_misses});
    std.debug.print("   Dirty pages: {}\n", .{buffer_stats.dirty_pages});

    // Transaction statistics
    std.debug.print("\n6. Transaction Statistics:\n");
    std.debug.print("   Active transactions: {}\n", .{db.getActiveTransactionCount()});

    // Create some transactions to show transaction statistics
    std.debug.print("\n7. Creating transactions and monitoring...\n");
    const tx1 = try db.beginTransaction(lowkeydb.Transaction.IsolationLevel.read_committed);
    const tx2 = try db.beginTransaction(lowkeydb.Transaction.IsolationLevel.serializable);
    std.debug.print("   Started 2 transactions (IDs: {}, {})\n", .{ tx1, tx2 });
    std.debug.print("   Active transactions: {}\n", .{db.getActiveTransactionCount()});

    // Perform some transactional operations
    try db.putTransaction(tx1, "tx_test:1", "Transaction data 1");
    try db.putTransaction(tx2, "tx_test:2", "Transaction data 2");
    std.debug.print("   Performed transactional operations\n");

    // Commit one transaction, rollback another
    try db.commitTransaction(tx1);
    try db.rollbackTransaction(tx2);
    std.debug.print("   Committed tx1, rolled back tx2\n");
    std.debug.print("   Active transactions: {}\n", .{db.getActiveTransactionCount()});

    // WAL and Checkpoint statistics
    std.debug.print("\n8. WAL and Checkpoint Statistics:\n");
    const checkpoint_stats = db.getCheckpointStats();
    std.debug.print("   Total checkpoints: {}\n", .{checkpoint_stats.checkpoints_performed});
    std.debug.print("   Pages written: {}\n", .{checkpoint_stats.pages_written});
    std.debug.print("   WAL size: {} bytes\n", .{checkpoint_stats.wal_size});
    std.debug.print("   Last checkpoint: {}\n", .{checkpoint_stats.last_checkpoint_time});

    // Force a checkpoint to update statistics
    std.debug.print("\n9. Forcing checkpoint...\n");
    try db.checkpoint();
    std.debug.print("   Checkpoint completed\n");

    // Show updated checkpoint statistics
    const updated_checkpoint_stats = db.getCheckpointStats();
    std.debug.print("   Updated checkpoint count: {}\n", .{updated_checkpoint_stats.checkpoints_performed});
    std.debug.print("   Updated pages written: {}\n", .{updated_checkpoint_stats.pages_written});

    // Flush WAL to ensure all data is written
    std.debug.print("\n10. Flushing WAL...\n");
    try db.flushWAL();
    std.debug.print("    WAL flushed to disk\n");

    // Final statistics summary
    std.debug.print("\n11. Final Statistics Summary:\n");
    std.debug.print("    Total keys: {}\n", .{db.getKeyCount()});
    std.debug.print("    Active transactions: {}\n", .{db.getActiveTransactionCount()});
    
    const final_buffer_stats = db.getBufferPoolStats();
    const hit_ratio = if (final_buffer_stats.cache_hits + final_buffer_stats.cache_misses > 0)
        (@as(f64, @floatFromInt(final_buffer_stats.cache_hits)) / @as(f64, @floatFromInt(final_buffer_stats.cache_hits + final_buffer_stats.cache_misses)) * 100.0)
    else
        0.0;
    std.debug.print("    Cache hit ratio: {d:.2}%\n", .{hit_ratio});

    // Show how to validate database integrity
    std.debug.print("\n12. Database Validation:\n");
    try db.validateBTreeStructure();
    std.debug.print("    Database structure is valid\n");

    std.debug.print("\n=== Statistics Example Complete ===\n");
}