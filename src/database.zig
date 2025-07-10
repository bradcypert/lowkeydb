const std = @import("std");
const Page = @import("storage/page.zig").Page;
const HeaderPage = @import("storage/page.zig").HeaderPage;
const PageHeader = @import("storage/page.zig").PageHeader;
const PageType = @import("storage/page.zig").PageType;
const PAGE_SIZE = @import("storage/page.zig").PAGE_SIZE;
const BufferPool = @import("storage/buffer.zig").BufferPool;
const BTreeLeafPage = @import("storage/btree.zig").BTreeLeafPage;
const BTreeInternalPage = @import("storage/btree.zig").BTreeInternalPage;
const KeyValue = @import("storage/btree.zig").KeyValue;
const SplitResult = @import("storage/btree.zig").SplitResult;
const DatabaseError = @import("error.zig").DatabaseError;
const Threading = @import("threading.zig").Threading;
const Transaction = @import("transaction.zig").Transaction;
const TransactionManager = @import("transaction.zig").TransactionManager;
const WAL = @import("wal.zig").WAL;

/// Path tracking structure for efficient parent finding during splits
const TreePath = struct {
    pages: [MAX_TREE_DEPTH]u32,
    depth: u32,
    
    const MAX_TREE_DEPTH = 20; // Reasonable limit for B+ tree depth
    
    pub fn init() TreePath {
        return TreePath{
            .pages = [_]u32{0} ** MAX_TREE_DEPTH,
            .depth = 0,
        };
    }
    
    pub fn push(self: *TreePath, page_id: u32) void {
        if (self.depth < MAX_TREE_DEPTH) {
            self.pages[self.depth] = page_id;
            self.depth += 1;
        }
    }
    
    pub fn getParent(self: *const TreePath) ?u32 {
        if (self.depth <= 1) return null; // Root or empty path
        return self.pages[self.depth - 2]; // Parent of current page
    }
    
    pub fn getCurrentPage(self: *const TreePath) ?u32 {
        if (self.depth == 0) return null;
        return self.pages[self.depth - 1];
    }
    
    pub fn popToParent(self: *TreePath) void {
        if (self.depth > 0) {
            self.depth -= 1;
        }
    }
};

pub const Database = struct {
    const Self = @This();
    
    file: std.fs.File,
    buffer_pool: BufferPool,
    header_page: *HeaderPage,
    allocator: std.mem.Allocator,
    is_open: std.atomic.Value(bool),
    db_lock: Threading.DatabaseLock,
    key_count: std.atomic.Value(u64),
    page_count: std.atomic.Value(u32),
    transaction_manager: TransactionManager,
    wal_manager: WAL.Manager,
    wal_path: []u8,
    is_recovery_mode: std.atomic.Value(bool),
    
    pub fn create(path: []const u8, allocator: std.mem.Allocator) DatabaseError!Self {
        // Create new database file
        const file = std.fs.cwd().createFile(path, .{ .read = true, .truncate = true }) catch |err| switch (err) {
            error.FileNotFound => return DatabaseError.FileNotFound,
            error.AccessDenied => return DatabaseError.FileAccessDenied,
            error.PathAlreadyExists => return DatabaseError.FileAlreadyExists,
            else => return DatabaseError.InternalError,
        };
        
        // Create WAL file path
        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{path});
        
        var db = Self{
            .file = file,
            .buffer_pool = BufferPool.init(allocator, 1024), // 1024 pages ~ 4MB
            .header_page = undefined,
            .allocator = allocator,
            .is_open = std.atomic.Value(bool).init(true),
            .db_lock = Threading.DatabaseLock.init(),
            .key_count = std.atomic.Value(u64).init(0),
            .page_count = std.atomic.Value(u32).init(1),
            .transaction_manager = TransactionManager.init(allocator),
            .wal_manager = try WAL.Manager.init(allocator, wal_path),
            .wal_path = wal_path,
            .is_recovery_mode = std.atomic.Value(bool).init(false),
        };
        
        // Set rollback callback (database reference will be set later)
        db.transaction_manager.setRollbackCallback(performRollback);
        
        // Set file in buffer pool for I/O
        db.buffer_pool.setFile(db.file);
        
        // Initialize header page
        try db.initializeHeader();
        
        return db;
    }
    
    pub fn open(path: []const u8, allocator: std.mem.Allocator) DatabaseError!Self {
        const file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => return DatabaseError.FileNotFound,
            error.AccessDenied => return DatabaseError.FileAccessDenied,
            else => return DatabaseError.InternalError,
        };
        
        // Create WAL file path
        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{path});
        
        var db = Self{
            .file = file,
            .buffer_pool = BufferPool.init(allocator, 1024),
            .header_page = undefined,
            .allocator = allocator,
            .is_open = std.atomic.Value(bool).init(true),
            .db_lock = Threading.DatabaseLock.init(),
            .key_count = std.atomic.Value(u64).init(0),
            .page_count = std.atomic.Value(u32).init(0),
            .transaction_manager = TransactionManager.init(allocator),
            .wal_manager = try WAL.Manager.init(allocator, wal_path),
            .wal_path = wal_path,
            .is_recovery_mode = std.atomic.Value(bool).init(false),
        };
        
        // Set rollback callback (database reference will be set later)
        db.transaction_manager.setRollbackCallback(performRollback);
        
        // Set file in buffer pool for I/O
        db.buffer_pool.setFile(db.file);
        
        // Load and validate header
        try db.loadHeader();
        
        // Perform WAL recovery
        db.wal_manager.recover(@ptrCast(&db)) catch |err| {
            std.debug.print("WAL recovery failed: {}, continuing without recovery\n", .{err});
        };
        
        return db;
    }
    
    pub fn close(self: *Self) void {
        if (!self.is_open.load(.acquire)) return;
        
        // Signal shutdown and wait for operations to complete
        self.db_lock.shutdown();
        
        // Mark as closed before any cleanup
        self.is_open.store(false, .release);
        
        // Flush all dirty pages while file is still open
        self.buffer_pool.flushAll() catch {};
        
        // Clean up buffer pool first (this will handle any remaining page operations)
        self.buffer_pool.deinit();
        
        // Clean up transaction manager
        self.transaction_manager.deinit();
        
        // Clean up WAL manager
        self.wal_manager.deinit();
        
        // Free WAL path
        self.allocator.free(self.wal_path);
        
        // Close file last, after all buffer operations are complete
        self.file.close();
    }
    
    /// Update the database reference for transaction rollback callbacks
    /// This must be called after the Database struct is moved to its final location
    pub fn updateDatabaseReference(self: *Self) void {
        self.transaction_manager.setDatabaseReference(@ptrCast(self));
    }
    
    pub fn put(self: *Self, key: []const u8, value: []const u8) DatabaseError!void {
        if (!self.db_lock.beginOperation()) return DatabaseError.DatabaseNotOpen;
        defer self.db_lock.endOperation();
        
        if (!self.is_open.load(.acquire)) return DatabaseError.DatabaseNotOpen;
        
        // Use fine-grained page-level locking for concurrent write operations
        // Each B+ tree operation will acquire appropriate page locks as needed
        
        // If no root page exists, create one with proper synchronization
        if (self.header_page.root_page == 0) {
            try self.createRootPageSafe();
        }
        
        // Insert into B+ tree
        try self.insertIntoBTree(key, value);
        
        // Update key count atomically
        _ = self.key_count.fetchAdd(1, .acq_rel);
        self.header_page.key_count = self.key_count.load(.acquire);
    }
    
    pub fn get(self: *Self, key: []const u8, allocator: std.mem.Allocator) DatabaseError!?[]u8 {
        if (!self.db_lock.beginOperation()) return DatabaseError.DatabaseNotOpen;
        defer self.db_lock.endOperation();
        
        if (!self.is_open.load(.acquire)) return DatabaseError.DatabaseNotOpen;
        
        if (self.header_page.root_page == 0) {
            return null; // Empty database
        }
        
        return try self.searchInBTree(key, allocator);
    }
    
    pub fn delete(self: *Self, key: []const u8) DatabaseError!bool {
        if (!self.db_lock.beginOperation()) return DatabaseError.DatabaseNotOpen;
        defer self.db_lock.endOperation();
        
        if (!self.is_open.load(.acquire)) return DatabaseError.DatabaseNotOpen;
        
        if (self.header_page.root_page == 0) {
            return false; // Empty database
        }
        
        const deleted = try self.deleteFromBTree(key);
        if (deleted) {
            _ = self.key_count.fetchSub(1, .acq_rel);
            self.header_page.key_count = self.key_count.load(.acquire);
        }
        
        return deleted;
    }
    
    pub fn sync(self: *Self) DatabaseError!void {
        if (!self.db_lock.beginOperation()) return DatabaseError.DatabaseNotOpen;
        defer self.db_lock.endOperation();
        
        if (!self.is_open.load(.acquire)) return DatabaseError.DatabaseNotOpen;
        
        try self.buffer_pool.flushAll();
        self.file.sync() catch |err| switch (err) {
            error.AccessDenied => return DatabaseError.FileAccessDenied,
            error.InputOutput => return DatabaseError.InternalError,
            else => return DatabaseError.InternalError,
        };
    }
    
    pub fn getKeyCount(self: *const Self) u64 {
        return self.key_count.load(.acquire);
    }
    
    /// Begin a new transaction
    pub fn beginTransaction(self: *Self, isolation_level: Transaction.IsolationLevel) DatabaseError!u64 {
        if (!self.is_open.load(.acquire)) return DatabaseError.DatabaseNotOpen;
        
        const transaction = try self.transaction_manager.beginTransaction(isolation_level);
        
        // Log transaction begin to WAL (skip if in recovery mode)
        if (!self.is_recovery_mode.load(.acquire)) {
            _ = try self.wal_manager.writeTransactionBegin(transaction.id);
        }
        
        return transaction.id;
    }
    
    /// Commit a transaction
    pub fn commitTransaction(self: *Self, tx_id: u64) DatabaseError!void {
        if (!self.is_open.load(.acquire)) return DatabaseError.DatabaseNotOpen;
        
        // Log transaction commit to WAL before committing (skip if in recovery mode)
        if (!self.is_recovery_mode.load(.acquire)) {
            _ = try self.wal_manager.writeTransactionCommit(tx_id);
        }
        
        try self.transaction_manager.commitTransaction(tx_id);
    }
    
    /// Rollback a transaction
    pub fn rollbackTransaction(self: *Self, tx_id: u64) DatabaseError!void {
        if (!self.is_open.load(.acquire)) return DatabaseError.DatabaseNotOpen;
        
        // Log transaction abort to WAL before rolling back (skip if in recovery mode)
        if (!self.is_recovery_mode.load(.acquire)) {
            _ = try self.wal_manager.writeTransactionAbort(tx_id);
        }
        
        // Perform the rollback while the database is still open
        try self.transaction_manager.abortTransaction(tx_id);
    }
    
    /// Get count of active transactions
    pub fn getActiveTransactionCount(self: *Self) usize {
        return self.transaction_manager.getActiveTransactionCount();
    }
    
    /// Perform manual WAL checkpoint
    pub fn checkpoint(self: *Self) DatabaseError!void {
        if (!self.is_open.load(.acquire)) return DatabaseError.DatabaseNotOpen;
        
        const active_count = @as(u32, @intCast(self.getActiveTransactionCount()));
        _ = try self.wal_manager.writeCheckpoint(active_count);
    }
    
    /// Start automatic WAL checkpointing
    pub fn startAutoCheckpoint(self: *Self) DatabaseError!void {
        if (!self.is_open.load(.acquire)) return DatabaseError.DatabaseNotOpen;
        
        try self.wal_manager.startCheckpointThread(@ptrCast(self));
    }
    
    /// Stop automatic WAL checkpointing
    pub fn stopAutoCheckpoint(self: *Self) void {
        self.wal_manager.stopCheckpointThread();
    }
    
    /// Configure WAL checkpointing parameters
    pub fn configureCheckpointing(self: *Self, interval_ms: u64, max_wal_size_mb: u32, max_archived: u32) void {
        self.wal_manager.configureCheckpointing(interval_ms, max_wal_size_mb, max_archived);
    }
    
    /// Get WAL checkpoint statistics
    pub fn getCheckpointStats(self: *Self) @TypeOf(self.wal_manager.getCheckpointStats()) {
        return self.wal_manager.getCheckpointStats();
    }
    
    /// Get buffer pool statistics
    pub fn getBufferPoolStats(self: *Self) @TypeOf(self.buffer_pool.getStatistics()) {
        return self.buffer_pool.getStatistics();
    }
    
    /// Print buffer pool statistics
    pub fn printBufferPoolStats(self: *Self) void {
        self.buffer_pool.printStatistics();
    }
    
    /// Print comprehensive database statistics
    pub fn printDatabaseStats(self: *Self) void {
        std.debug.print("\n=== LowkeyDB Database Statistics ===\n", .{});
        std.debug.print("Key Count: {}\n", .{self.key_count.load(.acquire)});
        std.debug.print("Page Count: {}\n", .{self.page_count.load(.acquire)});
        std.debug.print("Active Transactions: {}\n", .{self.getActiveTransactionCount()});
        std.debug.print("Database Status: {s}\n", .{if (self.is_open.load(.acquire)) "OPEN" else "CLOSED"});
        std.debug.print("=====================================\n\n", .{});
        
        // Print buffer pool stats
        self.buffer_pool.printStatistics();
        
        // Print WAL checkpoint stats
        self.wal_manager.printCheckpointStats();
    }
    
    /// Flush WAL to disk
    pub fn flushWAL(self: *Self) DatabaseError!void {
        if (!self.is_open.load(.acquire)) return DatabaseError.DatabaseNotOpen;
        
        try self.wal_manager.flush();
    }
    
    /// Transactional put operation
    pub fn putTransaction(self: *Self, tx_id: u64, key: []const u8, value: []const u8) DatabaseError!void {
        if (!self.is_open.load(.acquire)) return DatabaseError.DatabaseNotOpen;
        
        // Get the transaction
        const transaction = self.transaction_manager.getTransaction(tx_id) orelse return DatabaseError.TransactionNotFound;
        
        if (!transaction.isActive()) {
            return DatabaseError.TransactionNotActive;
        }
        
        // Check if key already exists (for undo logging)
        const existing_value = self.get(key, self.allocator) catch null;
        
        // Log the operation for rollback
        try transaction.logOperation(.put, key, existing_value, value, 0); // TODO: Get actual page_id
        
        // Log to WAL (skip if in recovery mode)
        if (!self.is_recovery_mode.load(.acquire)) {
            if (existing_value) |old_value| {
                _ = try self.wal_manager.writeUpdate(tx_id, 0, key, old_value, value);
                self.allocator.free(old_value);
            } else {
                _ = try self.wal_manager.writeInsert(tx_id, 0, key, value);
            }
        } else if (existing_value) |old_value| {
            self.allocator.free(old_value);
        }
        
        // Perform the actual put operation
        try self.put(key, value);
    }
    
    /// Transactional get operation
    pub fn getTransaction(self: *Self, tx_id: u64, key: []const u8, allocator: std.mem.Allocator) DatabaseError!?[]u8 {
        if (!self.is_open.load(.acquire)) return DatabaseError.DatabaseNotOpen;
        
        // Get the transaction
        const transaction = self.transaction_manager.getTransaction(tx_id) orelse return DatabaseError.TransactionNotFound;
        
        if (!transaction.isActive()) {
            return DatabaseError.TransactionNotActive;
        }
        
        // For now, just delegate to regular get operation
        // TODO: Implement isolation level specific logic
        return self.get(key, allocator);
    }
    
    /// Transactional delete operation
    pub fn deleteTransaction(self: *Self, tx_id: u64, key: []const u8) DatabaseError!bool {
        if (!self.is_open.load(.acquire)) return DatabaseError.DatabaseNotOpen;
        
        // Get the transaction
        const transaction = self.transaction_manager.getTransaction(tx_id) orelse return DatabaseError.TransactionNotFound;
        
        if (!transaction.isActive()) {
            return DatabaseError.TransactionNotActive;
        }
        
        // Get the existing value for undo logging
        const existing_value = self.get(key, self.allocator) catch null;
        
        if (existing_value) |old_value| {
            // Log the operation for rollback
            try transaction.logOperation(.delete, key, old_value, null, 0); // TODO: Get actual page_id
            
            // Log to WAL (skip if in recovery mode)
            if (!self.is_recovery_mode.load(.acquire)) {
                _ = try self.wal_manager.writeDelete(tx_id, 0, key, old_value);
            }
            
            // Clean up the temporary value
            self.allocator.free(old_value);
            
            // Perform the actual delete operation
            return self.delete(key);
        }
        
        return false; // Key doesn't exist
    }
    
    fn initializeHeader(self: *Self) DatabaseError!void {
        // Create and write header page
        var header = HeaderPage.init();
        
        _ = self.file.writeAll(std.mem.asBytes(&header)) catch |err| switch (err) {
            error.NoSpaceLeft => return DatabaseError.DiskFull,
            error.AccessDenied => return DatabaseError.FileAccessDenied,
            else => return DatabaseError.InternalError,
        };
        
        // Load header page into buffer pool
        const page = try self.buffer_pool.getPage(0);
        std.mem.copyForwards(u8, &page.data, std.mem.asBytes(&header));
        self.header_page = @ptrCast(@alignCast(&page.data));
        
        try self.buffer_pool.unpinPage(0, true);
    }
    
    fn loadHeader(self: *Self) DatabaseError!void {
        // Read header page
        var header_data: [PAGE_SIZE]u8 = undefined;
        _ = self.file.readAll(&header_data) catch |err| switch (err) {
            error.AccessDenied => return DatabaseError.FileAccessDenied,
            error.InputOutput => return DatabaseError.FileCorrupted,
            else => return DatabaseError.InternalError,
        };
        
        const header: *HeaderPage = @ptrCast(@alignCast(&header_data));
        try header.validate();
        
        // Load into buffer pool
        const page = try self.buffer_pool.getPage(0);
        std.mem.copyForwards(u8, &page.data, &header_data);
        self.header_page = @ptrCast(@alignCast(&page.data));
        
        try self.buffer_pool.unpinPage(0, false);
    }
    
    fn createRootPageSafe(self: *Self) DatabaseError!void {
        // Use database-level exclusive lock only for root page creation
        // This prevents race conditions when multiple threads try to create root simultaneously
        self.db_lock.lockExclusive();
        defer self.db_lock.unlockExclusive();
        
        // Double-check root page creation (another thread might have created it)
        if (self.header_page.root_page != 0) {
            return; // Root page already exists
        }
        
        // Allocate new page for root
        const page_id = try self.allocateNewPage();
        
        // Get page for exclusive access since it's a new page
        const page = try self.buffer_pool.getPageExclusive(page_id);
        
        // Initialize as leaf page
        _ = BTreeLeafPage.init(page);
        
        // Update header atomically
        self.header_page.root_page = page_id;
        
        // Unpin the page as dirty since we modified it
        self.buffer_pool.unpinPageExclusive(page_id, true);
    }
    
    fn createRootPage(self: *Self) DatabaseError!void {
        // Allocate new page for root
        const page_id = try self.allocateNewPage();
        
        // Get page for exclusive access since it's a new page
        const page = try self.buffer_pool.getPageExclusive(page_id);
        
        // Initialize as leaf page
        _ = BTreeLeafPage.init(page);
        
        // Update header
        self.header_page.root_page = page_id;
        
        // Unpin the page as dirty since we modified it
        self.buffer_pool.unpinPageExclusive(page_id, true);
    }
    
    fn allocateNewPage(self: *Self) DatabaseError!u32 {
        // Atomically increment page count
        const page_id = self.page_count.fetchAdd(1, .acq_rel);
        self.header_page.page_count = self.page_count.load(.acquire);
        
        // Extend file if needed
        const file_size = (self.page_count.load(.acquire) * PAGE_SIZE);
        self.file.setEndPos(file_size) catch |err| switch (err) {
            error.AccessDenied => return DatabaseError.FileAccessDenied,
            error.FileTooBig => return DatabaseError.DiskFull,
            else => return DatabaseError.InternalError,
        };
        
        return page_id;
    }
    
    /// Find the leaf page that should contain the given key
    fn findLeafPage(self: *Self, key: []const u8) DatabaseError!u32 {
        var path = TreePath.init();
        return self.findLeafPageWithPath(key, &path);
    }
    
    /// Find the leaf page and track the path for efficient parent finding
    fn findLeafPageWithPath(self: *Self, key: []const u8, path: *TreePath) DatabaseError!u32 {
        var current_page_id = self.header_page.root_page;
        
        while (true) {
            path.push(current_page_id);
            
            const page_ptr = try self.buffer_pool.getPageShared(current_page_id);
            defer self.buffer_pool.unpinPageShared(current_page_id);
            
            // Check if this is a leaf page
            const header: *PageHeader = @ptrCast(@alignCast(&page_ptr.data));
            if (header.page_type == .btree_leaf) {
                return current_page_id;
            }
            
            // This is an internal page, navigate to the correct child
            const internal_page: *BTreeInternalPage = @ptrCast(@alignCast(&page_ptr.data));
            current_page_id = internal_page.findChild(key);
        }
    }
    
    fn insertIntoBTree(self: *Self, key: []const u8, value: []const u8) DatabaseError!void {
        // Use path tracking for efficient multi-level B+ tree operations
        var path = TreePath.init();
        const leaf_page_id = try self.findLeafPageWithPath(key, &path);
        
        // Get the leaf page for exclusive access
        const leaf_page_ptr = try self.buffer_pool.getPageExclusive(leaf_page_id);
        const leaf_page: *BTreeLeafPage = @ptrCast(@alignCast(&leaf_page_ptr.data));
        
        // Check if the page needs to be split
        if (leaf_page.needsSplit(key, value)) {
            try self.splitLeafAndInsertWithPath(leaf_page_id, leaf_page, key, value, &path);
        } else {
            // Simple insertion - page has space
            try leaf_page.insertKeyValue(key, value);
            self.buffer_pool.unpinPageExclusive(leaf_page_id, true);
        }
    }
    
    /// Handle leaf page splitting and insertion using already-pinned page pointer
    fn splitLeafAndInsertWithPointer(self: *Self, leaf_page_id: u32, leaf_page: *BTreeLeafPage, key: []const u8, value: []const u8) DatabaseError!void {
        // Page is already pinned exclusively by caller, no need to pin again
        
        // Allocate a new page for the split
        const new_page_id = try self.allocateNewPage();
        const new_page_ptr = try self.buffer_pool.getPageExclusive(new_page_id);
        const new_leaf_page = BTreeLeafPage.init(new_page_ptr);
        
        // Perform the split
        var split_result = try leaf_page.split(self.allocator, new_leaf_page);
        split_result.new_page_id = new_page_id;
        
        // Update leaf linkage
        new_leaf_page.next_leaf = leaf_page.next_leaf;
        leaf_page.next_leaf = new_page_id;
        
        // Insert the new key-value pair into the appropriate page
        const cmp = std.mem.order(u8, key, split_result.promotion_key);
        if (cmp == .lt) {
            // Insert into original (left) page
            try leaf_page.insertKeyValue(key, value);
        } else {
            // Insert into new (right) page
            try new_leaf_page.insertKeyValue(key, value);
        }
        
        // Unpin the pages (mark as dirty)
        self.buffer_pool.unpinPageExclusive(leaf_page_id, true);
        self.buffer_pool.unpinPageExclusive(new_page_id, true);
        
        // Handle the promotion key - insert into parent or create new root
        try self.handlePromotion(split_result, leaf_page_id);
    }
    
    
    /// Handle leaf page splitting and insertion with path tracking (optimized)
    fn splitLeafAndInsertWithPath(self: *Self, leaf_page_id: u32, leaf_page: *BTreeLeafPage, key: []const u8, value: []const u8, path: *TreePath) DatabaseError!void {
        // Page is already pinned exclusively by caller, no need to re-pin
        
        // Allocate a new page for the split
        const new_page_id = try self.allocateNewPage();
        const new_page_ptr = try self.buffer_pool.getPageExclusive(new_page_id);
        const new_leaf_page = BTreeLeafPage.init(new_page_ptr);
        
        // Perform the split
        var split_result = try leaf_page.split(self.allocator, new_leaf_page);
        split_result.new_page_id = new_page_id;
        
        // Update leaf linkage
        new_leaf_page.next_leaf = leaf_page.next_leaf;
        leaf_page.next_leaf = new_page_id;
        
        // Insert the new key-value pair into the appropriate page
        const cmp = std.mem.order(u8, key, split_result.promotion_key);
        if (cmp == .lt) {
            // Insert into original (left) page
            try leaf_page.insertKeyValue(key, value);
        } else {
            // Insert into new (right) page
            try new_leaf_page.insertKeyValue(key, value);
        }
        
        // Unpin the pages (mark as dirty)
        self.buffer_pool.unpinPageExclusive(leaf_page_id, true);
        self.buffer_pool.unpinPageExclusive(new_page_id, true);
        
        // Handle the promotion key using path information (optimized)
        try self.handlePromotionWithPath(split_result, leaf_page_id, path);
    }
    
    /// Handle promotion of a key to parent level with path tracking (optimized)
    fn handlePromotionWithPath(self: *Self, split_result: SplitResult, left_page_id: u32, path: *TreePath) DatabaseError!void {
        // Get parent page ID from path instead of expensive search
        const parent_page_id = path.getParent();
        
        if (parent_page_id == null) {
            // No parent - we split the root, need to create new root
            try self.createNewRoot(split_result, left_page_id);
        } else {
            // We have a parent - try to insert into it
            try self.insertIntoInternalWithPath(parent_page_id.?, split_result, path);
        }
    }
    
    /// Handle promotion of a key to parent level (or create new root) - legacy version
    fn handlePromotion(self: *Self, split_result: SplitResult, left_page_id: u32) DatabaseError!void {
        // Check if we need to create a new root (root was a leaf page)
        const root_page_id = self.header_page.root_page;
        const root_page_ptr = try self.buffer_pool.getPageShared(root_page_id);
        const root_header: *PageHeader = @ptrCast(@alignCast(&root_page_ptr.data));
        const root_is_leaf = root_header.page_type == .btree_leaf;
        self.buffer_pool.unpinPageShared(root_page_id);
        
        if (root_is_leaf) {
            // Create new internal root
            try self.createNewRoot(split_result, left_page_id);
        } else {
            // Insert into existing internal page structure
            try self.insertIntoInternal(root_page_id, split_result);
        }
    }
    
    /// Create a new internal root when the original root (leaf) splits
    fn createNewRoot(self: *Self, split_result: SplitResult, left_page_id: u32) DatabaseError!void {
        // Allocate new page for the new root
        const new_root_id = try self.allocateNewPage();
        const new_root_ptr = try self.buffer_pool.getPageExclusive(new_root_id);
        const new_root = BTreeInternalPage.init(new_root_ptr);
        
        // Set up the new root with the promotion key
        new_root.children[0] = left_page_id;
        new_root.children[1] = split_result.new_page_id;
        
        // Insert the promotion key
        try new_root.insertKey(split_result.promotion_key, split_result.new_page_id);
        
        // Update header to point to new root
        self.header_page.root_page = new_root_id;
        
        // Unpin the new root page
        self.buffer_pool.unpinPageExclusive(new_root_id, true);
        
        // Free the promotion key
        self.allocator.free(split_result.promotion_key);
    }
    
    /// Insert a promotion key into an existing internal page with path tracking (optimized)
    fn insertIntoInternalWithPath(self: *Self, page_id: u32, split_result: SplitResult, path: *TreePath) DatabaseError!void {
        const page_ptr = try self.buffer_pool.getPageExclusive(page_id);
        const internal_page: *BTreeInternalPage = @ptrCast(@alignCast(&page_ptr.data));
        
        // Check if this internal page is full
        if (internal_page.isFull()) {
            // Need to split the internal page too
            self.buffer_pool.unpinPageExclusive(page_id, false);
            // Create a copy of the path and pop one level for recursive splitting
            var parent_path = path.*;  // Copy the path
            parent_path.popToParent(); // Move up one level for the parent operations
            try self.splitInternalAndInsertWithPath(page_id, split_result, &parent_path);
        } else {
            // Simple insertion into internal page
            try internal_page.insertKey(split_result.promotion_key, split_result.new_page_id);
            self.buffer_pool.unpinPageExclusive(page_id, true);
            
            // Free the promotion key
            self.allocator.free(split_result.promotion_key);
        }
    }
    
    /// Insert a promotion key into an existing internal page structure - legacy version
    fn insertIntoInternal(self: *Self, page_id: u32, split_result: SplitResult) DatabaseError!void {
        const page_ptr = try self.buffer_pool.getPageExclusive(page_id);
        const internal_page: *BTreeInternalPage = @ptrCast(@alignCast(&page_ptr.data));
        
        // Check if this internal page is full
        if (internal_page.isFull()) {
            // Need to split the internal page too
            self.buffer_pool.unpinPageExclusive(page_id, false);
            try self.splitInternalAndInsert(page_id, split_result);
        } else {
            // Simple insertion into internal page
            try internal_page.insertKey(split_result.promotion_key, split_result.new_page_id);
            self.buffer_pool.unpinPageExclusive(page_id, true);
            
            // Free the promotion key
            self.allocator.free(split_result.promotion_key);
        }
    }
    
    /// Handle internal page splitting with path tracking (optimized)
    fn splitInternalAndInsertWithPath(self: *Self, page_id: u32, split_result: SplitResult, path: *TreePath) DatabaseError!void {
        // Get the internal page that needs to be split
        const page_ptr = try self.buffer_pool.getPageExclusive(page_id);
        const internal_page: *BTreeInternalPage = @ptrCast(@alignCast(&page_ptr.data));
        
        // Allocate new page for the split
        const new_internal_page_id = try self.allocateNewPage();
        const new_page_ptr = try self.buffer_pool.getPageExclusive(new_internal_page_id);
        const new_internal_page = BTreeInternalPage.init(new_page_ptr);
        
        // Perform the split of the internal page
        var internal_split_result = try internal_page.split(self.allocator, new_internal_page);
        internal_split_result.new_page_id = new_internal_page_id;
        
        // Now we need to determine which page gets the incoming promotion key
        const cmp = std.mem.order(u8, split_result.promotion_key, internal_split_result.promotion_key);
        
        if (cmp == .lt) {
            // Insert into left (original) page
            try internal_page.insertKey(split_result.promotion_key, split_result.new_page_id);
        } else {
            // Insert into right (new) page  
            try new_internal_page.insertKey(split_result.promotion_key, split_result.new_page_id);
        }
        
        // Unpin both internal pages
        self.buffer_pool.unpinPageExclusive(page_id, true);
        self.buffer_pool.unpinPageExclusive(new_internal_page_id, true);
        
        // Free the original promotion key since we've used it
        self.allocator.free(split_result.promotion_key);
        
        // Now we need to promote the middle key from the internal split
        // Use path instead of expensive recursive search
        try self.handlePromotionWithPath(internal_split_result, page_id, path);
    }
    
    /// Handle internal page splitting (recursive case) - legacy version
    fn splitInternalAndInsert(self: *Self, page_id: u32, split_result: SplitResult) DatabaseError!void {
        // Get the internal page that needs to be split
        const page_ptr = try self.buffer_pool.getPageExclusive(page_id);
        const internal_page: *BTreeInternalPage = @ptrCast(@alignCast(&page_ptr.data));
        
        // First, try to insert the promotion key into this internal page
        // We need to insert it in the correct position, which might trigger a split
        
        // Allocate new page for the split
        const new_internal_page_id = try self.allocateNewPage();
        const new_page_ptr = try self.buffer_pool.getPageExclusive(new_internal_page_id);
        const new_internal_page = BTreeInternalPage.init(new_page_ptr);
        
        // Perform the split of the internal page
        var internal_split_result = try internal_page.split(self.allocator, new_internal_page);
        internal_split_result.new_page_id = new_internal_page_id;
        
        // Now we need to determine which page gets the incoming promotion key
        const cmp = std.mem.order(u8, split_result.promotion_key, internal_split_result.promotion_key);
        
        if (cmp == .lt) {
            // Insert into left (original) page
            try internal_page.insertKey(split_result.promotion_key, split_result.new_page_id);
        } else {
            // Insert into right (new) page  
            try new_internal_page.insertKey(split_result.promotion_key, split_result.new_page_id);
        }
        
        // Unpin both internal pages
        self.buffer_pool.unpinPageExclusive(page_id, true);
        self.buffer_pool.unpinPageExclusive(new_internal_page_id, true);
        
        // Free the original promotion key since we've used it
        self.allocator.free(split_result.promotion_key);
        
        // Now we need to promote the middle key from the internal split
        // This is the recursive part - we need to handle the new promotion
        try self.handlePromotionRecursive(internal_split_result, page_id);
    }
    
    /// Handle promotion recursively - works at any level of the tree
    fn handlePromotionRecursive(self: *Self, split_result: SplitResult, left_page_id: u32) DatabaseError!void {
        // Find the parent of the page that just split
        const parent_page_id = try self.findParentPage(left_page_id, split_result.promotion_key);
        
        if (parent_page_id == 0) {
            // No parent found - we split the root, need to create new root
            try self.createNewRoot(split_result, left_page_id);
        } else {
            // We have a parent - try to insert into it
            const parent_page_ptr = try self.buffer_pool.getPageExclusive(parent_page_id);
            const parent_internal_page: *BTreeInternalPage = @ptrCast(@alignCast(&parent_page_ptr.data));
            
            if (parent_internal_page.isFull()) {
                // Parent is full - need to split it too (recursive case)
                self.buffer_pool.unpinPageExclusive(parent_page_id, false);
                try self.splitInternalAndInsert(parent_page_id, split_result);
            } else {
                // Parent has space - simple insertion
                try parent_internal_page.insertKey(split_result.promotion_key, split_result.new_page_id);
                self.buffer_pool.unpinPageExclusive(parent_page_id, true);
                self.allocator.free(split_result.promotion_key);
            }
        }
    }
    
    /// Find the parent page of a given page by traversing from root
    /// Returns 0 if the page is the root (no parent)
    fn findParentPage(self: *Self, child_page_id: u32, key_hint: []const u8) DatabaseError!u32 {
        const root_page_id = self.header_page.root_page;
        
        // If the child is the root, it has no parent
        if (child_page_id == root_page_id) {
            return 0;
        }
        
        // Start traversal from root
        return self.findParentPageRecursive(root_page_id, child_page_id, key_hint);
    }
    
    /// Recursively search for the parent of a given page with depth limit
    fn findParentPageRecursive(self: *Self, current_page_id: u32, target_child_id: u32, key_hint: []const u8) DatabaseError!u32 {
        return self.findParentPageRecursiveWithDepth(current_page_id, target_child_id, key_hint, 0);
    }
    
    /// Internal recursive function with depth tracking to prevent infinite recursion
    fn findParentPageRecursiveWithDepth(self: *Self, current_page_id: u32, target_child_id: u32, key_hint: []const u8, depth: u32) DatabaseError!u32 {
        // Prevent infinite recursion - B+ trees shouldn't be deeper than ~10 levels for reasonable datasets
        if (depth > 20) {
            return DatabaseError.InternalError;
        }
        
        const page_ptr = try self.buffer_pool.getPageShared(current_page_id);
        defer self.buffer_pool.unpinPageShared(current_page_id);
        
        const header: *PageHeader = @ptrCast(@alignCast(&page_ptr.data));
        
        // If this is a leaf page, we've gone too far (shouldn't happen)
        if (header.page_type == .btree_leaf) {
            return 0;
        }
        
        const internal_page: *BTreeInternalPage = @ptrCast(@alignCast(&page_ptr.data));
        
        // Check if any of this page's children is our target
        for (0..internal_page.key_count + 1) |i| {
            if (internal_page.children[i] == target_child_id) {
                return current_page_id; // Found the parent!
            }
        }
        
        // Target child not found at this level, continue traversing
        // Use the key hint to decide which child to follow
        const next_child_id = internal_page.findChild(key_hint);
        
        // Prevent infinite loops by checking if we're going to same page
        if (next_child_id == current_page_id) {
            return DatabaseError.InternalError;
        }
        
        // Recursively search in the appropriate subtree
        return self.findParentPageRecursiveWithDepth(next_child_id, target_child_id, key_hint, depth + 1);
    }
    
    fn searchInBTree(self: *Self, key: []const u8, allocator: std.mem.Allocator) DatabaseError!?[]u8 {
        // Find the correct leaf page
        const leaf_page_id = try self.findLeafPage(key);
        
        // Get the leaf page for reading
        const page = try self.buffer_pool.getPageShared(leaf_page_id);
        defer self.buffer_pool.unpinPageShared(leaf_page_id);
        
        const leaf_page: *BTreeLeafPage = @ptrCast(@alignCast(&page.data));
        
        const index = leaf_page.findKey(key);
        if (index) |idx| {
            const value = leaf_page.getValue(idx);
            return try allocator.dupe(u8, value);
        }
        
        return null;
    }
    
    fn deleteFromBTree(self: *Self, key: []const u8) DatabaseError!bool {
        // Find the correct leaf page
        const leaf_page_id = try self.findLeafPage(key);
        
        // Get the leaf page for deletion
        const page = try self.buffer_pool.getPageExclusive(leaf_page_id);
        const leaf_page: *BTreeLeafPage = @ptrCast(@alignCast(&page.data));
        
        // Try to delete the key
        const deleted = leaf_page.deleteKey(key);
        if (!deleted) {
            self.buffer_pool.unpinPageExclusive(leaf_page_id, false);
            return false; // Key not found
        }
        
        // Check if page becomes underfull after deletion
        const is_root = (leaf_page_id == self.header_page.root_page);
        
        if (!is_root and leaf_page.isUnderfull()) {
            // Page is underfull, need to rebalance
            self.buffer_pool.unpinPageExclusive(leaf_page_id, true);
            try self.rebalanceAfterDeletion(leaf_page_id, key);
        } else if (is_root and leaf_page.isEmpty()) {
            // Root page is empty - need to handle this special case
            self.buffer_pool.unpinPageExclusive(leaf_page_id, true);
            try self.handleEmptyRoot();
        } else {
            // Page is fine, just unpin it
            self.buffer_pool.unpinPageExclusive(leaf_page_id, true);
        }
        
        return true;
    }
    
    /// Handle rebalancing after a deletion causes underflow
    fn rebalanceAfterDeletion(self: *Self, page_id: u32, deleted_key: []const u8) DatabaseError!void {
        // Find the parent and sibling pages
        const parent_page_id = try self.findParentPage(page_id, deleted_key);
        if (parent_page_id == 0) {
            // This shouldn't happen for non-root pages
            return DatabaseError.InternalError;
        }
        
        // Get parent page to find siblings
        const parent_page_ptr = try self.buffer_pool.getPageExclusive(parent_page_id);
        const parent_page: *BTreeInternalPage = @ptrCast(@alignCast(&parent_page_ptr.data));
        
        // Find the index of our page in parent's children
        var child_index: usize = 0;
        var found = false;
        for (0..parent_page.key_count + 1) |i| {
            if (parent_page.children[i] == page_id) {
                child_index = i;
                found = true;
                break;
            }
        }
        
        if (!found) {
            self.buffer_pool.unpinPageExclusive(parent_page_id, false);
            return DatabaseError.InternalError;
        }
        
        // Try to borrow from left sibling first
        if (child_index > 0) {
            const left_sibling_id = parent_page.children[child_index - 1];
            if (try self.tryBorrowFromLeftSibling(page_id, left_sibling_id, parent_page_id, child_index - 1)) {
                self.buffer_pool.unpinPageExclusive(parent_page_id, true);
                return;
            }
        }
        
        // Try to borrow from right sibling
        if (child_index < parent_page.key_count) {
            const right_sibling_id = parent_page.children[child_index + 1];
            if (try self.tryBorrowFromRightSibling(page_id, right_sibling_id, parent_page_id, child_index)) {
                self.buffer_pool.unpinPageExclusive(parent_page_id, true);
                return;
            }
        }
        
        // Borrowing failed, try merging with left sibling
        if (child_index > 0) {
            const left_sibling_id = parent_page.children[child_index - 1];
            if (try self.tryMergeWithLeftSibling(page_id, left_sibling_id, parent_page_id, child_index - 1)) {
                self.buffer_pool.unpinPageExclusive(parent_page_id, true);
                return;
            }
        }
        
        // Try merging with right sibling
        if (child_index < parent_page.key_count) {
            const right_sibling_id = parent_page.children[child_index + 1];
            if (try self.tryMergeWithRightSibling(page_id, right_sibling_id, parent_page_id, child_index)) {
                self.buffer_pool.unpinPageExclusive(parent_page_id, true);
                return;
            }
        }
        
        // If we get here, something went wrong
        self.buffer_pool.unpinPageExclusive(parent_page_id, false);
        return DatabaseError.InternalError;
    }
    
    /// Handle the case when root page becomes empty
    fn handleEmptyRoot(self: *Self) DatabaseError!void {
        _ = self; // TODO: Implement root handling
        // For now, just keep the empty root
        // TODO: In a multi-level tree, we should make a child the new root
    }
    
    /// Try to borrow a key from the left sibling
    fn tryBorrowFromLeftSibling(self: *Self, page_id: u32, left_sibling_id: u32, parent_page_id: u32, parent_key_index: usize) DatabaseError!bool {
        // Get both pages
        const page_ptr = try self.buffer_pool.getPageExclusive(page_id);
        const left_page_ptr = try self.buffer_pool.getPageExclusive(left_sibling_id);
        const parent_page_ptr = try self.buffer_pool.getPageExclusive(parent_page_id);
        
        const page: *BTreeLeafPage = @ptrCast(@alignCast(&page_ptr.data));
        const left_page: *BTreeLeafPage = @ptrCast(@alignCast(&left_page_ptr.data));
        const parent_page: *BTreeInternalPage = @ptrCast(@alignCast(&parent_page_ptr.data));
        
        // Check if left sibling can donate a key
        if (!left_page.canDonateKey()) {
            self.buffer_pool.unpinPageExclusive(page_id, false);
            self.buffer_pool.unpinPageExclusive(left_sibling_id, false);
            self.buffer_pool.unpinPageExclusive(parent_page_id, false);
            return false;
        }
        
        // Move the last key from left sibling to the beginning of this page
        const donor_index = left_page.key_count - 1;
        const donor_key = left_page.getKey(donor_index);
        const donor_value = left_page.getValue(donor_index);
        
        // Insert at beginning of current page (shift existing keys right)
        // For simplicity, we'll implement this as delete+insert
        // TODO: Optimize with direct slot manipulation
        
        // Copy the key and value to allocate new memory
        const key_copy = try self.allocator.dupe(u8, donor_key);
        defer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, donor_value);
        defer self.allocator.free(value_copy);
        
        // Remove from left sibling
        _ = left_page.deleteKey(donor_key);
        
        // Insert into current page
        try page.insertKeyValue(key_copy, value_copy);
        
        // Update parent key (the separator between left and current)
        const new_separator_key = page.getKey(0);
        const parent_key_entry = &parent_page.keys[parent_key_index];
        parent_key_entry.length = @intCast(new_separator_key.len);
        std.mem.copyForwards(u8, parent_key_entry.data[0..new_separator_key.len], new_separator_key);
        
        self.buffer_pool.unpinPageExclusive(page_id, true);
        self.buffer_pool.unpinPageExclusive(left_sibling_id, true);
        self.buffer_pool.unpinPageExclusive(parent_page_id, true);
        
        return true;
    }
    
    /// Try to borrow a key from the right sibling  
    fn tryBorrowFromRightSibling(self: *Self, page_id: u32, right_sibling_id: u32, parent_page_id: u32, parent_key_index: usize) DatabaseError!bool {
        // Get both pages
        const page_ptr = try self.buffer_pool.getPageExclusive(page_id);
        const right_page_ptr = try self.buffer_pool.getPageExclusive(right_sibling_id);
        const parent_page_ptr = try self.buffer_pool.getPageExclusive(parent_page_id);
        
        const page: *BTreeLeafPage = @ptrCast(@alignCast(&page_ptr.data));
        const right_page: *BTreeLeafPage = @ptrCast(@alignCast(&right_page_ptr.data));
        const parent_page: *BTreeInternalPage = @ptrCast(@alignCast(&parent_page_ptr.data));
        
        // Check if right sibling can donate a key
        if (!right_page.canDonateKey()) {
            self.buffer_pool.unpinPageExclusive(page_id, false);
            self.buffer_pool.unpinPageExclusive(right_sibling_id, false);
            self.buffer_pool.unpinPageExclusive(parent_page_id, false);
            return false;
        }
        
        // Move the first key from right sibling to the end of this page
        const donor_key = right_page.getKey(0);
        const donor_value = right_page.getValue(0);
        
        // Copy the key and value
        const key_copy = try self.allocator.dupe(u8, donor_key);
        defer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, donor_value);
        defer self.allocator.free(value_copy);
        
        // Remove from right sibling
        _ = right_page.deleteKey(donor_key);
        
        // Insert into current page
        try page.insertKeyValue(key_copy, value_copy);
        
        // Update parent key (the separator between current and right)
        const new_separator_key = right_page.getKey(0);
        const parent_key_entry = &parent_page.keys[parent_key_index];
        parent_key_entry.length = @intCast(new_separator_key.len);
        std.mem.copyForwards(u8, parent_key_entry.data[0..new_separator_key.len], new_separator_key);
        
        self.buffer_pool.unpinPageExclusive(page_id, true);
        self.buffer_pool.unpinPageExclusive(right_sibling_id, true);
        self.buffer_pool.unpinPageExclusive(parent_page_id, true);
        
        return true;
    }
    
    /// Try to merge with left sibling
    fn tryMergeWithLeftSibling(self: *Self, page_id: u32, left_sibling_id: u32, parent_page_id: u32, parent_key_index: usize) DatabaseError!bool {
        // Get both pages
        const page_ptr = try self.buffer_pool.getPageExclusive(page_id);
        const left_page_ptr = try self.buffer_pool.getPageExclusive(left_sibling_id);
        
        const page: *BTreeLeafPage = @ptrCast(@alignCast(&page_ptr.data));
        const left_page: *BTreeLeafPage = @ptrCast(@alignCast(&left_page_ptr.data));
        
        // Check if pages can be merged
        if (!left_page.canMergeWith(page)) {
            self.buffer_pool.unpinPageExclusive(page_id, false);
            self.buffer_pool.unpinPageExclusive(left_sibling_id, false);
            return false;
        }
        
        // Move all keys from current page to left sibling
        for (0..page.key_count) |i| {
            const key = page.getKey(i);
            const value = page.getValue(i);
            
            const key_copy = try self.allocator.dupe(u8, key);
            defer self.allocator.free(key_copy);
            const value_copy = try self.allocator.dupe(u8, value);
            defer self.allocator.free(value_copy);
            
            try left_page.insertKeyValue(key_copy, value_copy);
        }
        
        // Update leaf linkage
        left_page.next_leaf = page.next_leaf;
        
        // Mark pages appropriately
        self.buffer_pool.unpinPageExclusive(page_id, false); // Current page will be freed
        self.buffer_pool.unpinPageExclusive(left_sibling_id, true); // Left page was modified
        
        // Remove the separator key from parent and update child pointers
        try self.removeKeyFromInternalNode(parent_page_id, parent_key_index, page_id);
        
        return true;
    }
    
    /// Try to merge with right sibling
    fn tryMergeWithRightSibling(self: *Self, page_id: u32, right_sibling_id: u32, parent_page_id: u32, parent_key_index: usize) DatabaseError!bool {
        // Get both pages
        const page_ptr = try self.buffer_pool.getPageExclusive(page_id);
        const right_page_ptr = try self.buffer_pool.getPageExclusive(right_sibling_id);
        
        const page: *BTreeLeafPage = @ptrCast(@alignCast(&page_ptr.data));
        const right_page: *BTreeLeafPage = @ptrCast(@alignCast(&right_page_ptr.data));
        
        // Check if pages can be merged
        if (!page.canMergeWith(right_page)) {
            self.buffer_pool.unpinPageExclusive(page_id, false);
            self.buffer_pool.unpinPageExclusive(right_sibling_id, false);
            return false;
        }
        
        // Move all keys from right page to current page
        for (0..right_page.key_count) |i| {
            const key = right_page.getKey(i);
            const value = right_page.getValue(i);
            
            const key_copy = try self.allocator.dupe(u8, key);
            defer self.allocator.free(key_copy);
            const value_copy = try self.allocator.dupe(u8, value);
            defer self.allocator.free(value_copy);
            
            try page.insertKeyValue(key_copy, value_copy);
        }
        
        // Update leaf linkage
        page.next_leaf = right_page.next_leaf;
        
        // Mark pages appropriately
        self.buffer_pool.unpinPageExclusive(page_id, true); // Current page was modified
        self.buffer_pool.unpinPageExclusive(right_sibling_id, false); // Right page will be freed
        
        // Remove the separator key from parent and update child pointers
        try self.removeKeyFromInternalNode(parent_page_id, parent_key_index, right_sibling_id);
        
        return true;
    }
    
    /// Remove a key from an internal node and update child pointers
    fn removeKeyFromInternalNode(self: *Self, page_id: u32, key_index: usize, removed_child_id: u32) DatabaseError!void {
        const page_ptr = try self.buffer_pool.getPageExclusive(page_id);
        const internal_page: *BTreeInternalPage = @ptrCast(@alignCast(&page_ptr.data));
        
        // Shift keys left
        var i = key_index;
        while (i < internal_page.key_count - 1) {
            internal_page.keys[i] = internal_page.keys[i + 1];
            i += 1;
        }
        
        // Shift child pointers left (remove the specified child)
        i = 0;
        var write_index: usize = 0;
        while (i <= internal_page.key_count) {
            if (internal_page.children[i] != removed_child_id) {
                internal_page.children[write_index] = internal_page.children[i];
                write_index += 1;
            }
            i += 1;
        }
        
        internal_page.key_count -= 1;
        
        // Check if this internal page is now underfull
        const is_root = (page_id == self.header_page.root_page);
        
        if (!is_root and internal_page.isUnderfull()) {
            self.buffer_pool.unpinPageExclusive(page_id, true);
            // TODO: Implement internal page rebalancing (similar to leaf rebalancing)
            // For now, we accept that internal pages may be underfull to avoid complexity
        } else if (is_root and internal_page.isEmpty()) {
            // Root became empty - tree height reduction
            self.buffer_pool.unpinPageExclusive(page_id, true);
            try self.reduceTreeHeight();
        } else {
            self.buffer_pool.unpinPageExclusive(page_id, true);
        }
    }
    
    /// Reduce tree height when root becomes empty
    fn reduceTreeHeight(self: *Self) DatabaseError!void {
        const root_page_id = self.header_page.root_page;
        if (root_page_id == 0) return; // No root page
        
        const root_page_ptr = try self.buffer_pool.getPageExclusive(root_page_id);
        const root_internal: *BTreeInternalPage = @ptrCast(@alignCast(&root_page_ptr.data));
        
        // Root must be an empty internal page for height reduction
        if (root_internal.header.page_type != .btree_internal or !root_internal.isEmpty()) {
            self.buffer_pool.unpinPageExclusive(root_page_id, false);
            return;
        }
        
        // If root is empty, it should have exactly one child (the only remaining subtree)
        // The child becomes the new root
        const new_root_page_id = root_internal.children[0];
        
        // Update header to point to new root
        self.header_page.root_page = new_root_page_id;
        
        // If the new root is a leaf page with no keys, the tree becomes empty
        if (new_root_page_id == 0) {
            self.header_page.root_page = 0;
        }
        
        // Mark old root page as dirty (it will be freed/reused later)
        self.buffer_pool.unpinPageExclusive(root_page_id, true);
        
        // Decrement page count since we're effectively removing the old root
        _ = self.page_count.fetchSub(1, .monotonic);
    }
    
    /// Validate the B+ tree structure for debugging
    pub fn validateBTreeStructure(self: *Self) DatabaseError!void {
        const root_page_id = self.header_page.root_page;
        std.debug.print("Validating B+ tree structure starting from root page {}...\n", .{root_page_id});
        
        var total_keys: u32 = 0;
        try self.validateBTreePage(root_page_id, 0, &total_keys);
        
        std.debug.print("B+ tree validation complete. Total keys found: {}\n", .{total_keys});
    }
    
    /// Recursively validate a B+ tree page
    fn validateBTreePage(self: *Self, page_id: u32, depth: u32, total_keys: *u32) DatabaseError!void {
        if (depth > 20) { // Prevent infinite recursion
            return DatabaseError.InternalError;
        }
        
        const page_ptr = try self.buffer_pool.getPageShared(page_id);
        defer self.buffer_pool.unpinPageShared(page_id);
        
        const header: *PageHeader = @ptrCast(@alignCast(&page_ptr.data));
        
        switch (header.page_type) {
            .btree_leaf => {
                const leaf_page: *BTreeLeafPage = @ptrCast(@alignCast(&page_ptr.data));
                // Create indentation string dynamically
                var indent_buffer: [32]u8 = undefined;
                const indent_len = @min(depth * 2, 32);
                @memset(indent_buffer[0..indent_len], ' ');
                const indent = indent_buffer[0..indent_len];
                std.debug.print("{s}Leaf page {}: {} keys\n", .{ indent, page_id, leaf_page.key_count });
                total_keys.* += leaf_page.key_count;
            },
            .btree_internal => {
                const internal_page: *BTreeInternalPage = @ptrCast(@alignCast(&page_ptr.data));
                // Create indentation string dynamically
                var indent_buffer: [32]u8 = undefined;
                const indent_len = @min(depth * 2, 32);
                @memset(indent_buffer[0..indent_len], ' ');
                const indent = indent_buffer[0..indent_len];
                std.debug.print("{s}Internal page {}: {} keys, {} children\n", .{ indent, page_id, internal_page.key_count, internal_page.key_count + 1 });
                
                // Validate all children
                for (0..internal_page.key_count + 1) |i| {
                    const child_id = internal_page.children[i];
                    if (child_id != 0) {
                        try self.validateBTreePage(child_id, depth + 1, total_keys);
                    }
                }
            },
            else => {
                // Create indentation string dynamically
                var indent_buffer: [32]u8 = undefined;
                const indent_len = @min(depth * 2, 32);
                @memset(indent_buffer[0..indent_len], ' ');
                const indent = indent_buffer[0..indent_len];
                std.debug.print("{s}ERROR: Invalid page type at page {}\n", .{ indent, page_id });
                return DatabaseError.CorruptedData;
            },
        }
    }
};

/// Rollback callback function for transaction manager
fn performRollback(transaction: *Transaction, database: *anyopaque, allocator: std.mem.Allocator) DatabaseError!void {
    // Cast the database pointer back to the correct type
    const db: *Database = @ptrCast(@alignCast(database));
    
    // Check if database is still open
    if (!db.is_open.load(.acquire)) {
        std.debug.print("Database closed during rollback for transaction {}\n", .{transaction.id});
        return;
    }
    
    std.debug.print("Starting rollback for transaction {} with {} operations\n", .{transaction.id, transaction.undo_log.items.len});
    
    // Process undo log in reverse order (LIFO) to undo operations
    var i = transaction.undo_log.items.len;
    while (i > 0) {
        i -= 1;
        const entry = &transaction.undo_log.items[i];
        
        switch (entry.operation) {
            .put => {
                // For put operations, we need to either:
                // 1. Delete the key if it was a new insertion (old_value == null)
                // 2. Restore the old value if it was an update
                if (entry.old_value == null) {
                    // This was a new insertion, delete the key
                    std.debug.print("Rollback: Deleting inserted key '{s}'\n", .{entry.key});
                    const deleted = db.deleteFromBTree(entry.key) catch |err| {
                        std.debug.print("Rollback error: Failed to delete key '{s}': {}\n", .{entry.key, err});
                        return err;
                    };
                    if (deleted) {
                        // Decrement key count since we deleted a key
                        _ = db.key_count.fetchSub(1, .acq_rel);
                        db.header_page.key_count = db.key_count.load(.acquire);
                    }
                } else {
                    // This was an update, restore old value
                    std.debug.print("Rollback: Restoring key '{s}' to old value\n", .{entry.key});
                    db.insertIntoBTree(entry.key, entry.old_value.?) catch |err| {
                        std.debug.print("Rollback error: Failed to restore key '{s}': {}\n", .{entry.key, err});
                        return err;
                    };
                }
            },
            .delete => {
                // For delete operations, restore the deleted key-value pair
                if (entry.old_value) |old_value| {
                    std.debug.print("Rollback: Restoring deleted key '{s}'\n", .{entry.key});
                    db.insertIntoBTree(entry.key, old_value) catch |err| {
                        std.debug.print("Rollback error: Failed to restore deleted key '{s}': {}\n", .{entry.key, err});
                        return err;
                    };
                    // Increment key count since we restored a key
                    _ = db.key_count.fetchAdd(1, .acq_rel);
                    db.header_page.key_count = db.key_count.load(.acquire);
                }
            },
            .update => {
                // For update operations, restore the old value
                if (entry.old_value) |old_value| {
                    std.debug.print("Rollback: Restoring updated key '{s}' to old value\n", .{entry.key});
                    db.insertIntoBTree(entry.key, old_value) catch |err| {
                        std.debug.print("Rollback error: Failed to restore updated key '{s}': {}\n", .{entry.key, err});
                        return err;
                    };
                }
            },
        }
    }
    
    // Suppress unused parameter warning
    _ = allocator;
    
    std.debug.print("Transaction {} successfully rolled back with {} operations\n", .{transaction.id, transaction.undo_log.items.len});
}