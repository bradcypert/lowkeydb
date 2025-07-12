// C API wrapper for LowkeyDB
// This provides a C-compatible interface to the LowkeyDB database

const std = @import("std");
const Database = @import("database.zig").Database;
const DatabaseError = @import("error.zig").DatabaseError;
const Transaction = @import("transaction.zig").Transaction;

// Opaque handle for C API
pub const LowkeyDB = opaque {};
pub const LowkeyDBTransaction = opaque {};

// Error codes for C API
pub const LOWKEY_OK: c_int = 0;
pub const LOWKEY_ERROR_INVALID_PARAM: c_int = -1;
pub const LOWKEY_ERROR_MEMORY: c_int = -2;
pub const LOWKEY_ERROR_IO: c_int = -3;
pub const LOWKEY_ERROR_KEY_NOT_FOUND: c_int = -4;
pub const LOWKEY_ERROR_TRANSACTION_CONFLICT: c_int = -5;
pub const LOWKEY_ERROR_INVALID_TRANSACTION: c_int = -6;
pub const LOWKEY_ERROR_GENERIC: c_int = -100;

// Transaction isolation levels
pub const LOWKEY_READ_COMMITTED: c_int = 0;
pub const LOWKEY_REPEATABLE_READ: c_int = 1;
pub const LOWKEY_SERIALIZABLE: c_int = 2;

// Buffer pool statistics structure for C
pub const LowkeyDBBufferStats = extern struct {
    capacity: u32,
    pages_in_buffer: u32,
    cache_hits: u64,
    cache_misses: u64,
    hit_ratio: f64,
    evictions: u64,
    write_backs: u64,
};

// WAL checkpoint statistics structure for C
pub const LowkeyDBCheckpointStats = extern struct {
    checkpoints_performed: u64,
    pages_written: u64,
    wal_size: u64,
    last_checkpoint_time: u64,
};

// Internal wrapper structure
const DatabaseWrapper = struct {
    db: Database,
    allocator: std.mem.Allocator,
};

// Global allocator for C API (using page allocator for simplicity)
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const c_allocator = gpa.allocator();

// Convert Zig errors to C error codes
fn zigErrorToC(err: anyerror) c_int {
    return switch (err) {
        DatabaseError.KeyNotFound => LOWKEY_ERROR_KEY_NOT_FOUND,
        DatabaseError.TransactionConflict => LOWKEY_ERROR_TRANSACTION_CONFLICT,
        DatabaseError.InvalidTransaction => LOWKEY_ERROR_INVALID_TRANSACTION,
        error.OutOfMemory => LOWKEY_ERROR_MEMORY,
        else => LOWKEY_ERROR_GENERIC,
    };
}

// C API Functions

/// Create a new database
/// @param db_path Path to the database file
/// @param db_handle Output parameter for database handle
/// @return Error code (LOWKEY_OK on success)
export fn lowkeydb_create(db_path: [*:0]const u8, db_handle: *?*LowkeyDB) c_int {
    const path_slice = std.mem.span(db_path);
    
    const wrapper = c_allocator.create(DatabaseWrapper) catch {
        return LOWKEY_ERROR_MEMORY;
    };
    
    wrapper.* = DatabaseWrapper{
        .db = Database.create(path_slice, c_allocator) catch |err| {
            c_allocator.destroy(wrapper);
            return zigErrorToC(err);
        },
        .allocator = c_allocator,
    };
    
    db_handle.* = @ptrCast(wrapper);
    return LOWKEY_OK;
}

/// Open an existing database
/// @param db_path Path to the database file
/// @param db_handle Output parameter for database handle
/// @return Error code (LOWKEY_OK on success)
export fn lowkeydb_open(db_path: [*:0]const u8, db_handle: *?*LowkeyDB) c_int {
    const path_slice = std.mem.span(db_path);
    
    const wrapper = c_allocator.create(DatabaseWrapper) catch {
        return LOWKEY_ERROR_MEMORY;
    };
    
    wrapper.* = DatabaseWrapper{
        .db = Database.open(path_slice, c_allocator) catch |err| {
            c_allocator.destroy(wrapper);
            return zigErrorToC(err);
        },
        .allocator = c_allocator,
    };
    
    db_handle.* = @ptrCast(wrapper);
    return LOWKEY_OK;
}

/// Close and free database
/// @param db_handle Database handle
export fn lowkeydb_close(db_handle: ?*LowkeyDB) void {
    if (db_handle) |handle| {
        const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(handle));
        wrapper.db.close();
        c_allocator.destroy(wrapper);
    }
}

/// Put a key-value pair
/// @param db_handle Database handle
/// @param key Key string (null-terminated)
/// @param value Value string (null-terminated)
/// @return Error code (LOWKEY_OK on success)
export fn lowkeydb_put(db_handle: ?*LowkeyDB, key: [*:0]const u8, value: [*:0]const u8) c_int {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return LOWKEY_ERROR_INVALID_PARAM));
    const key_slice = std.mem.span(key);
    const value_slice = std.mem.span(value);
    
    wrapper.db.put(key_slice, value_slice) catch |err| {
        return zigErrorToC(err);
    };
    
    return LOWKEY_OK;
}

/// Get a value by key
/// @param db_handle Database handle
/// @param key Key string (null-terminated)
/// @param value_out Output parameter for value (caller must free with lowkeydb_free)
/// @param value_len Output parameter for value length
/// @return Error code (LOWKEY_OK on success, LOWKEY_ERROR_KEY_NOT_FOUND if not found)
export fn lowkeydb_get(db_handle: ?*LowkeyDB, key: [*:0]const u8, value_out: *?[*:0]u8, value_len: *usize) c_int {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return LOWKEY_ERROR_INVALID_PARAM));
    const key_slice = std.mem.span(key);
    
    const maybe_value = wrapper.db.get(key_slice, c_allocator) catch |err| {
        return zigErrorToC(err);
    };
    
    if (maybe_value) |value| {
        // Allocate null-terminated C string
        const c_string = c_allocator.allocSentinel(u8, value.len, 0) catch {
            c_allocator.free(value);
            return LOWKEY_ERROR_MEMORY;
        };
        @memcpy(c_string[0..value.len], value);
        
        value_out.* = c_string.ptr;
        value_len.* = value.len;
        
        c_allocator.free(value);
        return LOWKEY_OK;
    } else {
        value_out.* = null;
        value_len.* = 0;
        return LOWKEY_ERROR_KEY_NOT_FOUND;
    }
}

/// Delete a key
/// @param db_handle Database handle
/// @param key Key string (null-terminated)
/// @return Error code (LOWKEY_OK on success, LOWKEY_ERROR_KEY_NOT_FOUND if not found)
export fn lowkeydb_delete(db_handle: ?*LowkeyDB, key: [*:0]const u8) c_int {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return LOWKEY_ERROR_INVALID_PARAM));
    const key_slice = std.mem.span(key);
    
    const deleted = wrapper.db.delete(key_slice) catch |err| {
        return zigErrorToC(err);
    };
    
    return if (deleted) LOWKEY_OK else LOWKEY_ERROR_KEY_NOT_FOUND;
}

/// Get the number of keys in the database
/// @param db_handle Database handle
/// @return Number of keys (0 on error)
export fn lowkeydb_key_count(db_handle: ?*LowkeyDB) u64 {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return 0));
    return wrapper.db.getKeyCount();
}

/// Begin a transaction
/// @param db_handle Database handle
/// @param isolation_level Isolation level (LOWKEY_READ_COMMITTED, etc.)
/// @param tx_id Output parameter for transaction ID
/// @return Error code (LOWKEY_OK on success)
export fn lowkeydb_begin_transaction(db_handle: ?*LowkeyDB, isolation_level: c_int, tx_id: *u64) c_int {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return LOWKEY_ERROR_INVALID_PARAM));
    
    const isolation = switch (isolation_level) {
        LOWKEY_READ_COMMITTED => Transaction.IsolationLevel.read_committed,
        LOWKEY_REPEATABLE_READ => Transaction.IsolationLevel.repeatable_read,
        LOWKEY_SERIALIZABLE => Transaction.IsolationLevel.serializable,
        else => return LOWKEY_ERROR_INVALID_PARAM,
    };
    
    const id = wrapper.db.beginTransaction(isolation) catch |err| {
        return zigErrorToC(err);
    };
    
    tx_id.* = id;
    return LOWKEY_OK;
}

/// Commit a transaction
/// @param db_handle Database handle
/// @param tx_id Transaction ID
/// @return Error code (LOWKEY_OK on success)
export fn lowkeydb_commit_transaction(db_handle: ?*LowkeyDB, tx_id: u64) c_int {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return LOWKEY_ERROR_INVALID_PARAM));
    
    wrapper.db.commitTransaction(tx_id) catch |err| {
        return zigErrorToC(err);
    };
    
    return LOWKEY_OK;
}

/// Rollback a transaction
/// @param db_handle Database handle
/// @param tx_id Transaction ID
/// @return Error code (LOWKEY_OK on success)
export fn lowkeydb_rollback_transaction(db_handle: ?*LowkeyDB, tx_id: u64) c_int {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return LOWKEY_ERROR_INVALID_PARAM));
    
    wrapper.db.rollbackTransaction(tx_id) catch |err| {
        return zigErrorToC(err);
    };
    
    return LOWKEY_OK;
}

/// Put a key-value pair within a transaction
/// @param db_handle Database handle
/// @param tx_id Transaction ID
/// @param key Key string (null-terminated)
/// @param value Value string (null-terminated)
/// @return Error code (LOWKEY_OK on success)
export fn lowkeydb_put_transaction(db_handle: ?*LowkeyDB, tx_id: u64, key: [*:0]const u8, value: [*:0]const u8) c_int {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return LOWKEY_ERROR_INVALID_PARAM));
    const key_slice = std.mem.span(key);
    const value_slice = std.mem.span(value);
    
    wrapper.db.putTransaction(tx_id, key_slice, value_slice) catch |err| {
        return zigErrorToC(err);
    };
    
    return LOWKEY_OK;
}

/// Get a value by key within a transaction
/// @param db_handle Database handle
/// @param tx_id Transaction ID
/// @param key Key string (null-terminated)
/// @param value_out Output parameter for value (caller must free with lowkeydb_free)
/// @param value_len Output parameter for value length
/// @return Error code (LOWKEY_OK on success)
export fn lowkeydb_get_transaction(db_handle: ?*LowkeyDB, tx_id: u64, key: [*:0]const u8, value_out: *?[*:0]u8, value_len: *usize) c_int {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return LOWKEY_ERROR_INVALID_PARAM));
    const key_slice = std.mem.span(key);
    
    const maybe_value = wrapper.db.getTransaction(tx_id, key_slice, c_allocator) catch |err| {
        return zigErrorToC(err);
    };
    
    if (maybe_value) |value| {
        // Allocate null-terminated C string
        const c_string = c_allocator.allocSentinel(u8, value.len, 0) catch {
            c_allocator.free(value);
            return LOWKEY_ERROR_MEMORY;
        };
        @memcpy(c_string[0..value.len], value);
        
        value_out.* = c_string.ptr;
        value_len.* = value.len;
        
        c_allocator.free(value);
        return LOWKEY_OK;
    } else {
        value_out.* = null;
        value_len.* = 0;
        return LOWKEY_ERROR_KEY_NOT_FOUND;
    }
}

/// Delete a key within a transaction
/// @param db_handle Database handle
/// @param tx_id Transaction ID
/// @param key Key string (null-terminated)
/// @return Error code (LOWKEY_OK on success)
export fn lowkeydb_delete_transaction(db_handle: ?*LowkeyDB, tx_id: u64, key: [*:0]const u8) c_int {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return LOWKEY_ERROR_INVALID_PARAM));
    const key_slice = std.mem.span(key);
    
    const deleted = wrapper.db.deleteTransaction(tx_id, key_slice) catch |err| {
        return zigErrorToC(err);
    };
    
    return if (deleted) LOWKEY_OK else LOWKEY_ERROR_KEY_NOT_FOUND;
}

/// Get buffer pool statistics
/// @param db_handle Database handle
/// @param stats Output parameter for statistics
/// @return Error code (LOWKEY_OK on success)
export fn lowkeydb_get_buffer_stats(db_handle: ?*LowkeyDB, stats: *LowkeyDBBufferStats) c_int {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return LOWKEY_ERROR_INVALID_PARAM));
    
    const buffer_stats = wrapper.db.getBufferPoolStats();
    
    stats.* = LowkeyDBBufferStats{
        .capacity = buffer_stats.capacity,
        .pages_in_buffer = buffer_stats.pages_in_buffer,
        .cache_hits = buffer_stats.cache_hits,
        .cache_misses = buffer_stats.cache_misses,
        .hit_ratio = buffer_stats.hit_ratio,
        .evictions = buffer_stats.evictions,
        .write_backs = buffer_stats.write_backs,
    };
    
    return LOWKEY_OK;
}

/// Get checkpoint statistics
/// @param db_handle Database handle
/// @param stats Output parameter for statistics
/// @return Error code (LOWKEY_OK on success)
export fn lowkeydb_get_checkpoint_stats(db_handle: ?*LowkeyDB, stats: *LowkeyDBCheckpointStats) c_int {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return LOWKEY_ERROR_INVALID_PARAM));
    
    const wal_stats = wrapper.db.getCheckpointStats();
    
    stats.* = LowkeyDBCheckpointStats{
        .checkpoints_performed = wal_stats.checkpoints_performed,
        .pages_written = wal_stats.pages_written,
        .wal_size = wal_stats.wal_size,
        .last_checkpoint_time = wal_stats.last_checkpoint_time,
    };
    
    return LOWKEY_OK;
}

/// Configure automatic checkpointing
/// @param db_handle Database handle
/// @param interval_ms Checkpoint interval in milliseconds
/// @param max_wal_size_mb Maximum WAL size in MB before checkpoint
/// @param max_archived_wals Maximum number of archived WAL files to keep
export fn lowkeydb_configure_checkpointing(db_handle: ?*LowkeyDB, interval_ms: u64, max_wal_size_mb: u32, max_archived_wals: u32) void {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return));
    wrapper.db.configureCheckpointing(interval_ms, max_wal_size_mb, max_archived_wals);
}

/// Start automatic checkpointing
/// @param db_handle Database handle
/// @return Error code (LOWKEY_OK on success)
export fn lowkeydb_start_auto_checkpoint(db_handle: ?*LowkeyDB) c_int {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return LOWKEY_ERROR_INVALID_PARAM));
    
    wrapper.db.startAutoCheckpoint() catch |err| {
        return zigErrorToC(err);
    };
    
    return LOWKEY_OK;
}

/// Stop automatic checkpointing
/// @param db_handle Database handle
export fn lowkeydb_stop_auto_checkpoint(db_handle: ?*LowkeyDB) void {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return));
    wrapper.db.stopAutoCheckpoint();
}

/// Perform manual checkpoint
/// @param db_handle Database handle
/// @return Error code (LOWKEY_OK on success)
export fn lowkeydb_checkpoint(db_handle: ?*LowkeyDB) c_int {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return LOWKEY_ERROR_INVALID_PARAM));
    
    wrapper.db.checkpoint() catch |err| {
        return zigErrorToC(err);
    };
    
    return LOWKEY_OK;
}

/// Flush WAL to disk
/// @param db_handle Database handle
/// @return Error code (LOWKEY_OK on success)
export fn lowkeydb_flush_wal(db_handle: ?*LowkeyDB) c_int {
    const wrapper: *DatabaseWrapper = @ptrCast(@alignCast(db_handle orelse return LOWKEY_ERROR_INVALID_PARAM));
    
    wrapper.db.flushWAL() catch |err| {
        return zigErrorToC(err);
    };
    
    return LOWKEY_OK;
}

/// Free memory allocated by LowkeyDB
/// @param ptr Pointer to free
export fn lowkeydb_free(ptr: ?*anyopaque) void {
    if (ptr) |p| {
        // Note: This is a simplified approach. In a real implementation,
        // you'd need to track allocation sizes or use a different strategy.
        const slice: [*:0]u8 = @ptrCast(p);
        const len = std.mem.len(slice);
        c_allocator.free(slice[0..len :0]);
    }
}

/// Get error message for error code
/// @param error_code Error code
/// @return Human-readable error message
export fn lowkeydb_error_message(error_code: c_int) [*:0]const u8 {
    return switch (error_code) {
        LOWKEY_OK => "Success",
        LOWKEY_ERROR_INVALID_PARAM => "Invalid parameter",
        LOWKEY_ERROR_MEMORY => "Memory allocation error",
        LOWKEY_ERROR_IO => "I/O error",
        LOWKEY_ERROR_KEY_NOT_FOUND => "Key not found",
        LOWKEY_ERROR_TRANSACTION_CONFLICT => "Transaction conflict",
        LOWKEY_ERROR_INVALID_TRANSACTION => "Invalid transaction",
        else => "Unknown error",
    };
}