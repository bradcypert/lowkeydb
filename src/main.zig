const std = @import("std");
const lowkeydb = @import("root.zig");

const Command = enum {
    get,
    put,
    delete,
    count,
    sync,
    begin,
    commit,
    rollback,
    tput,
    tget,
    tdelete,
    stats,
    transactions,
    checkpoint_stats,
    buffer_stats,
    checkpoint,
    flush_wal,
    auto_checkpoint,
    validate,
    configure_checkpoint,
    unknown,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const db_path = args[1];

    // Try to open existing database, create if it doesn't exist
    var db = lowkeydb.Database.open(db_path, allocator) catch |err| switch (err) {
        lowkeydb.DatabaseError.FileNotFound => try lowkeydb.Database.create(db_path, allocator),
        else => return err,
    };
    defer db.close();

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    try stdout.print("LowkeyDB CLI - Database: {s}\n", .{db_path});
    try stdout.print("Basic Commands: get <key>, put <key> <value>, delete <key>, count, sync, quit\n", .{});
    try stdout.print("Transaction Commands: begin [isolation_level], commit <tx_id>, rollback <tx_id>\n", .{});
    try stdout.print("                     tput <tx_id> <key> <value>, tget <tx_id> <key>, tdelete <tx_id> <key>\n", .{});
    try stdout.print("Statistics Commands: stats, transactions, checkpoint_stats, buffer_stats\n", .{});
    try stdout.print("WAL Commands: checkpoint, flush_wal, auto_checkpoint <start|stop>\n", .{});
    try stdout.print("Advanced Commands: validate, configure_checkpoint <interval_ms> <max_wal_size_mb> <max_archived>\n\n", .{});

    while (true) {
        try stdout.print("> ", .{});

        var input_buffer: [1024]u8 = undefined;
        if (try stdin.readUntilDelimiterOrEof(input_buffer[0..], '\n')) |input| {
            const trimmed_input = std.mem.trim(u8, input, " \t\r\n");

            if (std.mem.eql(u8, trimmed_input, "quit") or std.mem.eql(u8, trimmed_input, "exit")) {
                break;
            }

            try processCommand(trimmed_input, &db, allocator, stdout);
        } else {
            break;
        }
    }

    try stdout.print("Goodbye!\n", .{});
}

fn parseCommand(command_str: []const u8) Command {
    return std.meta.stringToEnum(Command, command_str) orelse .unknown;
}

fn processCommand(input: []const u8, db: *lowkeydb.Database, allocator: std.mem.Allocator, writer: anytype) !void {
    var parts = std.mem.splitScalar(u8, input, ' ');
    const command_str = parts.next() orelse return;
    const command = parseCommand(command_str);

    switch (command) {
        .get => {
            const key = parts.next() orelse {
                try writer.print("Usage: get <key>\n", .{});
                return;
            };

            const value = db.get(key, allocator) catch |err| {
                try writer.print("Error: {}\n", .{err});
                return;
            };

            if (value) |v| {
                defer allocator.free(v);
                try writer.print("Value: {s}\n", .{v});
            } else {
                try writer.print("Key not found\n", .{});
            }
        },
        .put => {
            const key = parts.next() orelse {
                try writer.print("Usage: put <key> <value>\n", .{});
                return;
            };

            const value = parts.next() orelse {
                try writer.print("Usage: put <key> <value>\n", .{});
                return;
            };

            db.put(key, value) catch |err| {
                try writer.print("Error: {}\n", .{err});
                return;
            };

            try writer.print("OK\n", .{});
        },
        .delete => {
            const key = parts.next() orelse {
                try writer.print("Usage: delete <key>\n", .{});
                return;
            };

            const deleted = db.delete(key) catch |err| {
                try writer.print("Error: {}\n", .{err});
                return;
            };

            if (deleted) {
                try writer.print("Key deleted\n", .{});
            } else {
                try writer.print("Key not found\n", .{});
            }
        },
        .count => {
            const count = db.getKeyCount();
            try writer.print("Key count: {}\n", .{count});
        },
        .sync => {
            db.sync() catch |err| {
                try writer.print("Error: {}\n", .{err});
                return;
            };
            try writer.print("Database synced\n", .{});
        },
        .begin => {
            const isolation_str = parts.next() orelse "read_committed";
            
            const isolation_level = if (std.mem.eql(u8, isolation_str, "read_uncommitted"))
                lowkeydb.Transaction.IsolationLevel.read_uncommitted
            else if (std.mem.eql(u8, isolation_str, "read_committed"))
                lowkeydb.Transaction.IsolationLevel.read_committed
            else if (std.mem.eql(u8, isolation_str, "repeatable_read"))
                lowkeydb.Transaction.IsolationLevel.repeatable_read
            else if (std.mem.eql(u8, isolation_str, "serializable"))
                lowkeydb.Transaction.IsolationLevel.serializable
            else {
                try writer.print("Invalid isolation level: {s}\n", .{isolation_str});
                try writer.print("Available levels: read_uncommitted, read_committed, repeatable_read, serializable\n", .{});
                return;
            };
            
            const tx_id = db.beginTransaction(isolation_level) catch |err| {
                try writer.print("Error: {}\n", .{err});
                return;
            };
            
            try writer.print("Transaction started with ID: {}\n", .{tx_id});
        },
        .commit => {
            const tx_id_str = parts.next() orelse {
                try writer.print("Usage: commit <transaction_id>\n", .{});
                return;
            };
            
            const tx_id = std.fmt.parseInt(u64, tx_id_str, 10) catch {
                try writer.print("Invalid transaction ID: {s}\n", .{tx_id_str});
                return;
            };
            
            db.commitTransaction(tx_id) catch |err| {
                try writer.print("Error: {}\n", .{err});
                return;
            };
            
            try writer.print("Transaction {} committed\n", .{tx_id});
        },
        .rollback => {
            const tx_id_str = parts.next() orelse {
                try writer.print("Usage: rollback <transaction_id>\n", .{});
                return;
            };
            
            const tx_id = std.fmt.parseInt(u64, tx_id_str, 10) catch {
                try writer.print("Invalid transaction ID: {s}\n", .{tx_id_str});
                return;
            };
            
            db.rollbackTransaction(tx_id) catch |err| {
                try writer.print("Error: {}\n", .{err});
                return;
            };
            
            try writer.print("Transaction {} rolled back\n", .{tx_id});
        },
        .tput => {
            const tx_id_str = parts.next() orelse {
                try writer.print("Usage: tput <transaction_id> <key> <value>\n", .{});
                return;
            };
            
            const tx_id = std.fmt.parseInt(u64, tx_id_str, 10) catch {
                try writer.print("Invalid transaction ID: {s}\n", .{tx_id_str});
                return;
            };
            
            const key = parts.next() orelse {
                try writer.print("Usage: tput <transaction_id> <key> <value>\n", .{});
                return;
            };
            
            const value = parts.next() orelse {
                try writer.print("Usage: tput <transaction_id> <key> <value>\n", .{});
                return;
            };
            
            db.putTransaction(tx_id, key, value) catch |err| {
                try writer.print("Error: {}\n", .{err});
                return;
            };
            
            try writer.print("OK\n", .{});
        },
        .tget => {
            const tx_id_str = parts.next() orelse {
                try writer.print("Usage: tget <transaction_id> <key>\n", .{});
                return;
            };
            
            const tx_id = std.fmt.parseInt(u64, tx_id_str, 10) catch {
                try writer.print("Invalid transaction ID: {s}\n", .{tx_id_str});
                return;
            };
            
            const key = parts.next() orelse {
                try writer.print("Usage: tget <transaction_id> <key>\n", .{});
                return;
            };
            
            const value = db.getTransaction(tx_id, key, allocator) catch |err| {
                try writer.print("Error: {}\n", .{err});
                return;
            };
            
            if (value) |v| {
                defer allocator.free(v);
                try writer.print("Value: {s}\n", .{v});
            } else {
                try writer.print("Key not found\n", .{});
            }
        },
        .tdelete => {
            const tx_id_str = parts.next() orelse {
                try writer.print("Usage: tdelete <transaction_id> <key>\n", .{});
                return;
            };
            
            const tx_id = std.fmt.parseInt(u64, tx_id_str, 10) catch {
                try writer.print("Invalid transaction ID: {s}\n", .{tx_id_str});
                return;
            };
            
            const key = parts.next() orelse {
                try writer.print("Usage: tdelete <transaction_id> <key>\n", .{});
                return;
            };
            
            const deleted = db.deleteTransaction(tx_id, key) catch |err| {
                try writer.print("Error: {}\n", .{err});
                return;
            };
            
            if (deleted) {
                try writer.print("Key deleted\n", .{});
            } else {
                try writer.print("Key not found\n", .{});
            }
        },
        .stats => {
            db.printDatabaseStats();
        },
        .transactions => {
            const count = db.getActiveTransactionCount();
            try writer.print("Active transactions: {}\n", .{count});
        },
        .checkpoint_stats => {
            const stats = db.getCheckpointStats();
            try writer.print("Checkpoint Statistics:\n", .{});
            try writer.print("  Total checkpoints: {}\n", .{stats.checkpoints_performed});
            try writer.print("  Pages written: {}\n", .{stats.pages_written});
            try writer.print("  WAL size: {} bytes\n", .{stats.wal_size});
            try writer.print("  Last checkpoint: {}\n", .{stats.last_checkpoint_time});
        },
        .buffer_stats => {
            db.printBufferPoolStats();
        },
        .checkpoint => {
            db.checkpoint() catch |err| {
                try writer.print("Error: {}\n", .{err});
                return;
            };
            try writer.print("Checkpoint completed\n", .{});
        },
        .flush_wal => {
            db.flushWAL() catch |err| {
                try writer.print("Error: {}\n", .{err});
                return;
            };
            try writer.print("WAL flushed\n", .{});
        },
        .auto_checkpoint => {
            const action = parts.next() orelse {
                try writer.print("Usage: auto_checkpoint <start|stop>\n", .{});
                return;
            };
            
            if (std.mem.eql(u8, action, "start")) {
                db.startAutoCheckpoint() catch |err| {
                    try writer.print("Error: {}\n", .{err});
                    return;
                };
                try writer.print("Auto checkpoint started\n", .{});
            } else if (std.mem.eql(u8, action, "stop")) {
                db.stopAutoCheckpoint();
                try writer.print("Auto checkpoint stopped\n", .{});
            } else {
                try writer.print("Invalid action: {s}. Use 'start' or 'stop'\n", .{action});
            }
        },
        .validate => {
            db.validateBTreeStructure() catch |err| {
                try writer.print("Validation failed: {}\n", .{err});
                return;
            };
            try writer.print("Database structure is valid\n", .{});
        },
        .configure_checkpoint => {
            const interval_str = parts.next() orelse {
                try writer.print("Usage: configure_checkpoint <interval_ms> <max_wal_size_mb> <max_archived>\n", .{});
                return;
            };
            
            const max_size_str = parts.next() orelse {
                try writer.print("Usage: configure_checkpoint <interval_ms> <max_wal_size_mb> <max_archived>\n", .{});
                return;
            };
            
            const max_archived_str = parts.next() orelse {
                try writer.print("Usage: configure_checkpoint <interval_ms> <max_wal_size_mb> <max_archived>\n", .{});
                return;
            };
            
            const interval = std.fmt.parseInt(u64, interval_str, 10) catch {
                try writer.print("Invalid interval: {s}\n", .{interval_str});
                return;
            };
            
            const max_size = std.fmt.parseInt(u32, max_size_str, 10) catch {
                try writer.print("Invalid max WAL size: {s}\n", .{max_size_str});
                return;
            };
            
            const max_archived = std.fmt.parseInt(u32, max_archived_str, 10) catch {
                try writer.print("Invalid max archived count: {s}\n", .{max_archived_str});
                return;
            };
            
            db.configureCheckpointing(interval, max_size, max_archived);
            try writer.print("Checkpoint configuration updated\n", .{});
        },
        .unknown => {
            try writer.print("Unknown command: {s}\n", .{command_str});
            try writer.print("Available commands:\n", .{});
            try writer.print("  Basic: get, put, delete, count, sync, quit\n", .{});
            try writer.print("  Transaction: begin, commit, rollback, tput, tget, tdelete\n", .{});
            try writer.print("  Statistics: stats, transactions, checkpoint_stats, buffer_stats\n", .{});
            try writer.print("  WAL: checkpoint, flush_wal, auto_checkpoint\n", .{});
            try writer.print("  Advanced: validate, configure_checkpoint\n", .{});
        },
    }
}

fn printUsage() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Usage: lowkeydb <database_path>\n", .{});
    try stdout.print("Opens or creates a LowkeyDB database at the specified path.\n", .{});
}
