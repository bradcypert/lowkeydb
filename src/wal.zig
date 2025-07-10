const std = @import("std");
const DatabaseError = @import("error.zig").DatabaseError;
const Threading = @import("threading.zig").Threading;

/// Write-Ahead Log system for LowkeyDB providing durability and crash recovery
pub const WAL = struct {
    /// WAL record types for different database operations
    pub const RecordType = enum(u8) {
        transaction_begin = 1,
        transaction_commit = 2,
        transaction_abort = 3,
        insert = 4,
        update = 5,
        delete = 6,
        checkpoint = 7,
        
        pub fn toString(self: RecordType) []const u8 {
            return switch (self) {
                .transaction_begin => "BEGIN",
                .transaction_commit => "COMMIT",
                .transaction_abort => "ABORT",
                .insert => "INSERT",
                .update => "UPDATE",
                .delete => "DELETE",
                .checkpoint => "CHECKPOINT",
            };
        }
    };
    
    /// WAL record header structure
    pub const RecordHeader = packed struct {
        record_type: RecordType,
        transaction_id: u64,
        timestamp: u64,
        data_length: u32,
        checksum: u32,
        
        pub const SIZE = @sizeOf(RecordHeader);
        
        pub fn calculateChecksum(self: *const RecordHeader, data: []const u8) u32 {
            var hasher = std.hash.Crc32.init();
            hasher.update(std.mem.asBytes(self)[0..RecordHeader.SIZE - 4]); // Exclude checksum field
            hasher.update(data);
            return hasher.final();
        }
        
        pub fn isValid(self: *const RecordHeader, data: []const u8) bool {
            return self.checksum == self.calculateChecksum(data);
        }
    };
    
    /// WAL record data for insert/update operations
    pub const InsertUpdateRecord = struct {
        page_id: u32,
        key_length: u32,
        value_length: u32,
        // Followed by: key_data, value_data
        
        pub const SIZE = @sizeOf(InsertUpdateRecord);
        
        pub fn serialize(self: *const InsertUpdateRecord, writer: anytype, key: []const u8, value: []const u8) !void {
            try writer.writeAll(std.mem.asBytes(self));
            try writer.writeAll(key);
            try writer.writeAll(value);
        }
        
        pub fn deserialize(reader: anytype, allocator: std.mem.Allocator) !struct { record: InsertUpdateRecord, key: []u8, value: []u8 } {
            var record: InsertUpdateRecord = undefined;
            _ = try reader.readAll(std.mem.asBytes(&record));
            const key = try allocator.alloc(u8, record.key_length);
            const value = try allocator.alloc(u8, record.value_length);
            
            try reader.readNoEof(key);
            try reader.readNoEof(value);
            
            return .{ .record = record, .key = key, .value = value };
        }
    };
    
    /// WAL record data for update operations
    pub const UpdateRecord = struct {
        page_id: u32,
        key_length: u32,
        old_value_length: u32,
        new_value_length: u32,
        // Followed by: key_data, old_value_data, new_value_data
        
        pub const SIZE = @sizeOf(UpdateRecord);
    };
    
    /// WAL record data for delete operations
    pub const DeleteRecord = struct {
        page_id: u32,
        key_length: u32,
        value_length: u32, // For rollback purposes
        // Followed by: key_data, old_value_data
        
        pub const SIZE = @sizeOf(DeleteRecord);
        
        pub fn serialize(self: *const DeleteRecord, writer: anytype, key: []const u8, old_value: []const u8) !void {
            try writer.writeAll(std.mem.asBytes(self));
            try writer.writeAll(key);
            try writer.writeAll(old_value);
        }
        
        pub fn deserialize(reader: anytype, allocator: std.mem.Allocator) !struct { record: DeleteRecord, key: []u8, old_value: []u8 } {
            var record: DeleteRecord = undefined;
            _ = try reader.readAll(std.mem.asBytes(&record));
            const key = try allocator.alloc(u8, record.key_length);
            const old_value = try allocator.alloc(u8, record.value_length);
            
            try reader.readNoEof(key);
            try reader.readNoEof(old_value);
            
            return .{ .record = record, .key = key, .old_value = old_value };
        }
    };
    
    /// WAL checkpoint record
    pub const CheckpointRecord = struct {
        last_checkpoint_lsn: u64,
        active_transactions: u32,
        
        pub const SIZE = @sizeOf(CheckpointRecord);
    };
    
    /// Log Sequence Number for ordering WAL records
    pub const LSN = u64;
    
    /// WAL Manager handles log file operations and recovery
    pub const Manager = struct {
        const Self = @This();
        
        log_file: std.fs.File,
        log_path: []const u8,
        current_lsn: std.atomic.Value(LSN),
        last_checkpoint_lsn: std.atomic.Value(LSN),
        write_buffer: std.ArrayList(u8),
        buffer_mutex: std.Thread.Mutex,
        allocator: std.mem.Allocator,
        is_recovery_mode: bool,
        
        // Enhanced checkpointing
        checkpoint_thread: ?std.Thread,
        should_stop_checkpoint_thread: std.atomic.Value(bool),
        checkpoint_interval_ms: u64,
        max_wal_size_bytes: u64,
        checkpoint_mutex: std.Thread.Mutex,
        
        // Log rotation
        archived_logs: std.ArrayList([]const u8),
        max_archived_logs: u32,
        
        pub fn init(allocator: std.mem.Allocator, log_path: []const u8) !Self {
            const log_file = std.fs.cwd().createFile(log_path, .{ .read = true, .truncate = false }) catch |err| switch (err) {
                error.FileNotFound => return DatabaseError.FileNotFound,
                error.AccessDenied => return DatabaseError.FileAccessDenied,
                else => return DatabaseError.InternalError,
            };
            
            return Self{
                .log_file = log_file,
                .log_path = log_path,
                .current_lsn = std.atomic.Value(LSN).init(1),
                .last_checkpoint_lsn = std.atomic.Value(LSN).init(0),
                .write_buffer = std.ArrayList(u8).init(allocator),
                .buffer_mutex = std.Thread.Mutex{},
                .allocator = allocator,
                .is_recovery_mode = false,
                .checkpoint_thread = null,
                .should_stop_checkpoint_thread = std.atomic.Value(bool).init(false),
                .checkpoint_interval_ms = 30000, // 30 seconds default
                .max_wal_size_bytes = 50 * 1024 * 1024, // 50MB default
                .checkpoint_mutex = std.Thread.Mutex{},
                .archived_logs = std.ArrayList([]const u8).init(allocator),
                .max_archived_logs = 10,
            };
        }
        
        pub fn deinit(self: *Self) void {
            // Stop checkpoint thread if running
            self.stopCheckpointThread();
            
            self.flush() catch {};
            self.log_file.close();
            self.write_buffer.deinit();
            
            // Clean up archived log paths
            for (self.archived_logs.items) |path| {
                self.allocator.free(path);
            }
            self.archived_logs.deinit();
        }
        
        /// Generate next LSN atomically
        fn nextLSN(self: *Self) LSN {
            return self.current_lsn.fetchAdd(1, .acq_rel);
        }
        
        /// Write a WAL record to the log
        pub fn writeRecord(self: *Self, record_type: RecordType, transaction_id: u64, data: []const u8) !LSN {
            const lsn = self.nextLSN();
            const timestamp = @as(u64, @intCast(std.time.milliTimestamp()));
            
            var header = RecordHeader{
                .record_type = record_type,
                .transaction_id = transaction_id,
                .timestamp = timestamp,
                .data_length = @as(u32, @intCast(data.len)),
                .checksum = 0, // Will be calculated
            };
            
            header.checksum = header.calculateChecksum(data);
            
            self.buffer_mutex.lock();
            defer self.buffer_mutex.unlock();
            
            // Write header
            try self.write_buffer.writer().writeAll(std.mem.asBytes(&header));
            
            // Write data
            try self.write_buffer.writer().writeAll(data);
            
            // For critical operations, flush immediately
            if (record_type == .transaction_commit or record_type == .transaction_abort) {
                try self.flushUnlocked();
            }
            
            return lsn;
        }
        
        /// Write transaction begin record
        pub fn writeTransactionBegin(self: *Self, transaction_id: u64) !LSN {
            return self.writeRecord(.transaction_begin, transaction_id, &[_]u8{});
        }
        
        /// Write transaction commit record
        pub fn writeTransactionCommit(self: *Self, transaction_id: u64) !LSN {
            return self.writeRecord(.transaction_commit, transaction_id, &[_]u8{});
        }
        
        /// Write transaction abort record
        pub fn writeTransactionAbort(self: *Self, transaction_id: u64) !LSN {
            return self.writeRecord(.transaction_abort, transaction_id, &[_]u8{});
        }
        
        /// Write insert record
        pub fn writeInsert(self: *Self, transaction_id: u64, page_id: u32, key: []const u8, value: []const u8) !LSN {
            var buffer = std.ArrayList(u8).init(self.allocator);
            defer buffer.deinit();
            
            const record = InsertUpdateRecord{
                .page_id = page_id,
                .key_length = @as(u32, @intCast(key.len)),
                .value_length = @as(u32, @intCast(value.len)),
            };
            
            try record.serialize(buffer.writer(), key, value);
            return self.writeRecord(.insert, transaction_id, buffer.items);
        }
        
        /// Write update record
        pub fn writeUpdate(self: *Self, transaction_id: u64, page_id: u32, key: []const u8, old_value: []const u8, new_value: []const u8) !LSN {
            var buffer = std.ArrayList(u8).init(self.allocator);
            defer buffer.deinit();
            
            // For updates, we store both old and new values with separate lengths
            const record = UpdateRecord{
                .page_id = page_id,
                .key_length = @as(u32, @intCast(key.len)),
                .old_value_length = @as(u32, @intCast(old_value.len)),
                .new_value_length = @as(u32, @intCast(new_value.len)),
            };
            
            try buffer.writer().writeAll(std.mem.asBytes(&record));
            try buffer.writer().writeAll(key);
            try buffer.writer().writeAll(old_value);
            try buffer.writer().writeAll(new_value);
            
            return self.writeRecord(.update, transaction_id, buffer.items);
        }
        
        /// Write delete record
        pub fn writeDelete(self: *Self, transaction_id: u64, page_id: u32, key: []const u8, old_value: []const u8) !LSN {
            var buffer = std.ArrayList(u8).init(self.allocator);
            defer buffer.deinit();
            
            const record = DeleteRecord{
                .page_id = page_id,
                .key_length = @as(u32, @intCast(key.len)),
                .value_length = @as(u32, @intCast(old_value.len)),
            };
            
            try record.serialize(buffer.writer(), key, old_value);
            return self.writeRecord(.delete, transaction_id, buffer.items);
        }
        
        /// Write checkpoint record
        pub fn writeCheckpoint(self: *Self, active_transactions: u32) !LSN {
            const last_checkpoint_lsn = self.last_checkpoint_lsn.load(.acquire);
            
            const record = CheckpointRecord{
                .last_checkpoint_lsn = last_checkpoint_lsn,
                .active_transactions = active_transactions,
            };
            
            var buffer = std.ArrayList(u8).init(self.allocator);
            defer buffer.deinit();
            
            try buffer.writer().writeAll(std.mem.asBytes(&record));
            const lsn = try self.writeRecord(.checkpoint, 0, buffer.items);
            
            self.last_checkpoint_lsn.store(lsn, .release);
            return lsn;
        }
        
        /// Flush WAL buffer to disk
        pub fn flush(self: *Self) !void {
            self.buffer_mutex.lock();
            defer self.buffer_mutex.unlock();
            
            try self.flushUnlocked();
        }
        
        /// Internal flush without locking
        fn flushUnlocked(self: *Self) !void {
            if (self.write_buffer.items.len > 0) {
                try self.log_file.writeAll(self.write_buffer.items);
                try self.log_file.sync();
                self.write_buffer.clearRetainingCapacity();
            }
        }
        
        /// Get current LSN
        pub fn getCurrentLSN(self: *const Self) LSN {
            return self.current_lsn.load(.acquire);
        }
        
        /// Get last checkpoint LSN
        pub fn getLastCheckpointLSN(self: *const Self) LSN {
            return self.last_checkpoint_lsn.load(.acquire);
        }
        
        /// WAL Recovery iterator for replaying log records
        pub const RecoveryIterator = struct {
            manager: *Manager,
            file_reader: std.fs.File.Reader,
            current_position: u64,
            
            pub fn init(manager: *Manager) !RecoveryIterator {
                try manager.log_file.seekTo(0);
                
                return RecoveryIterator{
                    .manager = manager,
                    .file_reader = manager.log_file.reader(),
                    .current_position = 0,
                };
            }
            
            pub fn next(self: *RecoveryIterator) !?struct { header: RecordHeader, data: []u8 } {
                var header: RecordHeader = undefined;
                const header_bytes_read = self.file_reader.readAll(std.mem.asBytes(&header)) catch |err| switch (err) {
                    else => return err,
                };
                
                if (header_bytes_read == 0) {
                    return null; // End of file
                }
                
                if (header_bytes_read != @sizeOf(RecordHeader)) {
                    return DatabaseError.CorruptedData;
                }
                
                const data = try self.manager.allocator.alloc(u8, header.data_length);
                try self.file_reader.readNoEof(data);
                
                // Validate checksum
                if (!header.isValid(data)) {
                    self.manager.allocator.free(data);
                    return DatabaseError.CorruptedData;
                }
                
                return .{ .header = header, .data = data };
            }
            
            pub fn deinit(self: *RecoveryIterator) void {
                _ = self;
                // Iterator cleanup if needed
            }
        };
        
        /// Perform WAL recovery
        pub fn recover(self: *Self, database: *anyopaque) !void {
            self.is_recovery_mode = true;
            defer self.is_recovery_mode = false;
            
            std.debug.print("Starting WAL recovery...\n", .{});
            
            var iterator = try RecoveryIterator.init(self);
            defer iterator.deinit();
            
            var records_replayed: u32 = 0;
            var committed_transactions = std.HashMap(u64, void, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(self.allocator);
            defer committed_transactions.deinit();
            
            var aborted_transactions = std.HashMap(u64, void, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(self.allocator);
            defer aborted_transactions.deinit();
            
            // First pass: Identify committed and aborted transactions
            std.debug.print("First pass: Identifying transaction outcomes...\n", .{});
            var first_pass_iterator = try RecoveryIterator.init(self);
            defer first_pass_iterator.deinit();
            
            while (try first_pass_iterator.next()) |entry| {
                defer self.allocator.free(entry.data);
                
                switch (entry.header.record_type) {
                    .transaction_commit => {
                        try committed_transactions.put(entry.header.transaction_id, {});
                    },
                    .transaction_abort => {
                        try aborted_transactions.put(entry.header.transaction_id, {});
                    },
                    else => {},
                }
            }
            
            std.debug.print("Found {} committed transactions, {} aborted transactions\n", .{ committed_transactions.count(), aborted_transactions.count() });
            
            // Second pass: Replay operations for committed transactions only
            std.debug.print("Second pass: Replaying committed operations...\n", .{});
            
            while (try iterator.next()) |entry| {
                defer self.allocator.free(entry.data);
                
                std.debug.print("Processing WAL record: {s} for transaction {}\n", .{ entry.header.record_type.toString(), entry.header.transaction_id });
                
                switch (entry.header.record_type) {
                    .transaction_begin, .transaction_commit, .transaction_abort => {
                        // Skip transaction control records in replay
                        std.debug.print("  -> Skipping transaction control record\n", .{});
                    },
                    .insert => {
                        // Only replay if transaction was committed
                        if (committed_transactions.contains(entry.header.transaction_id)) {
                            try self.replayInsertOperation(database, entry.data);
                            std.debug.print("  -> Replayed INSERT operation\n", .{});
                        } else {
                            std.debug.print("  -> Skipped INSERT (transaction not committed)\n", .{});
                        }
                    },
                    .update => {
                        // Only replay if transaction was committed
                        if (committed_transactions.contains(entry.header.transaction_id)) {
                            try self.replayUpdateOperation(database, entry.data);
                            std.debug.print("  -> Replayed UPDATE operation\n", .{});
                        } else {
                            std.debug.print("  -> Skipped UPDATE (transaction not committed)\n", .{});
                        }
                    },
                    .delete => {
                        // Only replay if transaction was committed
                        if (committed_transactions.contains(entry.header.transaction_id)) {
                            try self.replayDeleteOperation(database, entry.data);
                            std.debug.print("  -> Replayed DELETE operation\n", .{});
                        } else {
                            std.debug.print("  -> Skipped DELETE (transaction not committed)\n", .{});
                        }
                    },
                    .checkpoint => {
                        if (entry.data.len >= @sizeOf(CheckpointRecord)) {
                            const checkpoint_data = std.mem.bytesToValue(CheckpointRecord, entry.data[0..@sizeOf(CheckpointRecord)]);
                            self.last_checkpoint_lsn.store(checkpoint_data.last_checkpoint_lsn, .release);
                            std.debug.print("  -> Processed checkpoint at LSN {}\n", .{checkpoint_data.last_checkpoint_lsn});
                        }
                    },
                }
                
                records_replayed += 1;
                
                // Update current LSN to the highest we've seen
                if (entry.header.timestamp > self.current_lsn.load(.acquire)) {
                    self.current_lsn.store(entry.header.timestamp, .release);
                }
            }
            
            std.debug.print("WAL recovery completed. Processed {} records\n", .{records_replayed});
            
            try self.flush();
        }
        
        /// Replay an insert operation during recovery
        fn replayInsertOperation(self: *Self, database: *anyopaque, data: []const u8) !void {
            const Database = @import("database.zig").Database;
            const db: *Database = @ptrCast(@alignCast(database));
            
            var reader = std.io.fixedBufferStream(data);
            const stream_reader = reader.reader();
            
            // Read the InsertUpdateRecord
            var record: InsertUpdateRecord = undefined;
            _ = try stream_reader.readAll(std.mem.asBytes(&record));
            
            // Read key and value
            const key = try self.allocator.alloc(u8, record.key_length);
            defer self.allocator.free(key);
            try stream_reader.readNoEof(key);
            
            const value = try self.allocator.alloc(u8, record.value_length);
            defer self.allocator.free(value);
            try stream_reader.readNoEof(value);
            
            // Set recovery mode to prevent WAL logging during replay
            db.is_recovery_mode.store(true, .release);
            defer db.is_recovery_mode.store(false, .release);
            
            // Replay the insert operation
            try db.put(key, value);
        }
        
        /// Replay an update operation during recovery
        fn replayUpdateOperation(self: *Self, database: *anyopaque, data: []const u8) !void {
            const Database = @import("database.zig").Database;
            const db: *Database = @ptrCast(@alignCast(database));
            
            var reader = std.io.fixedBufferStream(data);
            const stream_reader = reader.reader();
            
            // Read the UpdateRecord
            var record: UpdateRecord = undefined;
            _ = try stream_reader.readAll(std.mem.asBytes(&record));
            
            // Read key
            const key = try self.allocator.alloc(u8, record.key_length);
            defer self.allocator.free(key);
            try stream_reader.readNoEof(key);
            
            // Read old value (we don't need it for replay, but must read it to get to new value)
            const old_value = try self.allocator.alloc(u8, record.old_value_length);
            defer self.allocator.free(old_value);
            try stream_reader.readNoEof(old_value);
            
            // Read new value
            const new_value = try self.allocator.alloc(u8, record.new_value_length);
            defer self.allocator.free(new_value);
            try stream_reader.readNoEof(new_value);
            
            // Set recovery mode to prevent WAL logging during replay
            db.is_recovery_mode.store(true, .release);
            defer db.is_recovery_mode.store(false, .release);
            
            // Replay the update operation
            try db.put(key, new_value);
        }
        
        /// Replay a delete operation during recovery
        fn replayDeleteOperation(self: *Self, database: *anyopaque, data: []const u8) !void {
            const Database = @import("database.zig").Database;
            const db: *Database = @ptrCast(@alignCast(database));
            
            var reader = std.io.fixedBufferStream(data);
            const stream_reader = reader.reader();
            
            // Read the DeleteRecord
            var record: DeleteRecord = undefined;
            _ = try stream_reader.readAll(std.mem.asBytes(&record));
            
            // Read key
            const key = try self.allocator.alloc(u8, record.key_length);
            defer self.allocator.free(key);
            try stream_reader.readNoEof(key);
            
            // We don't need the old value for delete replay, but we need to skip over it
            const old_value = try self.allocator.alloc(u8, record.value_length);
            defer self.allocator.free(old_value);
            try stream_reader.readNoEof(old_value);
            
            // Set recovery mode to prevent WAL logging during replay
            db.is_recovery_mode.store(true, .release);
            defer db.is_recovery_mode.store(false, .release);
            
            // Replay the delete operation
            _ = try db.delete(key);
        }
        
        /// Start automatic checkpointing thread
        pub fn startCheckpointThread(self: *Self, database: *anyopaque) DatabaseError!void {
            if (self.checkpoint_thread != null) {
                return; // Already running
            }
            
            std.debug.print("Starting WAL checkpoint thread (interval: {}ms)\n", .{self.checkpoint_interval_ms});
            
            self.should_stop_checkpoint_thread.store(false, .release);
            self.checkpoint_thread = std.Thread.spawn(.{}, checkpointThreadMain, .{ self, database }) catch |err| {
                std.debug.print("Error starting checkpoint thread: {}\n", .{err});
                return DatabaseError.InternalError;
            };
        }
        
        /// Stop automatic checkpointing thread
        pub fn stopCheckpointThread(self: *Self) void {
            if (self.checkpoint_thread == null) {
                return; // Not running
            }
            
            std.debug.print("Stopping WAL checkpoint thread...\n", .{});
            
            self.should_stop_checkpoint_thread.store(true, .release);
            
            if (self.checkpoint_thread) |thread| {
                thread.join();
                self.checkpoint_thread = null;
            }
            
            std.debug.print("WAL checkpoint thread stopped\n", .{});
        }
        
        /// Configure checkpointing parameters
        pub fn configureCheckpointing(self: *Self, interval_ms: u64, max_wal_size_mb: u64, max_archived: u32) void {
            self.checkpoint_mutex.lock();
            defer self.checkpoint_mutex.unlock();
            
            self.checkpoint_interval_ms = interval_ms;
            self.max_wal_size_bytes = max_wal_size_mb * 1024 * 1024; // Convert MB to bytes
            self.max_archived_logs = max_archived;
            
            std.debug.print("Checkpoint configuration updated: interval={}ms, max_wal_size={}MB, max_archived={}\n", .{ interval_ms, max_wal_size_mb, max_archived });
        }
        
        /// Checkpoint statistics structure
        pub const CheckpointStats = struct {
            checkpoints_performed: u64,
            pages_written: u64,
            wal_size: u64,
            last_checkpoint_time: u64,
        };
        
        /// Get checkpoint statistics
        pub fn getCheckpointStats(self: *const Self) CheckpointStats {
            const wal_size = self.getCurrentWALSize();
            const last_checkpoint_time = @as(u64, @intCast(std.time.milliTimestamp()));
            
            return CheckpointStats{
                .checkpoints_performed = self.last_checkpoint_lsn.load(.acquire),
                .pages_written = 0, // Could be tracked in future
                .wal_size = wal_size,
                .last_checkpoint_time = last_checkpoint_time,
            };
        }
        
        /// Get current WAL file size
        fn getCurrentWALSize(self: *const Self) u64 {
            const stat = self.log_file.stat() catch |err| {
                std.debug.print("Error getting WAL size: {}\n", .{err});
                return 0;
            };
            return @as(u64, @intCast(stat.size));
        }
        
        /// Print checkpoint statistics
        pub fn printCheckpointStats(self: *const Self) void {
            const stats = self.getCheckpointStats();
            std.debug.print("Checkpoint Statistics:\n", .{});
            std.debug.print("  Checkpoints performed: {}\n", .{stats.checkpoints_performed});
            std.debug.print("  Pages written: {}\n", .{stats.pages_written});
            std.debug.print("  WAL size: {} bytes\n", .{stats.wal_size});
            std.debug.print("  Last checkpoint time: {}\n", .{stats.last_checkpoint_time});
        }
    };
};

/// Main checkpoint thread function
fn checkpointThreadMain(wal_manager: *WAL.Manager, database: *anyopaque) void {
    const Database = @import("database.zig").Database;
    const db: *Database = @ptrCast(@alignCast(database));
    
    std.debug.print("Checkpoint thread started\n", .{});
    
    while (!wal_manager.should_stop_checkpoint_thread.load(.acquire)) {
        // Sleep for the configured interval
        std.time.sleep(wal_manager.checkpoint_interval_ms * 1000 * 1000); // Convert ms to ns
        
        // Check if we should stop
        if (wal_manager.should_stop_checkpoint_thread.load(.acquire)) {
            break;
        }
        
        // Check if checkpoint is needed based on WAL size
        const current_wal_size = wal_manager.getCurrentWALSize();
        const should_checkpoint = current_wal_size > wal_manager.max_wal_size_bytes;
        
        if (should_checkpoint) {
            std.debug.print("Checkpoint thread: WAL size {} bytes exceeds threshold {} bytes, performing checkpoint\n", .{ current_wal_size, wal_manager.max_wal_size_bytes });
            
            // Perform checkpoint
            wal_manager.checkpoint_mutex.lock();
            defer wal_manager.checkpoint_mutex.unlock();
            
            const active_tx_count = db.getActiveTransactionCount();
            
            // Write checkpoint record
            _ = wal_manager.writeCheckpoint(@as(u32, @intCast(active_tx_count))) catch |err| {
                std.debug.print("Checkpoint thread: Error writing checkpoint: {}\n", .{err});
                continue;
            };
            
            // Flush WAL to disk
            wal_manager.flush() catch |err| {
                std.debug.print("Checkpoint thread: Error flushing WAL: {}\n", .{err});
                continue;
            };
            
            // Flush database buffer pool
            db.buffer_pool.flushAll() catch |err| {
                std.debug.print("Checkpoint thread: Error flushing buffer pool: {}\n", .{err});
                continue;
            };
            
            std.debug.print("Checkpoint thread: Checkpoint completed successfully\n", .{});
            
            // TODO: Consider WAL log rotation here if needed
            // This would involve creating a new WAL file and archiving the old one
        }
    }
    
    std.debug.print("Checkpoint thread exiting\n", .{});
}