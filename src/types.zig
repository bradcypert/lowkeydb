const std = @import("std");

/// Supported value types in LowkeyDB
pub const ValueType = enum(u8) {
    string = 1,
    integer = 2,
    float = 3,
    binary = 4,
    json = 5,
    boolean = 6,
    null = 7,
    
    pub fn toString(self: ValueType) []const u8 {
        return switch (self) {
            .string => "string",
            .integer => "integer", 
            .float => "float",
            .binary => "binary",
            .json => "json",
            .boolean => "boolean",
            .null => "null",
        };
    }
};

/// A typed value that can be stored in the database
pub const TypedValue = union(ValueType) {
    string: []const u8,
    integer: i64,
    float: f64,
    binary: []const u8,
    json: std.json.Value,
    boolean: bool,
    null: void,
    
    /// Get the type of this value
    pub fn getType(self: TypedValue) ValueType {
        return @as(ValueType, self);
    }
    
    /// Get the size needed to serialize this value
    pub fn getSerializedSize(self: TypedValue) usize {
        return switch (self) {
            .string => |str| 1 + 4 + str.len, // type + length + data
            .integer => 1 + 8, // type + i64
            .float => 1 + 8, // type + f64
            .binary => |bin| 1 + 4 + bin.len, // type + length + data
            .json => |json| blk: {
                // Estimate JSON size (we'll use actual size during serialization)
                var counting_writer = std.io.countingWriter(std.io.null_writer);
                std.json.stringify(json, .{}, counting_writer.writer()) catch unreachable;
                break :blk 1 + 4 + counting_writer.bytes_written;
            },
            .boolean => 1 + 1, // type + bool
            .null => 1, // just type
        };
    }
    
    /// Serialize this value to a writer
    pub fn serialize(self: TypedValue, writer: anytype) !void {
        // Write the type tag
        try writer.writeByte(@intFromEnum(self.getType()));
        
        switch (self) {
            .string => |str| {
                try writer.writeInt(u32, @intCast(str.len), .little);
                try writer.writeAll(str);
            },
            .integer => |int| {
                try writer.writeInt(i64, int, .little);
            },
            .float => |float| {
                try writer.writeInt(u64, @bitCast(float), .little);
            },
            .binary => |bin| {
                try writer.writeInt(u32, @intCast(bin.len), .little);
                try writer.writeAll(bin);
            },
            .json => |json| {
                var json_string = std.ArrayList(u8).init(std.heap.page_allocator);
                defer json_string.deinit();
                try std.json.stringify(json, .{}, json_string.writer());
                try writer.writeInt(u32, @intCast(json_string.items.len), .little);
                try writer.writeAll(json_string.items);
            },
            .boolean => |boolean| {
                try writer.writeByte(if (boolean) 1 else 0);
            },
            .null => {},
        }
    }
    
    /// Deserialize a value from a reader
    pub fn deserialize(reader: anytype, allocator: std.mem.Allocator) !TypedValue {
        const type_byte = try reader.readByte();
        const value_type = @as(ValueType, @enumFromInt(type_byte));
        
        return switch (value_type) {
            .string => {
                const len = try reader.readInt(u32, .little);
                const str = try allocator.alloc(u8, len);
                try reader.readNoEof(str);
                return TypedValue{ .string = str };
            },
            .integer => {
                const int = try reader.readInt(i64, .little);
                return TypedValue{ .integer = int };
            },
            .float => {
                const float_bits = try reader.readInt(u64, .little);
                const float: f64 = @bitCast(float_bits);
                return TypedValue{ .float = float };
            },
            .binary => {
                const len = try reader.readInt(u32, .little);
                const bin = try allocator.alloc(u8, len);
                try reader.readNoEof(bin);
                return TypedValue{ .binary = bin };
            },
            .json => {
                const len = try reader.readInt(u32, .little);
                const json_str = try allocator.alloc(u8, len);
                defer allocator.free(json_str);
                try reader.readNoEof(json_str);
                
                const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
                return TypedValue{ .json = parsed.value };
            },
            .boolean => {
                const bool_byte = try reader.readByte();
                return TypedValue{ .boolean = bool_byte != 0 };
            },
            .null => {
                return TypedValue{ .null = {} };
            },
        };
    }
    
    /// Convert to a byte array for storage (for compatibility with existing APIs)
    pub fn toBytes(self: TypedValue, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        try self.serialize(buffer.writer());
        return buffer.toOwnedSlice();
    }
    
    /// Create a TypedValue from bytes (for compatibility with existing APIs)
    pub fn fromBytes(bytes: []const u8, allocator: std.mem.Allocator) !TypedValue {
        var stream = std.io.fixedBufferStream(bytes);
        return deserialize(stream.reader(), allocator);
    }
    
    /// Free any allocated memory in this value
    pub fn deinit(self: TypedValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |str| allocator.free(str),
            .binary => |bin| allocator.free(bin),
            .json => {}, // JSON values are automatically managed
            else => {},
        }
    }
    
    /// Create a copy of this value
    pub fn clone(self: TypedValue, allocator: std.mem.Allocator) !TypedValue {
        return switch (self) {
            .string => |str| TypedValue{ .string = try allocator.dupe(u8, str) },
            .integer => |int| TypedValue{ .integer = int },
            .float => |float| TypedValue{ .float = float },
            .binary => |bin| TypedValue{ .binary = try allocator.dupe(u8, bin) },
            .json => |json| TypedValue{ .json = try json.cloneWithAllocator(allocator) },
            .boolean => |boolean| TypedValue{ .boolean = boolean },
            .null => TypedValue{ .null = {} },
        };
    }
    
    /// Convert this value to a string representation
    pub fn toString(self: TypedValue, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .string => |str| try allocator.dupe(u8, str),
            .integer => |int| try std.fmt.allocPrint(allocator, "{}", .{int}),
            .float => |float| try std.fmt.allocPrint(allocator, "{d}", .{float}),
            .binary => |bin| try std.fmt.allocPrint(allocator, "binary({} bytes)", .{bin.len}),
            .json => |json| blk: {
                var string = std.ArrayList(u8).init(allocator);
                try std.json.stringify(json, .{}, string.writer());
                break :blk try string.toOwnedSlice();
            },
            .boolean => |boolean| try allocator.dupe(u8, if (boolean) "true" else "false"),
            .null => try allocator.dupe(u8, "null"),
        };
    }
    
    /// Compare two typed values for equality
    pub fn eql(self: TypedValue, other: TypedValue) bool {
        if (self.getType() != other.getType()) return false;
        
        return switch (self) {
            .string => |str| std.mem.eql(u8, str, other.string),
            .integer => |int| int == other.integer,
            .float => |float| float == other.float,
            .binary => |bin| std.mem.eql(u8, bin, other.binary),
            .json => |json| std.meta.eql(json, other.json),
            .boolean => |boolean| boolean == other.boolean,
            .null => true,
        };
    }
};

/// Helper functions for creating TypedValues
pub const TypedValueHelper = struct {
    pub fn string(str: []const u8) TypedValue {
        return TypedValue{ .string = str };
    }
    
    pub fn integer(int: i64) TypedValue {
        return TypedValue{ .integer = int };
    }
    
    pub fn float(f: f64) TypedValue {
        return TypedValue{ .float = f };
    }
    
    pub fn binary(bin: []const u8) TypedValue {
        return TypedValue{ .binary = bin };
    }
    
    pub fn boolean(b: bool) TypedValue {
        return TypedValue{ .boolean = b };
    }
    
    pub fn @"null"() TypedValue {
        return TypedValue{ .null = {} };
    }
    
    pub fn jsonFromString(json_str: []const u8, allocator: std.mem.Allocator) !TypedValue {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        return TypedValue{ .json = parsed.value };
    }
};

// Tests
test "TypedValue basic serialization" {
    const allocator = std.testing.allocator;
    
    // Test string
    const str_val = TypedValueHelper.string("hello world");
    const str_bytes = try str_val.toBytes(allocator);
    defer allocator.free(str_bytes);
    const str_restored = try TypedValue.fromBytes(str_bytes, allocator);
    defer str_restored.deinit(allocator);
    try std.testing.expect(str_val.eql(str_restored));
    
    // Test integer
    const int_val = TypedValueHelper.integer(42);
    const int_bytes = try int_val.toBytes(allocator);
    defer allocator.free(int_bytes);
    const int_restored = try TypedValue.fromBytes(int_bytes, allocator);
    defer int_restored.deinit(allocator);
    try std.testing.expect(int_val.eql(int_restored));
    
    // Test boolean
    const bool_val = TypedValueHelper.boolean(true);
    const bool_bytes = try bool_val.toBytes(allocator);
    defer allocator.free(bool_bytes);
    const bool_restored = try TypedValue.fromBytes(bool_bytes, allocator);
    defer bool_restored.deinit(allocator);
    try std.testing.expect(bool_val.eql(bool_restored));
}

test "TypedValue toString" {
    const allocator = std.testing.allocator;
    
    const int_val = TypedValueHelper.integer(123);
    const int_str = try int_val.toString(allocator);
    defer allocator.free(int_str);
    try std.testing.expectEqualStrings("123", int_str);
    
    const bool_val = TypedValueHelper.boolean(false);
    const bool_str = try bool_val.toString(allocator);
    defer allocator.free(bool_str);
    try std.testing.expectEqualStrings("false", bool_str);
}