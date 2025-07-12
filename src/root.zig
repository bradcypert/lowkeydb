const std = @import("std");
const logging = @import("logging.zig");

// Public API exports
pub const Database = @import("database.zig").Database;
pub const DatabaseError = @import("error.zig").DatabaseError;
pub const KeyValue = @import("storage/btree.zig").KeyValue;
pub const Transaction = @import("transaction.zig").Transaction;
pub const TransactionManager = @import("transaction.zig").TransactionManager;
pub const WAL = @import("wal.zig").WAL;

// Re-export for convenience
pub const create = Database.create;
pub const open = Database.open;

test "basic database operations" {
    const allocator = std.testing.allocator;
    
    const db_path = "test_basic.db";
    
    // Create database
    var db = try Database.create(db_path, allocator);
    defer {
        db.close();
        std.fs.cwd().deleteFile(db_path) catch {};
        // Clean up global logger to prevent memory leaks in tests
        logging.deinitGlobalLogger(allocator);
    }
    
    // Test put and get
    try db.put("hello", "world");
    try db.put("foo", "bar");
    
    const value1 = try db.get("hello", allocator);
    defer if (value1) |v| allocator.free(v);
    try std.testing.expectEqualSlices(u8, "world", value1.?);
    
    const value2 = try db.get("foo", allocator);
    defer if (value2) |v| allocator.free(v);
    try std.testing.expectEqualSlices(u8, "bar", value2.?);
    
    // Test non-existent key
    const value3 = try db.get("nonexistent", allocator);
    try std.testing.expect(value3 == null);
    
    // Test key count
    try std.testing.expectEqual(@as(u64, 2), db.getKeyCount());
    
    // Test delete
    const deleted = try db.delete("hello");
    try std.testing.expect(deleted);
    
    const value4 = try db.get("hello", allocator);
    try std.testing.expect(value4 == null);
    
    try std.testing.expectEqual(@as(u64, 1), db.getKeyCount());
}

test "database creation and basic operations" {
    const allocator = std.testing.allocator;
    
    const db_path = "test_persist.db";
    
    // Create database and add data
    var db = try Database.create(db_path, allocator);
    defer {
        db.close();
        std.fs.cwd().deleteFile(db_path) catch {};
        // Clean up global logger to prevent memory leaks in tests
        logging.deinitGlobalLogger(allocator);
    }
    
    try db.put("test", "value");
    
    const value = try db.get("test", allocator);
    defer if (value) |v| allocator.free(v);
    
    try std.testing.expectEqualSlices(u8, "value", value.?);
    try std.testing.expectEqual(@as(u64, 1), db.getKeyCount());
}
