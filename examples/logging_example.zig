const std = @import("std");
const logging = @import("../src/logging.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== LowkeyDB Structured Logging Example ===\n\n", .{});

    // Test different logging configurations
    const configs = [_]struct {
        name: []const u8,
        config: logging.LoggerConfig,
    }{
        .{
            .name = "Text Format (Default)",
            .config = logging.LoggerConfig.default(),
        },
        .{
            .name = "JSON Format",
            .config = logging.LoggerConfig{
                .format = .json,
                .use_colors = false,
            },
        },
        .{
            .name = "Compact Format",
            .config = logging.LoggerConfig{
                .format = .compact,
                .level = .debug,
                .include_timestamp = false,
            },
        },
        .{
            .name = "Debug Format",
            .config = logging.LoggerConfig.debug(),
        },
    };

    for (configs) |test_config| {
        std.debug.print("--- {s} ---\n", .{test_config.name});
        
        var logger = try logging.StructuredLogger.init(allocator, test_config.config);
        defer logger.deinit();
        
        // Test basic logging
        logger.info("Database operation started", null);
        logger.warn("Buffer pool usage high", null);
        logger.err("Transaction conflict detected", null);
        
        // Test logging with context
        var context = logging.LogContext.init(allocator);
        defer context.deinit();
        
        try context.addString("operation", "put");
        try context.addString("key", "user:123");
        try context.addUInt("value_size", 256);
        try context.addFloat("latency_ms", 1.23);
        try context.addBool("cache_hit", true);
        
        logger.info("Operation completed", &context);
        
        // Test builder pattern
        if (logger.withContext(.debug, "Transaction committed")) |*ctx| {
            ctx.addString("tx_id", "tx_456")
                .addUInt("operations", 5)
                .addFloat("duration_ms", 15.7)
                .addBool("success", true)
                .commit();
        }
        
        std.debug.print("\n", .{});
    }

    // Test global logger
    std.debug.print("--- Global Logger Test ---\n", .{});
    try logging.initGlobalLogger(allocator, logging.LoggerConfig.default());
    
    logging.info("Using global logger", null);
    
    if (logging.withContext(.info, "Global logger with context")) |*ctx| {
        ctx.addString("component", "database")
            .addUInt("version", 1)
            .commit();
    }

    std.debug.print("\n=== Logging Example Complete ===\n", .{});
}