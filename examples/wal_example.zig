const std = @import("std");
const Database = @import("root.zig").Database;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a database with WAL enabled
    var db = try Database.create("wal_example.db", allocator);
    defer {
        db.close();
        std.fs.cwd().deleteFile("wal_example.db") catch {};
        std.fs.cwd().deleteFile("wal_example.db.wal") catch {};
    }

    // Update database reference for proper rollback functionality
    db.updateDatabaseReference();

    std.debug.print("=== LowkeyDB WAL Example ===\n", .{});

    // Demonstrate basic WAL functionality
    std.debug.print("\n1. Transaction with WAL logging:\n", .{});
    
    const tx1 = try db.beginTransaction(.read_committed);
    std.debug.print("   Started transaction: {}\n", .{tx1});
    
    try db.putTransaction(tx1, "user:1", "John Doe");
    try db.putTransaction(tx1, "user:2", "Jane Smith");
    std.debug.print("   Inserted user data\n", .{});
    
    try db.commitTransaction(tx1);
    std.debug.print("   Committed transaction (logged to WAL)\n", .{});

    // Demonstrate rollback with WAL
    std.debug.print("\n2. Transaction rollback with WAL:\n", .{});
    
    const tx2 = try db.beginTransaction(.read_committed);
    std.debug.print("   Started transaction: {}\n", .{tx2});
    
    try db.putTransaction(tx2, "temp:1", "temporary data");
    try db.putTransaction(tx2, "temp:2", "more temporary data");
    std.debug.print("   Inserted temporary data\n", .{});
    
    try db.rollbackTransaction(tx2);
    std.debug.print("   Rolled back transaction (logged to WAL)\n", .{});

    // Verify data state
    std.debug.print("\n3. Verifying data state:\n", .{});
    
    const user1 = try db.get("user:1", allocator);
    if (user1) |value| {
        std.debug.print("   user:1 = {s}\n", .{value});
        allocator.free(value);
    }
    
    const user2 = try db.get("user:2", allocator);
    if (user2) |value| {
        std.debug.print("   user:2 = {s}\n", .{value});
        allocator.free(value);
    }
    
    const temp1 = try db.get("temp:1", allocator);
    if (temp1) |value| {
        std.debug.print("   temp:1 = {s} (should not exist)\n", .{value});
        allocator.free(value);
    } else {
        std.debug.print("   temp:1 = null (correctly rolled back)\n", .{});
    }

    // Demonstrate WAL checkpointing
    std.debug.print("\n4. WAL checkpoint:\n", .{});
    
    try db.checkpoint();
    std.debug.print("   Created WAL checkpoint\n", .{});
    
    // Demonstrate manual WAL flush
    std.debug.print("\n5. Manual WAL flush:\n", .{});
    
    try db.flushWAL();
    std.debug.print("   Flushed WAL to disk\n", .{});

    // Show transaction statistics
    std.debug.print("\n6. Transaction statistics:\n", .{});
    const active_count = db.getActiveTransactionCount();
    std.debug.print("   Active transactions: {}\n", .{active_count});
    
    const current_lsn = db.wal_manager.getCurrentLSN();
    std.debug.print("   Current LSN: {}\n", .{current_lsn});
    
    const checkpoint_lsn = db.wal_manager.getLastCheckpointLSN();
    std.debug.print("   Last checkpoint LSN: {}\n", .{checkpoint_lsn});

    std.debug.print("\n✅ WAL example completed successfully!\n", .{});
    std.debug.print("WAL provides durability guarantees and crash recovery capability.\n", .{});
}