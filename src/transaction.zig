const std = @import("std");
const DatabaseError = @import("error.zig").DatabaseError;
const Threading = @import("threading.zig").Threading;

/// Transaction system for LowkeyDB providing ACID properties
pub const Transaction = struct {
    /// Transaction states
    pub const State = enum {
        active,     // Transaction is active and can perform operations
        committed,  // Transaction has been committed
        aborted,    // Transaction has been aborted/rolled back
    };

    /// Transaction isolation levels
    pub const IsolationLevel = enum {
        read_uncommitted,   // Allows dirty reads
        read_committed,     // Prevents dirty reads
        repeatable_read,    // Prevents dirty and non-repeatable reads
        serializable,       // Full isolation
    };

    /// Operation types for undo logging
    pub const OperationType = enum {
        put,
        delete,
        update,
    };

    /// Undo log entry for rollback support
    pub const UndoLogEntry = struct {
        operation: OperationType,
        key: []u8,
        old_value: ?[]u8,  // null for new keys
        new_value: ?[]u8,  // null for deleted keys
        page_id: u32,
        
        pub fn deinit(self: *UndoLogEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.key);
            if (self.old_value) |old| allocator.free(old);
            if (self.new_value) |new| allocator.free(new);
        }
    };

    /// Transaction context
    const Self = @This();
    
    id: u64,
    state: State,
    isolation_level: IsolationLevel,
    undo_log: std.ArrayList(UndoLogEntry),
    held_locks: std.ArrayList(u32), // Page IDs with locks held
    allocator: std.mem.Allocator,
    start_time: i64,
    lock_timeout_ms: u32,
    
    pub fn init(allocator: std.mem.Allocator, id: u64, isolation_level: IsolationLevel) Self {
        return Self{
            .id = id,
            .state = .active,
            .isolation_level = isolation_level,
            .undo_log = std.ArrayList(UndoLogEntry).init(allocator),
            .held_locks = std.ArrayList(u32).init(allocator),
            .allocator = allocator,
            .start_time = std.time.milliTimestamp(),
            .lock_timeout_ms = 5000, // 5 second timeout
        };
    }
    
    pub fn deinit(self: *Self) void {
        // Clean up undo log entries
        for (self.undo_log.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.undo_log.deinit();
        self.held_locks.deinit();
    }
    /// Add an operation to the undo log
    pub fn logOperation(self: *Self, operation: OperationType, key: []const u8, old_value: ?[]const u8, new_value: ?[]const u8, page_id: u32) !void {
        if (self.state != .active) {
            return DatabaseError.TransactionNotActive;
        }
        
        // Deep copy all data for the undo log
        const key_copy = try self.allocator.dupe(u8, key);
        const old_value_copy = if (old_value) |old| try self.allocator.dupe(u8, old) else null;
        const new_value_copy = if (new_value) |new| try self.allocator.dupe(u8, new) else null;
        
        const entry = UndoLogEntry{
            .operation = operation,
            .key = key_copy,
            .old_value = old_value_copy,
            .new_value = new_value_copy,
            .page_id = page_id,
        };
        
        try self.undo_log.append(entry);
    }
    
    /// Check if transaction is active
    pub fn isActive(self: *const Self) bool {
        return self.state == .active;
    }
    /// Check if transaction has timed out
    pub fn hasTimedOut(self: *const Self) bool {
        const current_time = std.time.milliTimestamp();
        return (current_time - self.start_time) > self.lock_timeout_ms;
    }
    /// Mark transaction as committed
    pub fn markCommitted(self: *Self) void {
        self.state = .committed;
    }
    /// Mark transaction as aborted
    pub fn markAborted(self: *Self) void {
        self.state = .aborted;
    }
    /// Add a page lock to the transaction
    pub fn addLock(self: *Self, page_id: u32) !void {
        try self.held_locks.append(page_id);
    }
    /// Get all locks held by this transaction
    pub fn getHeldLocks(self: *const Self) []const u32 {
        return self.held_locks.items;
    }
};

/// Transaction Manager coordinates all transactions
pub const TransactionManager = struct {
    const Self = @This();
    
    active_transactions: std.HashMap(u64, *Transaction, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage),
    next_transaction_id: std.atomic.Value(u64),
    manager_mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    rollback_callback: ?*const fn(transaction: *Transaction, database: *anyopaque, allocator: std.mem.Allocator) DatabaseError!void,
    database_ref: ?*anyopaque,
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .active_transactions = std.HashMap(u64, *Transaction, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(allocator),
            .next_transaction_id = std.atomic.Value(u64).init(1),
            .manager_mutex = std.Thread.Mutex{},
            .allocator = allocator,
            .rollback_callback = null,
            .database_ref = null,
        };
    }
    /// Set the rollback callback function
    pub fn setRollbackCallback(self: *Self, callback: *const fn(transaction: *Transaction, database: *anyopaque, allocator: std.mem.Allocator) DatabaseError!void) void {
        self.rollback_callback = callback;
    }
    /// Set the database reference for rollback operations
    pub fn setDatabaseReference(self: *Self, database: *anyopaque) void {
        self.database_ref = database;
    }
    pub fn deinit(self: *Self) void {
        self.manager_mutex.lock();
        defer self.manager_mutex.unlock();
        
        // Clean up all active transactions
        var iter = self.active_transactions.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.active_transactions.deinit();
    }
    
    /// Begin a new transaction
    pub fn beginTransaction(self: *Self, isolation_level: Transaction.IsolationLevel) !*Transaction {
        const tx_id = self.next_transaction_id.fetchAdd(1, .acq_rel);
        
        const transaction = try self.allocator.create(Transaction);
        transaction.* = Transaction.init(self.allocator, tx_id, isolation_level);
        
        self.manager_mutex.lock();
        defer self.manager_mutex.unlock();
        
        try self.active_transactions.put(tx_id, transaction);
        return transaction;
    }
    /// Commit a transaction
    pub fn commitTransaction(self: *Self, tx_id: u64) !void {
        self.manager_mutex.lock();
        defer self.manager_mutex.unlock();
        
        if (self.active_transactions.get(tx_id)) |transaction| {
            if (transaction.state != .active) {
                return DatabaseError.TransactionNotActive;
            }
            
            // Mark as committed
            transaction.markCommitted();
            
            // Remove from active transactions
            _ = self.active_transactions.remove(tx_id);
            
            // Clean up transaction
            transaction.deinit();
            self.allocator.destroy(transaction);
        } else {
            return DatabaseError.TransactionNotFound;
        }
    }
    
    /// Abort a transaction and rollback changes
    pub fn abortTransaction(self: *Self, tx_id: u64) !void {
        self.manager_mutex.lock();
        defer self.manager_mutex.unlock();
        
        if (self.active_transactions.get(tx_id)) |transaction| {
            if (transaction.state != .active) {
                return DatabaseError.TransactionNotActive;
            }
            
            // Mark as aborted
            transaction.markAborted();
            
            // Execute rollback callback if available
            if (self.rollback_callback) |callback| {
                if (self.database_ref) |db_ref| {
                    try callback(transaction, db_ref, self.allocator);
                }
            }
            // Remove from active transactions
            _ = self.active_transactions.remove(tx_id);
            
            // Clean up transaction
            transaction.deinit();
            self.allocator.destroy(transaction);
        } else {
            return DatabaseError.TransactionNotFound;
        }
    }
    
    /// Get an active transaction by ID
    pub fn getTransaction(self: *Self, tx_id: u64) ?*Transaction {
        self.manager_mutex.lock();
        defer self.manager_mutex.unlock();
        
        return self.active_transactions.get(tx_id);
    }
    /// Check if a transaction exists and is active
    pub fn isTransactionActive(self: *Self, tx_id: u64) bool {
        if (self.getTransaction(tx_id)) |transaction| {
            return transaction.isActive();
        }
        return false;
    }
    /// Get count of active transactions
    pub fn getActiveTransactionCount(self: *Self) usize {
        self.manager_mutex.lock();
        defer self.manager_mutex.unlock();
        
        return self.active_transactions.count();
    }
    /// Clean up timed out transactions
    pub fn cleanupTimedOutTransactions(self: *Self) !void {
        self.manager_mutex.lock();
        defer self.manager_mutex.unlock();
        
        var to_remove = std.ArrayList(u64).init(self.allocator);
        defer to_remove.deinit();
        
        var iter = self.active_transactions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.hasTimedOut()) {
                try to_remove.append(entry.key_ptr.*);
            }
        }
        
        // Remove timed out transactions
        for (to_remove.items) |tx_id| {
            if (self.active_transactions.get(tx_id)) |transaction| {
                transaction.markAborted();
                transaction.deinit();
                self.allocator.destroy(transaction);
                _ = self.active_transactions.remove(tx_id);
            }
        }
    }
};

/// Read-write lock set for transaction isolation
pub const TransactionLockSet = struct {
    const Self = @This();
    
    read_locks: std.ArrayList(u32),
    write_locks: std.ArrayList(u32),
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .read_locks = std.ArrayList(u32).init(allocator),
            .write_locks = std.ArrayList(u32).init(allocator),
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *Self) void {
        self.read_locks.deinit();
        self.write_locks.deinit();
    }
    pub fn addReadLock(self: *Self, page_id: u32) !void {
        try self.read_locks.append(page_id);
    }
    pub fn addWriteLock(self: *Self, page_id: u32) !void {
        try self.write_locks.append(page_id);
    }
    pub fn hasReadLock(self: *const Self, page_id: u32) bool {
        for (self.read_locks.items) |lock_page_id| {
            if (lock_page_id == page_id) return true;
        }
        return false;
    }
    pub fn hasWriteLock(self: *const Self, page_id: u32) bool {
        for (self.write_locks.items) |lock_page_id| {
            if (lock_page_id == page_id) return true;
        }
        return false;
    }
};