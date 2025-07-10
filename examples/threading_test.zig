const std = @import("std");

// Note: To build this example, copy it to the project root and build with:
// zig build-exe threading_test.zig -I src/
const Database = @import("src/database.zig").Database;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create database
    var db = try Database.create("threading_test.db", allocator);
    defer {
        db.close();
        std.fs.cwd().deleteFile("threading_test.db") catch {};
    }

    std.debug.print("Testing basic single-threaded operations...\n", .{});
    
    // Test basic operations
    try db.put("test1", "value1");
    const result = try db.get("test1", allocator);
    defer if (result) |r| allocator.free(r);
    
    if (result) |value| {
        std.debug.print("Retrieved: {s}\n", .{value});
    } else {
        std.debug.print("Key not found!\n", .{});
    }
    
    std.debug.print("Key count: {}\n", .{db.getKeyCount()});
    std.debug.print("Basic test completed successfully!\n", .{});
}