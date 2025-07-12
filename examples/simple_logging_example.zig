const std = @import("std");
const logging = @import("../src/logging.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize simple logging
    try logging.initGlobalLogger(allocator, logging.LoggerConfig.default());

    // Test simple logging without context
    logging.info("Simple structured logging test", null);
    logging.warn("This is a warning message", null);
    logging.err("This is an error message", null);

    // Test with context
    var context = logging.LogContext.init(allocator);
    defer context.deinit();
    
    try context.addString("operation", "test");
    try context.addUInt("count", 42);
    try context.addBool("success", true);
    
    logging.info("Operation completed", &context);
    
    std.debug.print("Structured logging example completed successfully!\n", .{});
}