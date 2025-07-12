const std = @import("std");

/// Log levels in order of severity
pub const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    fatal = 4,
    
    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }
    
    pub fn fromString(str: []const u8) ?LogLevel {
        if (std.mem.eql(u8, str, "debug")) return .debug;
        if (std.mem.eql(u8, str, "info")) return .info;
        if (std.mem.eql(u8, str, "warn")) return .warn;
        if (std.mem.eql(u8, str, "error")) return .err;
        if (std.mem.eql(u8, str, "fatal")) return .fatal;
        return null;
    }
};

/// Log output destination
pub const LogOutput = enum {
    stderr,
    stdout,
    file,
    none, // Disable logging
};

/// Logger configuration
pub const LogConfig = struct {
    level: LogLevel = .info,
    output: LogOutput = .stderr,
    file_path: ?[]const u8 = null,
    enable_timestamps: bool = true,
    enable_colors: bool = true,
    max_file_size: usize = 10 * 1024 * 1024, // 10MB
    max_backup_files: u32 = 5,
};

/// Log context for structured logging
pub const LogContext = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    fields: std.StringHashMap([]const u8),
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .fields = std.StringHashMap([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        var iterator = self.fields.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.fields.deinit();
    }
    
    pub fn addField(self: *Self, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);
        try self.fields.put(owned_key, owned_value);
    }
    
    pub fn addFieldFmt(self: *Self, key: []const u8, comptime fmt: []const u8, args: anytype) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.fields.put(owned_key, owned_value);
    }
};

/// Main logger structure
pub const Logger = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    config: LogConfig,
    file: ?std.fs.File = null,
    mutex: std.Thread.Mutex = std.Thread.Mutex{},
    
    pub fn init(allocator: std.mem.Allocator, config: LogConfig) !Self {
        var logger = Self{
            .allocator = allocator,
            .config = config,
        };
        
        if (config.output == .file) {
            if (config.file_path) |path| {
                logger.file = try std.fs.cwd().createFile(path, .{
                    .read = true,
                    .truncate = false,
                });
                try logger.file.?.seekFromEnd(0); // Append mode
            }
        }
        
        return logger;
    }
    
    pub fn deinit(self: *Self) void {
        if (self.file) |file| {
            file.close();
        }
    }
    
    /// Log a message with the specified level
    pub fn log(self: *Self, level: LogLevel, message: []const u8, context: ?*const LogContext) void {
        if (@intFromEnum(level) < @intFromEnum(self.config.level)) {
            return; // Log level too low
        }
        
        if (self.config.output == .none) {
            return; // Logging disabled
        }
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var buffer: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        const writer = fbs.writer();
        
        // Write timestamp
        if (self.config.enable_timestamps) {
            const timestamp = std.time.timestamp();
            const epoch_seconds = @as(u64, @intCast(timestamp));
            const datetime = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
            const day_seconds = datetime.getDaySeconds();
            const year_day = datetime.getEpochDay().calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            
            writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ", .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                day_seconds.getHoursIntoDay(),
                day_seconds.getMinutesIntoHour(),
                day_seconds.getSecondsIntoMinute(),
            }) catch {};
        }
        
        // Write log level with color
        if (self.config.enable_colors and self.config.output != .file) {
            const color = switch (level) {
                .debug => "\x1b[36m", // Cyan
                .info => "\x1b[32m",  // Green
                .warn => "\x1b[33m",  // Yellow
                .err => "\x1b[31m",   // Red
                .fatal => "\x1b[35m", // Magenta
            };
            writer.print("{s}[{s}]\x1b[0m ", .{ color, level.toString() }) catch {};
        } else {
            writer.print("[{s}] ", .{level.toString()}) catch {};
        }
        
        // Write message
        writer.print("{s}", .{message}) catch {};
        
        // Write context fields
        if (context) |ctx| {
            var iterator = ctx.fields.iterator();
            if (iterator.next() != null) {
                writer.print(" {{", .{}) catch {};
                
                var first = true;
                iterator = ctx.fields.iterator();
                while (iterator.next()) |entry| {
                    if (!first) {
                        writer.print(", ", .{}) catch {};
                    }
                    writer.print("{s}=\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {};
                    first = false;
                }
                writer.print("}}", .{}) catch {};
            }
        }
        
        writer.print("\n", .{}) catch {};
        
        // Output the formatted message
        const output = fbs.getWritten();
        switch (self.config.output) {
            .stderr => std.io.getStdErr().writeAll(output) catch {},
            .stdout => std.io.getStdOut().writeAll(output) catch {},
            .file => if (self.file) |file| {
                file.writeAll(output) catch {};
            },
            .none => {},
        }
    }
    
    /// Convenience logging methods
    pub fn debug(self: *Self, message: []const u8, context: ?*const LogContext) void {
        self.log(.debug, message, context);
    }
    
    pub fn info(self: *Self, message: []const u8, context: ?*const LogContext) void {
        self.log(.info, message, context);
    }
    
    pub fn warn(self: *Self, message: []const u8, context: ?*const LogContext) void {
        self.log(.warn, message, context);
    }
    
    pub fn err(self: *Self, message: []const u8, context: ?*const LogContext) void {
        self.log(.err, message, context);
    }
    
    pub fn fatal(self: *Self, message: []const u8, context: ?*const LogContext) void {
        self.log(.fatal, message, context);
    }
    
    /// Formatted logging methods
    pub fn debugFmt(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(message);
        self.debug(message, null);
    }
    
    pub fn infoFmt(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(message);
        self.info(message, null);
    }
    
    pub fn warnFmt(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(message);
        self.warn(message, null);
    }
    
    pub fn errFmt(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(message);
        self.err(message, null);
    }
    
    pub fn fatalFmt(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(message);
        self.fatal(message, null);
    }
};

/// Global logger instance
var global_logger: ?*Logger = null;
var global_logger_mutex: std.Thread.Mutex = std.Thread.Mutex{};

/// Initialize the global logger
pub fn initGlobalLogger(allocator: std.mem.Allocator, config: LogConfig) !void {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();
    
    if (global_logger) |logger| {
        logger.deinit();
        allocator.destroy(logger);
    }
    
    const logger = try allocator.create(Logger);
    logger.* = try Logger.init(allocator, config);
    global_logger = logger;
}

/// Get the global logger
pub fn getGlobalLogger() ?*Logger {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();
    return global_logger;
}

/// Cleanup the global logger (useful for tests)
pub fn deinitGlobalLogger(allocator: std.mem.Allocator) void {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();
    
    if (global_logger) |logger| {
        logger.deinit();
        allocator.destroy(logger);
        global_logger = null;
    }
}

/// Convenience functions using global logger
pub fn debug(message: []const u8, context: ?*const LogContext) void {
    if (getGlobalLogger()) |logger| {
        logger.debug(message, context);
    }
}

pub fn info(message: []const u8, context: ?*const LogContext) void {
    if (getGlobalLogger()) |logger| {
        logger.info(message, context);
    }
}

pub fn warn(message: []const u8, context: ?*const LogContext) void {
    if (getGlobalLogger()) |logger| {
        logger.warn(message, context);
    }
}

pub fn err(message: []const u8, context: ?*const LogContext) void {
    if (getGlobalLogger()) |logger| {
        logger.err(message, context);
    }
}

pub fn fatal(message: []const u8, context: ?*const LogContext) void {
    if (getGlobalLogger()) |logger| {
        logger.fatal(message, context);
    }
}

/// Create a log context helper
pub fn withContext(allocator: std.mem.Allocator) LogContext {
    return LogContext.init(allocator);
}

// Tests
test "Logger basic functionality" {
    const allocator = std.testing.allocator;
    
    const config = LogConfig{
        .level = .debug,
        .output = .none, // Don't output during tests
        .enable_timestamps = false,
        .enable_colors = false,
    };
    
    var logger = try Logger.init(allocator, config);
    defer logger.deinit();
    
    // Test logging methods don't crash
    logger.debug("Test debug message", null);
    logger.info("Test info message", null);
    logger.warn("Test warn message", null);
    logger.err("Test error message", null);
    logger.fatal("Test fatal message", null);
}

test "LogContext functionality" {
    const allocator = std.testing.allocator;
    
    var context = LogContext.init(allocator);
    defer context.deinit();
    
    try context.addField("user_id", "12345");
    try context.addField("operation", "database_query");
    try context.addFieldFmt("duration_ms", "{d}", .{42});
    
    try std.testing.expect(context.fields.count() == 3);
    try std.testing.expectEqualStrings("12345", context.fields.get("user_id").?);
    try std.testing.expectEqualStrings("database_query", context.fields.get("operation").?);
    try std.testing.expectEqualStrings("42", context.fields.get("duration_ms").?);
}

test "LogLevel functionality" {
    try std.testing.expectEqualStrings("DEBUG", LogLevel.debug.toString());
    try std.testing.expectEqualStrings("INFO", LogLevel.info.toString());
    try std.testing.expectEqualStrings("WARN", LogLevel.warn.toString());
    try std.testing.expectEqualStrings("ERROR", LogLevel.err.toString());
    try std.testing.expectEqualStrings("FATAL", LogLevel.fatal.toString());
    
    try std.testing.expect(LogLevel.fromString("debug") == .debug);
    try std.testing.expect(LogLevel.fromString("info") == .info);
    try std.testing.expect(LogLevel.fromString("invalid") == null);
}

test "Global logger" {
    const allocator = std.testing.allocator;
    
    const config = LogConfig{
        .level = .info,
        .output = .none,
    };
    
    // Save current global logger state
    const old_logger = global_logger;
    global_logger = null;
    
    try initGlobalLogger(allocator, config);
    
    const logger = getGlobalLogger();
    try std.testing.expect(logger != null);
    
    // Test global convenience functions
    info("Test global info", null);
    warn("Test global warn", null);
    
    // Cleanup - use proper cleanup function
    global_logger_mutex.lock();
    if (global_logger) |l| {
        l.deinit();
        allocator.destroy(l);
        global_logger = null;
    }
    global_logger_mutex.unlock();
    
    // Restore old state
    global_logger = old_logger;
}