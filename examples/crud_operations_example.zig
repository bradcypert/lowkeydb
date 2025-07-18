const std = @import("std");
const Database = @import("src/root.zig").Database;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a database
    var db = try Database.create("crud_example.db", allocator);
    defer {
        db.close();
        std.fs.cwd().deleteFile("crud_example.db") catch {};
        std.fs.cwd().deleteFile("crud_example.db.wal") catch {};
    }

    // Update database reference for proper functionality
    db.updateDatabaseReference();

    std.debug.print("=== LowkeyDB CRUD Operations Example ===\n", .{});

    // Example 1: Basic Insert Operations
    std.debug.print("\n1. INSERT Operations:\n", .{});
    
    const test_data = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "user:001", .value = "Alice Johnson" },
        .{ .key = "user:002", .value = "Bob Smith" },
        .{ .key = "user:003", .value = "Carol Davis" },
        .{ .key = "product:A", .value = "Laptop Computer" },
        .{ .key = "product:B", .value = "Wireless Mouse" },
        .{ .key = "product:C", .value = "Mechanical Keyboard" },
        .{ .key = "order:001", .value = "user:001,product:A,1299.99" },
        .{ .key = "order:002", .value = "user:002,product:B,29.99" },
        .{ .key = "order:003", .value = "user:003,product:C,149.99" },
        .{ .key = "config:timeout", .value = "30000" },
    };
    
    for (test_data) |item| {
        try db.put(item.key, item.value);
        std.debug.print("   Inserted {s} -> {s}\n", .{ item.key, item.value });
    }
    
    std.debug.print("   Total keys inserted: {}\n", .{test_data.len});
    std.debug.print("   Database key count: {}\n", .{db.getKeyCount()});

    // Example 2: READ Operations  
    std.debug.print("\n2. READ Operations:\n", .{});
    
    // Read specific keys
    const read_keys = [_][]const u8{ "user:001", "product:A", "order:002", "config:timeout" };
    
    for (read_keys) |key| {
        const value = try db.get(key, allocator);
        if (value) |val| {
            std.debug.print("   {s} = {s}\n", .{ key, val });
            allocator.free(val);
        } else {
            std.debug.print("   {s} = NOT FOUND\n", .{key});
        }
    }
    
    // Try to read non-existent key
    const missing = try db.get("nonexistent:key", allocator);
    if (missing) |val| {
        std.debug.print("   nonexistent:key = {s} (unexpected!)\n", .{val});
        allocator.free(val);
    } else {
        std.debug.print("   nonexistent:key = NOT FOUND (expected)\n", .{});
    }

    // Example 3: UPDATE Operations
    std.debug.print("\n3. UPDATE Operations:\n", .{});
    
    // Update existing records
    try db.put("user:001", "Alice Johnson-Williams (updated)");
    try db.put("config:timeout", "45000");
    try db.put("product:A", "Laptop Computer - Gaming Edition");
    
    std.debug.print("   Updated user:001, config:timeout, and product:A\n", .{});
    
    // Verify updates
    const updated_user = try db.get("user:001", allocator);
    if (updated_user) |val| {
        std.debug.print("   user:001 now = {s}\n", .{val});
        allocator.free(val);
    }
    
    const updated_config = try db.get("config:timeout", allocator);
    if (updated_config) |val| {
        std.debug.print("   config:timeout now = {s}\n", .{val});
        allocator.free(val);
    }

    // Example 4: DELETE Operations
    std.debug.print("\n4. DELETE Operations:\n", .{});
    
    const keys_to_delete = [_][]const u8{ "order:001", "product:B", "user:002" };
    
    for (keys_to_delete) |key| {
        const deleted = try db.delete(key);
        if (deleted) {
            std.debug.print("   Deleted {s}\n", .{key});
        } else {
            std.debug.print("   Failed to delete {s} (key not found)\n", .{key});
        }
    }
    
    std.debug.print("   Database key count after deletions: {}\n", .{db.getKeyCount()});
    
    // Verify deletions
    for (keys_to_delete) |key| {
        const value = try db.get(key, allocator);
        if (value) |val| {
            std.debug.print("   {s} still exists: {s} (deletion failed!)\n", .{ key, val });
            allocator.free(val);
        } else {
            std.debug.print("   {s} correctly deleted\n", .{key});
        }
    }

    // Example 5: Bulk Operations Pattern
    std.debug.print("\n5. BULK Operations Pattern:\n", .{});
    
    // Insert a batch of configuration settings
    const config_items = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "config:max_connections", .value = "1000" },
        .{ .key = "config:log_level", .value = "INFO" },
        .{ .key = "config:cache_size", .value = "512MB" },
        .{ .key = "config:backup_interval", .value = "3600" },
        .{ .key = "config:encryption", .value = "enabled" },
    };
    
    std.debug.print("   Bulk inserting {} configuration items...\n", .{config_items.len});
    for (config_items) |item| {
        try db.put(item.key, item.value);
    }
    
    // Read back all config items with prefix pattern
    std.debug.print("   Configuration settings:\n", .{});
    for (config_items) |item| {
        const value = try db.get(item.key, allocator);
        if (value) |val| {
            std.debug.print("     {s} = {s}\n", .{ item.key, val });
            allocator.free(val);
        }
    }

    // Example 6: Edge Cases and Error Handling
    std.debug.print("\n6. Edge Cases:\n", .{});
    
    // Try to delete non-existent key
    const missing_delete = try db.delete("does:not:exist");
    std.debug.print("   Delete non-existent key: {}\n", .{missing_delete});
    
    // Try to update then delete same key
    try db.put("temp:key", "temporary value");
    const temp_value = try db.get("temp:key", allocator);
    if (temp_value) |val| {
        std.debug.print("   Created temp:key = {s}\n", .{val});
        allocator.free(val);
    }
    
    const temp_deleted = try db.delete("temp:key");
    std.debug.print("   Deleted temp:key: {}\n", .{temp_deleted});
    
    const temp_check = try db.get("temp:key", allocator);
    if (temp_check) |val| {
        std.debug.print("   temp:key still exists: {s}\n", .{val});
        allocator.free(val);
    } else {
        std.debug.print("   temp:key correctly removed\n", .{});
    }

    // Final summary
    std.debug.print("\n7. Final Database State:\n", .{});
    const final_count = db.getKeyCount();
    std.debug.print("   Total keys in database: {}\n", .{final_count});
    
    // Show remaining keys by reading a few samples
    const sample_keys = [_][]const u8{ "user:001", "user:003", "product:A", "product:C", "order:003" };
    std.debug.print("   Sample remaining data:\n", .{});
    
    for (sample_keys) |key| {
        const value = try db.get(key, allocator);
        if (value) |val| {
            std.debug.print("     {s} = {s}\n", .{ key, val });
            allocator.free(val);
        }
    }

    std.debug.print("\n✅ CRUD operations example completed successfully!\n", .{});
    std.debug.print("LowkeyDB supports all basic database operations with ACID properties.\n", .{});
}