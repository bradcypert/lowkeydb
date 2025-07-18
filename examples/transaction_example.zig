const std = @import("std");
const Database = @import("src/root.zig").Database;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a database
    var db = try Database.create("transaction_example.db", allocator);
    defer {
        db.close();
        std.fs.cwd().deleteFile("transaction_example.db") catch {};
        std.fs.cwd().deleteFile("transaction_example.db.wal") catch {};
    }

    // Update database reference for proper transaction functionality
    db.updateDatabaseReference();

    std.debug.print("=== LowkeyDB Transaction Example ===\n", .{});

    // Example 1: Basic transaction lifecycle
    std.debug.print("\n1. Basic Transaction Lifecycle:\n", .{});
    
    const tx1 = try db.beginTransaction(.read_committed);
    std.debug.print("   Started transaction: {}\n", .{tx1});
    
    try db.putTransaction(tx1, "user:1", "Alice");
    try db.putTransaction(tx1, "user:2", "Bob");
    std.debug.print("   Added users Alice and Bob\n", .{});
    
    // Verify data within transaction
    const alice = try db.getTransaction(tx1, "user:1", allocator);
    if (alice) |value| {
        std.debug.print("   Retrieved user:1 = {s}\n", .{value});
        allocator.free(value);
    }
    
    try db.commitTransaction(tx1);
    std.debug.print("   Committed transaction\n", .{});

    // Example 2: Transaction rollback
    std.debug.print("\n2. Transaction Rollback:\n", .{});
    
    const tx2 = try db.beginTransaction(.read_committed);
    std.debug.print("   Started transaction: {}\n", .{tx2});
    
    try db.putTransaction(tx2, "temp:1", "temporary data");
    try db.putTransaction(tx2, "temp:2", "more temp data");
    std.debug.print("   Added temporary data\n", .{});
    
    try db.rollbackTransaction(tx2);
    std.debug.print("   Rolled back transaction\n", .{});
    
    // Verify rollback worked
    const temp1 = try db.get("temp:1", allocator);
    if (temp1) |value| {
        std.debug.print("   temp:1 = {s} (should not exist!)\n", .{value});
        allocator.free(value);
    } else {
        std.debug.print("   temp:1 correctly does not exist after rollback\n", .{});
    }

    // Example 3: Multiple concurrent transactions
    std.debug.print("\n3. Concurrent Transactions:\n", .{});
    
    const tx3 = try db.beginTransaction(.read_committed);
    const tx4 = try db.beginTransaction(.read_committed);
    const tx5 = try db.beginTransaction(.read_committed);
    
    std.debug.print("   Started 3 concurrent transactions: {}, {}, {}\n", .{tx3, tx4, tx5});
    
    try db.putTransaction(tx3, "store:1", "Product A");
    try db.putTransaction(tx4, "store:2", "Product B");
    try db.putTransaction(tx5, "store:3", "Product C");
    
    // Commit some, rollback others
    try db.commitTransaction(tx3);
    try db.commitTransaction(tx4);
    try db.rollbackTransaction(tx5);
    
    std.debug.print("   Committed tx3 and tx4, rolled back tx5\n", .{});

    // Example 4: Transaction with updates and deletes
    std.debug.print("\n4. Transaction with Updates and Deletes:\n", .{});
    
    const tx6 = try db.beginTransaction(.read_committed);
    
    // Update existing user
    try db.putTransaction(tx6, "user:1", "Alice Updated");
    std.debug.print("   Updated user:1\n", .{});
    
    // Delete a store item
    const deleted = try db.deleteTransaction(tx6, "store:1");
    if (deleted) {
        std.debug.print("   Deleted store:1\n", .{});
    }
    
    try db.commitTransaction(tx6);
    std.debug.print("   Committed update/delete transaction\n", .{});

    // Final verification
    std.debug.print("\n5. Final Database State:\n", .{});
    
    const final_alice = try db.get("user:1", allocator);
    if (final_alice) |value| {
        std.debug.print("   user:1 = {s}\n", .{value});
        allocator.free(value);
    }
    
    const final_bob = try db.get("user:2", allocator);
    if (final_bob) |value| {
        std.debug.print("   user:2 = {s}\n", .{value});
        allocator.free(value);
    }
    
    const store2 = try db.get("store:2", allocator);
    if (store2) |value| {
        std.debug.print("   store:2 = {s}\n", .{value});
        allocator.free(value);
    }
    
    const deleted_store = try db.get("store:1", allocator);
    if (deleted_store) |value| {
        std.debug.print("   store:1 = {s} (should not exist!)\n", .{value});
        allocator.free(value);
    } else {
        std.debug.print("   store:1 correctly deleted\n", .{});
    }

    // Transaction statistics
    std.debug.print("\n6. Transaction Statistics:\n", .{});
    const active_count = db.getActiveTransactionCount();
    std.debug.print("   Active transactions: {}\n", .{active_count});

    std.debug.print("\n✅ Transaction example completed successfully!\n", .{});
    std.debug.print("Transactions provide ACID properties for data consistency.\n", .{});
}