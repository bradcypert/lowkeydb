const std = @import("std");

/// Thread-safe utilities for LowkeyDB
pub const Threading = struct {
    /// Reader-Writer lock implementation
    pub const RwLock = struct {
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,
        readers: std.atomic.Value(u32),
        writer: std.atomic.Value(bool),
        
        const Self = @This();
        
        pub fn init() Self {
            return Self{
                .mutex = std.Thread.Mutex{},
                .condition = std.Thread.Condition{},
                .readers = std.atomic.Value(u32).init(0),
                .writer = std.atomic.Value(bool).init(false),
            };
        
        }
        pub fn lockShared(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            // Wait for any active writer to finish
            while (self.writer.load(.acquire)) {
                self.condition.wait(&self.mutex);
            }
            
            // Increment reader count
            _ = self.readers.fetchAdd(1, .acq_rel);
        }
        
        pub fn unlockShared(self: *Self) void {
            const prev_readers = self.readers.fetchSub(1, .acq_rel);
            
            // If we were the last reader, notify waiting writers
            if (prev_readers == 1) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.condition.broadcast();
            }
        }
        
        pub fn lock(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            // Wait for all readers and writers to finish
            while (self.readers.load(.acquire) > 0 or self.writer.load(.acquire)) {
                self.condition.wait(&self.mutex);
            }
            
            // Mark as having an active writer
            self.writer.store(true, .release);
        }
        
        pub fn unlock(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            // Clear writer flag
            self.writer.store(false, .release);
            
            // Notify all waiting readers and writers
            self.condition.broadcast();
        }
    };
    
    /// Atomic page pin counter
    pub const AtomicPinCount = std.atomic.Value(u32);
    
    /// Atomic dirty flag
    pub const AtomicDirty = std.atomic.Value(bool);
    
    /// Page-level synchronization
    pub const PageLock = struct {
        rw_lock: RwLock,
        pin_count: AtomicPinCount,
        is_dirty: AtomicDirty,
        
        const Self = @This();
        
        pub fn init() Self {
            return Self{
                .rw_lock = RwLock.init(),
                .pin_count = AtomicPinCount.init(0),
                .is_dirty = AtomicDirty.init(false),
            };
        }
        
        /// Pin page for reading (shared access)
        pub fn pinShared(self: *Self) void {
            self.rw_lock.lockShared();
            _ = self.pin_count.fetchAdd(1, .acq_rel);
        }
        
        /// Pin page for writing (exclusive access)  
        pub fn pinExclusive(self: *Self) void {
            self.rw_lock.lock();
            _ = self.pin_count.fetchAdd(1, .acq_rel);
        }
        
        /// Unpin page after shared access
        pub fn unpinShared(self: *Self) void {
            _ = self.pin_count.fetchSub(1, .acq_rel);
            self.rw_lock.unlockShared();
        }
        
        /// Unpin page after exclusive access
        pub fn unpinExclusive(self: *Self, dirty: bool) void {
            if (dirty) {
                self.is_dirty.store(true, .release);
            }
            _ = self.pin_count.fetchSub(1, .acq_rel);
            self.rw_lock.unlock();
        }
        
        /// Check if page is pinned
        pub fn isPinned(self: *const Self) bool {
            return self.pin_count.load(.acquire) > 0;
        }
        
        /// Check if page is dirty
        pub fn isDirty(self: *const Self) bool {
            return self.is_dirty.load(.acquire);
        }
        
        /// Clear dirty flag (typically after flush)
        pub fn clearDirty(self: *Self) void {
            self.is_dirty.store(false, .release);
        }
    };
    
    /// Database-level coordination
    pub const DatabaseLock = struct {
        operations_mutex: std.Thread.Mutex,
        active_operations: std.atomic.Value(u32),
        shutdown_requested: std.atomic.Value(bool),
        
        const Self = @This();
        
        pub fn init() Self {
            return Self{
                .operations_mutex = std.Thread.Mutex{},
                .active_operations = std.atomic.Value(u32).init(0),
                .shutdown_requested = std.atomic.Value(bool).init(false),
            };
        }
        
        /// Begin a database operation (get, put, delete, etc.)
        pub fn beginOperation(self: *Self) bool {
            if (self.shutdown_requested.load(.acquire)) {
                return false; // Database is shutting down
            }
            
            _ = self.active_operations.fetchAdd(1, .acq_rel);
            
            // Double-check shutdown after incrementing
            if (self.shutdown_requested.load(.acquire)) {
                _ = self.active_operations.fetchSub(1, .acq_rel);
                return false;
            }
            
            return true;
        }
        
        /// End a database operation
        pub fn endOperation(self: *Self) void {
            _ = self.active_operations.fetchSub(1, .acq_rel);
        }
        
        /// Request database shutdown and wait for operations to complete
        pub fn shutdown(self: *Self) void {
            self.shutdown_requested.store(true, .release);
            
            // Wait for all active operations to complete
            while (self.active_operations.load(.acquire) > 0) {
                std.Thread.yield() catch {};
            }
        }
        
        /// Lock for exclusive database operations (like schema changes)
        pub fn lockExclusive(self: *Self) void {
            self.operations_mutex.lock();
        }
        
        /// Unlock after exclusive operation
        pub fn unlockExclusive(self: *Self) void {
            self.operations_mutex.unlock();
        }
    };
    
    /// Concurrent hash map wrapper for page management
    pub const ConcurrentPageMap = struct {
        map: std.HashMap(u32, *Page, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
        mutex: std.Thread.Mutex,
        
        const Self = @This();
        const Page = @import("storage/page.zig").Page;
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .map = std.HashMap(u32, *Page, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
                .mutex = std.Thread.Mutex{},
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.map.deinit();
        }
        
        pub fn get(self: *Self, key: u32) ?*Page {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.map.get(key);
        }
        
        pub fn put(self: *Self, key: u32, value: *Page) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.map.put(key, value);
        }
        
        pub fn remove(self: *Self, key: u32) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.map.remove(key);
        }
        
        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.map.count();
        }
        
        /// Iterator must be used with external synchronization
        pub fn iterator(self: *Self) std.HashMap(u32, *Page, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).Iterator {
            // Caller must hold mutex for duration of iteration
            return self.map.iterator();
        }
        
        /// Lock for safe iteration
        pub fn lockForIteration(self: *Self) void {
            self.mutex.lock();
        }
        
        /// Unlock after iteration
        pub fn unlockAfterIteration(self: *Self) void {
            self.mutex.unlock();
        }
    };
};