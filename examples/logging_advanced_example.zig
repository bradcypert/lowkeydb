const std = @import("std");
const logging = @import("../src/logging.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example 1: Basic logging with different levels
    std.debug.print("\n=== Example 1: Basic Logging ===\n", .{});
    
    const config = logging.LogConfig{
        .level = .debug,
        .output = .stderr,
        .enable_timestamps = true,
        .enable_colors = true,
    };
    
    try logging.initGlobalLogger(allocator, config);
    
    logging.debug("This is a debug message", null);
    logging.info("Database started successfully", null);
    logging.warn("Buffer pool is 90% full", null);
    logging.err("Failed to connect to remote server", null);
    logging.fatal("Database corruption detected", null);

    // Example 2: Structured logging with context
    std.debug.print("\n=== Example 2: Structured Logging ===\n", .{});
    
    var context = logging.withContext(allocator);
    defer context.deinit();
    
    try context.addField("user_id", "user_12345");
    try context.addField("operation", "database_query");
    try context.addFieldFmt("duration_ms", "{d}", .{142});
    try context.addField("table", "users");
    
    if (logging.getGlobalLogger()) |logger| {
        logger.info("Query executed successfully", &context);
        logger.warn("Query took longer than expected", &context);
    }

    // Example 3: Formatted logging
    std.debug.print("\n=== Example 3: Formatted Logging ===\n", .{});
    
    if (logging.getGlobalLogger()) |logger| {
        logger.infoFmt("Processing {d} records from table '{s}'", .{ 1000, "orders" });
        logger.warnFmt("Memory usage: {d:.1}MB / {d}MB", .{ 85.7, 100 });
        logger.errFmt("Connection timeout after {d}ms", .{5000});
    }

    // Example 4: Log levels filtering
    std.debug.print("\n=== Example 4: Log Level Filtering ===\n", .{});
    
    const warn_only_config = logging.LogConfig{
        .level = .warn, // Only show warnings and above
        .output = .stderr,
        .enable_timestamps = false,
        .enable_colors = true,
    };
    
    try logging.initGlobalLogger(allocator, warn_only_config);
    
    logging.debug("This won't be shown (below warn level)");
    logging.info("This won't be shown either");
    logging.warn("This warning will be shown");
    logging.err("This error will be shown");

    // Example 5: Different output formats
    std.debug.print("\n=== Example 5: No Colors/Timestamps ===\n", .{});
    
    const simple_config = logging.LogConfig{
        .level = .info,
        .output = .stderr,
        .enable_timestamps = false,
        .enable_colors = false,
    };
    
    try logging.initGlobalLogger(allocator, simple_config);
    
    logging.info("Simple log message without colors or timestamps", null);
    logging.err("Error message in plain format", null);

    // Example 6: File logging
    std.debug.print("\n=== Example 6: File Logging ===\n", .{});
    
    const file_config = logging.LogConfig{
        .level = .debug,
        .output = .file,
        .file_path = "lowkeydb.log",
        .enable_timestamps = true,
        .enable_colors = false, // No colors in files
    };
    
    try logging.initGlobalLogger(allocator, file_config);
    
    logging.info("This message goes to lowkeydb.log file", null);
    logging.debug("Debug information written to file", null);
    
    var file_context = logging.withContext(allocator);
    defer file_context.deinit();
    try file_context.addField("component", "buffer_pool");
    try file_context.addField("action", "eviction");
    
    if (logging.getGlobalLogger()) |logger| {
        logger.info("Buffer pool eviction completed", &file_context);
    }
    
    std.debug.print("Check 'lowkeydb.log' file for the logged messages!\n", .{});

    // Cleanup
    if (logging.getGlobalLogger()) |logger| {
        logger.deinit();
    }
}