const std = @import("std");
const Page = @import("page.zig").Page;
const DatabaseError = @import("../error.zig").DatabaseError;
const PAGE_SIZE = @import("page.zig").PAGE_SIZE;

/// Simple LRU node for tracking page access order
const LRUNode = struct {
    page_id: u32,
    page_ptr: *Page,
    prev: ?*LRUNode,
    next: ?*LRUNode,
    access_count: u32,
};

/// Simple LRU list implementation without internal synchronization
const LRUList = struct {
    const Self = @This();
    
    head: ?*LRUNode,
    tail: ?*LRUNode,
    count: usize,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .head = null,
            .tail = null,
            .count = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        var current = self.head;
        while (current) |node| {
            const next = node.next;
            self.allocator.destroy(node);
            current = next;
        }
        self.head = null;
        self.tail = null;
        self.count = 0;
    }
    
    /// Add a new node to the front (most recently used)
    pub fn addToFront(self: *Self, node: *LRUNode) void {
        node.prev = null;
        node.next = self.head;
        
        if (self.head) |head| {
            head.prev = node;
        } else {
            self.tail = node;
        }
        
        self.head = node;
        self.count += 1;
    }
    
    /// Move existing node to front (mark as recently used)
    pub fn moveToFront(self: *Self, node: *LRUNode) void {
        if (node == self.head) return; // Already at front
        
        // Remove from current position
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.head = node.next;
        }
        
        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.tail = node.prev;
        }
        
        // Add to front
        node.prev = null;
        node.next = self.head;
        
        if (self.head) |head| {
            head.prev = node;
        } else {
            self.tail = node;
        }
        
        self.head = node;
    }
    
    /// Remove node from list
    pub fn removeNode(self: *Self, node: *LRUNode) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.head = node.next;
        }
        
        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.tail = node.prev;
        }
        
        self.count -= 1;
    }
    
    /// Get least recently used node (from tail)
    pub fn getLRU(self: *Self) ?*LRUNode {
        return self.tail;
    }
};

/// Simplified buffer pool with single mutex design
pub const BufferPool = struct {
    const Self = @This();
    
    // Core data structures
    pages: std.HashMap(u32, *Page, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    lru_list: LRUList,
    lru_map: std.HashMap(u32, *LRUNode, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    
    // Configuration
    capacity: usize,
    allocator: std.mem.Allocator,
    file: ?std.fs.File,
    
    // Single mutex for all operations - prevents deadlocks
    mutex: std.Thread.Mutex,
    
    // Statistics (atomic for lock-free reads)
    cache_hits: std.atomic.Value(u64),
    cache_misses: std.atomic.Value(u64),
    evictions: std.atomic.Value(u64),
    write_backs: std.atomic.Value(u64),
    
    pub fn init(allocator: std.mem.Allocator, capacity: usize) Self {
        return Self{
            .pages = std.HashMap(u32, *Page, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .lru_list = LRUList.init(allocator),
            .lru_map = std.HashMap(u32, *LRUNode, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .capacity = capacity,
            .allocator = allocator,
            .file = null,
            .mutex = std.Thread.Mutex{},
            .cache_hits = std.atomic.Value(u64).init(0),
            .cache_misses = std.atomic.Value(u64).init(0),
            .evictions = std.atomic.Value(u64).init(0),
            .write_backs = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn setFile(self: *Self, file: std.fs.File) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.file = file;
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Clean up LRU tracking
        self.lru_list.deinit();
        self.lru_map.deinit();
        
        // Free all pages
        var iter = self.pages.iterator();
        while (iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pages.deinit();
    }
    
    /// Get page for shared (read) access
    pub fn getPageShared(self: *Self, page_id: u32) DatabaseError!*Page {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check if page is already in buffer
        if (self.pages.get(page_id)) |page| {
            // Update LRU on cache hit
            if (self.lru_map.get(page_id)) |node| {
                node.access_count += 1;
                self.lru_list.moveToFront(node);
            }
            
            page.pinShared();
            _ = self.cache_hits.fetchAdd(1, .monotonic);
            return page;
        }
        
        // Cache miss - need to load page
        _ = self.cache_misses.fetchAdd(1, .monotonic);
        
        // Check if we need to evict
        if (self.pages.count() >= self.capacity) {
            try self.evictPageInternal();
        }
        
        // Allocate and initialize new page
        const page = try self.allocator.create(Page);
        page.* = Page.init(page_id);
        
        // Load from file if available
        if (self.file) |*file| {
            self.readPageFromFile(file, page_id, page) catch {
                // If read fails, just use empty page
                page.* = Page.init(page_id);
            };
        }
        
        // Pin page and add to structures
        page.pinShared();
        try self.pages.put(page_id, page);
        try self.addToLRUInternal(page_id, page);
        
        return page;
    }
    
    /// Get page for exclusive (write) access
    pub fn getPageExclusive(self: *Self, page_id: u32) DatabaseError!*Page {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check if page is already in buffer
        if (self.pages.get(page_id)) |page| {
            // Update LRU on cache hit
            if (self.lru_map.get(page_id)) |node| {
                node.access_count += 1;
                self.lru_list.moveToFront(node);
            }
            
            page.pinExclusive();
            _ = self.cache_hits.fetchAdd(1, .monotonic);
            return page;
        }
        
        // Cache miss - need to load page
        _ = self.cache_misses.fetchAdd(1, .monotonic);
        
        // Check if we need to evict
        if (self.pages.count() >= self.capacity) {
            try self.evictPageInternal();
        }
        
        // Allocate and initialize new page
        const page = try self.allocator.create(Page);
        page.* = Page.init(page_id);
        
        // Load from file if available
        if (self.file) |*file| {
            self.readPageFromFile(file, page_id, page) catch {
                // If read fails, just use empty page
                page.* = Page.init(page_id);
            };
        }
        
        // Pin page and add to structures
        page.pinExclusive();
        try self.pages.put(page_id, page);
        try self.addToLRUInternal(page_id, page);
        
        return page;
    }
    
    /// Legacy method - defaults to shared access
    pub fn getPage(self: *Self, page_id: u32) DatabaseError!*Page {
        return self.getPageShared(page_id);
    }
    
    /// Unpin page after shared access
    pub fn unpinPageShared(self: *Self, page_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.pages.get(page_id)) |page| {
            page.unpinShared();
        }
    }
    
    /// Unpin page after exclusive access
    pub fn unpinPageExclusive(self: *Self, page_id: u32, is_dirty: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.pages.get(page_id)) |page| {
            page.unpinExclusive(is_dirty);
        }
    }
    
    /// Legacy method
    pub fn unpinPage(self: *Self, page_id: u32, is_dirty: bool) DatabaseError!void {
        if (is_dirty) {
            self.unpinPageExclusive(page_id, true);
        } else {
            self.unpinPageShared(page_id);
        }
    }
    
    /// Flush a specific page
    pub fn flushPage(self: *Self, page_id: u32) DatabaseError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.pages.get(page_id)) |page| {
            if (page.isDirtyAtomic()) {
                try self.writePageToFileInternal(page);
                _ = self.write_backs.fetchAdd(1, .monotonic);
            }
        }
    }
    
    /// Flush all dirty pages
    pub fn flushAll(self: *Self) DatabaseError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var iter = self.pages.iterator();
        while (iter.next()) |entry| {
            const page = entry.value_ptr.*;
            if (page.isDirtyAtomic()) {
                try self.writePageToFileInternal(page);
                _ = self.write_backs.fetchAdd(1, .monotonic);
            }
        }
    }
    
    /// Internal eviction - must be called with mutex held
    fn evictPageInternal(self: *Self) DatabaseError!void {
        // Find LRU candidate
        var victim_node = self.lru_list.getLRU();
        
        // Scan for unpinned page
        var attempts: u32 = 0;
        while (victim_node != null and attempts < 10) {
            const node = victim_node.?;
            const page = node.page_ptr;
            
            // Check if page is unpinned
            if (page.lock.pin_count.load(.acquire) == 0) {
                // Found eviction candidate
                const page_id = node.page_id;
                
                // Write to disk if dirty
                if (page.isDirtyAtomic()) {
                    try self.writePageToFileInternal(page);
                    _ = self.write_backs.fetchAdd(1, .monotonic);
                }
                
                // Remove from all structures
                self.lru_list.removeNode(node);
                _ = self.lru_map.remove(page_id);
                _ = self.pages.remove(page_id);
                
                // Free memory
                self.allocator.destroy(node);
                self.allocator.destroy(page);
                
                _ = self.evictions.fetchAdd(1, .monotonic);
                return;
            }
            
            victim_node = node.prev;
            attempts += 1;
        }
        
        // No unpinned pages found
        return DatabaseError.OutOfMemory;
    }
    
    /// Internal LRU addition - must be called with mutex held
    fn addToLRUInternal(self: *Self, page_id: u32, page: *Page) DatabaseError!void {
        const node = try self.allocator.create(LRUNode);
        node.* = LRUNode{
            .page_id = page_id,
            .page_ptr = page,
            .prev = null,
            .next = null,
            .access_count = 1,
        };
        
        self.lru_list.addToFront(node);
        try self.lru_map.put(page_id, node);
    }
    
    /// Internal file write - must be called with mutex held
    fn writePageToFileInternal(self: *Self, page: *Page) DatabaseError!void {
        if (self.file == null) return;
        
        const file = self.file.?;
        const offset = page.page_id * PAGE_SIZE;
        
        file.seekTo(offset) catch {
            return DatabaseError.InternalError;
        };
        
        file.writeAll(&page.data) catch {
            return DatabaseError.InternalError;
        };
        
        page.clearDirty();
    }
    
    /// Internal file read - must be called with mutex held
    fn readPageFromFile(self: *Self, file: *std.fs.File, page_id: u32, page: *Page) !void {
        _ = self; // unused
        
        const offset = page_id * PAGE_SIZE;
        
        const file_size = file.getEndPos() catch {
            return error.FileNotOpen;
        };
        
        if (offset >= file_size) {
            return error.IncompleteRead;
        }
        
        file.seekTo(offset) catch {
            return error.FileNotOpen;
        };
        
        const bytes_read = file.readAll(&page.data) catch {
            return error.FileNotOpen;
        };
        
        if (bytes_read != PAGE_SIZE) {
            return error.IncompleteRead;
        }
        
        page.page_id = page_id;
        page.is_dirty = false;
        page.pin_count = 0;
    }
    
    /// Get buffer pool statistics
    pub fn getStatistics(self: *Self) struct {
        cache_hits: u64,
        cache_misses: u64,
        evictions: u64,
        write_backs: u64,
        hit_ratio: f64,
        pages_in_buffer: u32,
        capacity: usize,
    } {
        const hits = self.cache_hits.load(.monotonic);
        const misses = self.cache_misses.load(.monotonic);
        const total_accesses = hits + misses;
        const hit_ratio = if (total_accesses > 0) @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total_accesses)) else 0.0;
        
        self.mutex.lock();
        const pages_count = self.pages.count();
        self.mutex.unlock();
        
        return .{
            .cache_hits = hits,
            .cache_misses = misses,
            .evictions = self.evictions.load(.monotonic),
            .write_backs = self.write_backs.load(.monotonic),
            .hit_ratio = hit_ratio,
            .pages_in_buffer = @as(u32, @intCast(pages_count)),
            .capacity = self.capacity,
        };
    }
    
    /// Print buffer pool statistics
    pub fn printStatistics(self: *Self) void {
        const stats = self.getStatistics();
        
        std.debug.print("\n=== Buffer Pool Statistics ===\n", .{});
        std.debug.print("Cache Hits: {}\n", .{stats.cache_hits});
        std.debug.print("Cache Misses: {}\n", .{stats.cache_misses});
        std.debug.print("Hit Ratio: {d:.2}%\n", .{stats.hit_ratio * 100.0});
        std.debug.print("Evictions: {}\n", .{stats.evictions});
        std.debug.print("Write-backs: {}\n", .{stats.write_backs});
        std.debug.print("Pages in Buffer: {}/{}\n", .{ stats.pages_in_buffer, stats.capacity });
        std.debug.print("==============================\n\n", .{});
    }
};

// Comprehensive test suite
test "LRUList basic operations" {
    const allocator = std.testing.allocator;
    var lru_list = LRUList.init(allocator);
    defer lru_list.deinit();

    // Test empty list
    try std.testing.expect(lru_list.head == null);
    try std.testing.expect(lru_list.tail == null);
    try std.testing.expect(lru_list.count == 0);
    try std.testing.expect(lru_list.getLRU() == null);

    // Create test pages and nodes
    var page1 = Page.init(1);
    var page2 = Page.init(2);

    const node1 = try allocator.create(LRUNode);
    node1.* = LRUNode{
        .page_id = 1,
        .page_ptr = &page1,
        .prev = null,
        .next = null,
        .access_count = 1,
    };

    const node2 = try allocator.create(LRUNode);
    node2.* = LRUNode{
        .page_id = 2,
        .page_ptr = &page2,
        .prev = null,
        .next = null,
        .access_count = 1,
    };

    // Test adding nodes
    lru_list.addToFront(node1);
    try std.testing.expect(lru_list.head == node1);
    try std.testing.expect(lru_list.tail == node1);
    try std.testing.expect(lru_list.count == 1);

    lru_list.addToFront(node2);
    try std.testing.expect(lru_list.head == node2);
    try std.testing.expect(lru_list.tail == node1);
    try std.testing.expect(lru_list.count == 2);

    // Test moveToFront
    lru_list.moveToFront(node1);
    try std.testing.expect(lru_list.head == node1);
    try std.testing.expect(lru_list.tail == node2);
    try std.testing.expect(lru_list.getLRU() == node2);
}

test "BufferPool initialization and basic operations" {
    const allocator = std.testing.allocator;
    var buffer_pool = BufferPool.init(allocator, 3);
    defer buffer_pool.deinit();

    // Test initial state
    const initial_stats = buffer_pool.getStatistics();
    try std.testing.expect(initial_stats.cache_hits == 0);
    try std.testing.expect(initial_stats.cache_misses == 0);
    try std.testing.expect(initial_stats.pages_in_buffer == 0);
    try std.testing.expect(initial_stats.capacity == 3);

    // Test getting a page (cache miss)
    const page1 = try buffer_pool.getPageShared(1);
    try std.testing.expect(page1.page_id == 1);

    var stats = buffer_pool.getStatistics();
    try std.testing.expect(stats.cache_hits == 0);
    try std.testing.expect(stats.cache_misses == 1);
    try std.testing.expect(stats.pages_in_buffer == 1);

    // Test getting same page again (cache hit)
    const page1_again = try buffer_pool.getPageShared(1);
    try std.testing.expect(page1_again == page1);

    stats = buffer_pool.getStatistics();
    try std.testing.expect(stats.cache_hits == 1);
    try std.testing.expect(stats.cache_misses == 1);
    try std.testing.expect(stats.hit_ratio == 0.5);

    // Unpin pages
    buffer_pool.unpinPageShared(1);
    buffer_pool.unpinPageShared(1);
}

test "BufferPool exclusive access" {
    const allocator = std.testing.allocator;
    var buffer_pool = BufferPool.init(allocator, 3);
    defer buffer_pool.deinit();

    // Test exclusive access
    const page1 = try buffer_pool.getPageExclusive(1);
    try std.testing.expect(page1.page_id == 1);
    
    // Unpin the page first
    buffer_pool.unpinPageExclusive(1, false);

    // Test getting same page again (should be cache hit)
    const page1_again = try buffer_pool.getPageExclusive(1);
    try std.testing.expect(page1_again == page1);
    
    // Unpin the page again
    buffer_pool.unpinPageExclusive(1, false);

    const stats = buffer_pool.getStatistics();
    try std.testing.expect(stats.cache_hits == 1);
    try std.testing.expect(stats.cache_misses == 1);
}

test "BufferPool LRU eviction" {
    const allocator = std.testing.allocator;
    var buffer_pool = BufferPool.init(allocator, 2); // Small capacity
    defer buffer_pool.deinit();

    // Fill buffer to capacity
    const page1 = try buffer_pool.getPageShared(1);
    buffer_pool.unpinPageShared(1);

    const page2 = try buffer_pool.getPageShared(2);
    buffer_pool.unpinPageShared(2);

    var stats = buffer_pool.getStatistics();
    try std.testing.expect(stats.pages_in_buffer == 2);

    // Access page 1 to make it more recently used
    _ = try buffer_pool.getPageShared(1);
    buffer_pool.unpinPageShared(1);

    // Add third page - should evict page 2 (LRU)
    _ = try buffer_pool.getPageShared(3);
    buffer_pool.unpinPageShared(3);

    stats = buffer_pool.getStatistics();
    try std.testing.expect(stats.evictions >= 1);
    try std.testing.expect(stats.pages_in_buffer == 2);

    // Verify page 1 is still in buffer (cache hit)
    const page1_again = try buffer_pool.getPageShared(1);
    try std.testing.expect(page1_again == page1);
    buffer_pool.unpinPageShared(1);

    // Verify page 2 was evicted (cache miss)
    const page2_again = try buffer_pool.getPageShared(2);
    try std.testing.expect(page2_again != page2);
    buffer_pool.unpinPageShared(2);
}

test "BufferPool page flushing" {
    const allocator = std.testing.allocator;
    var buffer_pool = BufferPool.init(allocator, 3);
    defer buffer_pool.deinit();

    // Create temporary file
    const temp_file = std.fs.cwd().createFile("test_buffer.db", .{ .read = true }) catch |err| {
        std.debug.print("Could not create test file: {}\n", .{err});
        return;
    };
    defer {
        temp_file.close();
        std.fs.cwd().deleteFile("test_buffer.db") catch {};
    }

    buffer_pool.setFile(temp_file);

    // Get page and mark as dirty
    const page1 = try buffer_pool.getPageExclusive(1);
    const test_data = "Hello, World!";
    @memcpy(page1.data[0..test_data.len], test_data);
    buffer_pool.unpinPageExclusive(1, true);

    // Test flush
    try buffer_pool.flushPage(1);
    
    var stats = buffer_pool.getStatistics();
    try std.testing.expect(stats.write_backs == 1);

    // Test flush all
    const page2 = try buffer_pool.getPageExclusive(2);
    @memcpy(page2.data[0..test_data.len], test_data);
    buffer_pool.unpinPageExclusive(2, true);
    
    try buffer_pool.flushAll();
    
    stats = buffer_pool.getStatistics();
    try std.testing.expect(stats.write_backs == 2);
}

test "BufferPool edge cases" {
    const allocator = std.testing.allocator;
    var buffer_pool = BufferPool.init(allocator, 1); // Capacity of 1
    defer buffer_pool.deinit();

    // Test unpinning non-existent pages
    buffer_pool.unpinPageShared(999);
    buffer_pool.unpinPageExclusive(999, false);

    // Test flushing non-existent page
    try buffer_pool.flushPage(999);

    // Test legacy methods
    const page1 = try buffer_pool.getPage(1);
    try std.testing.expect(page1.page_id == 1);
    try buffer_pool.unpinPage(1, false);
}

test "BufferPool concurrent access simulation" {
    const allocator = std.testing.allocator;
    var buffer_pool = BufferPool.init(allocator, 3);
    defer buffer_pool.deinit();

    // Get and immediately unpin multiple pages to simulate concurrent access
    for (0..5) |i| {
        const page = try buffer_pool.getPageShared(@as(u32, @intCast(i + 1)));
        try std.testing.expect(page.page_id == @as(u32, @intCast(i + 1)));
        buffer_pool.unpinPageShared(@as(u32, @intCast(i + 1)));
    }
    
    const stats = buffer_pool.getStatistics();
    try std.testing.expect(stats.cache_misses == 5);
    try std.testing.expect(stats.evictions >= 2);
    try std.testing.expect(stats.pages_in_buffer == 3);
}