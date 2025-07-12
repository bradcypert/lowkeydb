const std = @import("std");
const Database = @import("../src/root.zig").Database;
const TypedValue = @import("../src/types.zig").TypedValue;
const TypedValueHelper = @import("../src/types.zig").TypedValueHelper;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a new database
    var db = try Database.create("typed_values_test.db", allocator);
    defer db.deinit();

    std.debug.print("=== LowkeyDB Typed Values Demo ===\n\n");

    // Demo 1: Store and retrieve different types
    std.debug.print("1. Storing different data types:\n");
    
    // String
    try db.putString("name", "John Doe");
    const name = try db.getString("name");
    if (name) |n| {
        defer allocator.free(n);
        std.debug.print("   String: 'name' = '{s}'\n", .{n});
    }
    
    // Integer
    try db.putInteger("age", 30);
    const age = try db.getInteger("age");
    if (age) |a| {
        std.debug.print("   Integer: 'age' = {}\n", .{a});
    }
    
    // Float
    try db.putFloat("salary", 75000.50);
    const salary = try db.getFloat("salary");
    if (salary) |s| {
        std.debug.print("   Float: 'salary' = {d:.2}\n", .{s});
    }
    
    // Boolean
    try db.putBoolean("is_active", true);
    const is_active = try db.getBoolean("is_active");
    if (is_active) |active| {
        std.debug.print("   Boolean: 'is_active' = {}\n", .{active});
    }
    
    // JSON
    try db.putJSON("settings", "{\"theme\": \"dark\", \"notifications\": true}");
    const settings_json = try db.getJSON("settings");
    if (settings_json) |json| {
        defer allocator.free(json);
        std.debug.print("   JSON: 'settings' = {s}\n", .{json});
    }
    
    // Null
    try db.putNull("optional_field");
    const is_null = try db.isNull("optional_field");
    if (is_null) |null_check| {
        std.debug.print("   Null: 'optional_field' is null = {}\n", .{null_check});
    }

    std.debug.print("\n2. Type checking:\n");
    
    // Check types of stored values
    const name_type = try db.getValueType("name");
    const age_type = try db.getValueType("age");
    const salary_type = try db.getValueType("salary");
    
    if (name_type) |t| std.debug.print("   'name' is of type: {s}\n", .{t.toString()});
    if (age_type) |t| std.debug.print("   'age' is of type: {s}\n", .{t.toString()});
    if (salary_type) |t| std.debug.print("   'salary' is of type: {s}\n", .{t.toString()});

    std.debug.print("\n3. Type safety demo (error handling):\n");
    
    // Try to get an integer as a string (should error)
    const wrong_type = db.getString("age");
    if (wrong_type) |_| {
        std.debug.print("   ERROR: This shouldn't happen!\n");
    } else |err| {
        std.debug.print("   ✓ Type safety works: attempting to get integer 'age' as string returns: {}\n", .{err});
    }

    std.debug.print("\n4. Using the generic typed API:\n");
    
    // Store using TypedValue directly
    const complex_value = TypedValueHelper.string("Complex data structure");
    try db.putTyped("complex", complex_value);
    
    const retrieved = try db.getTyped("complex");
    if (retrieved) |val| {
        defer val.deinit(allocator);
        const as_string = try val.toString(allocator);
        defer allocator.free(as_string);
        std.debug.print("   Generic API: 'complex' = {s} (type: {s})\n", .{ as_string, val.getType().toString() });
    }

    std.debug.print("\n5. Binary data support:\n");
    
    // Store binary data
    const binary_data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0xFF };
    const binary_value = TypedValueHelper.binary(&binary_data);
    try db.putTyped("binary_field", binary_value);
    
    const retrieved_binary = try db.getTyped("binary_field");
    if (retrieved_binary) |val| {
        defer val.deinit(allocator);
        switch (val) {
            .binary => |bin| {
                std.debug.print("   Binary data: {} bytes = [", .{bin.len});
                for (bin, 0..) |byte, i| {
                    if (i > 0) std.debug.print(", ");
                    std.debug.print("0x{X:0>2}", .{byte});
                }
                std.debug.print("]\n");
            },
            else => std.debug.print("   ERROR: Expected binary data\n"),
        }
    }

    std.debug.print("\n6. Count total keys in database:\n");
    const total_keys = try db.count();
    std.debug.print("   Total keys stored: {}\n", .{total_keys});

    std.debug.print("\n=== Demo Complete ===\n");
}