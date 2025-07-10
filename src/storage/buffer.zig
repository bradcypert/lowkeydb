const std = @import("std");
const Page = @import("page.zig").Page;
const DatabaseError = @import("../error.zig").DatabaseError;
const Threading = @import("../threading.zig").Threading;
const PAGE_SIZE = @import("page.zig").PAGE_SIZE;

/// LRU node for tracking page access order
const LRUNode = struct {
    page_id: u32,
    page_ptr: *Page,
    prev: ?*LRUNode,
    next: ?*LRUNode,
    last_access_time: u64,
    access_count: u32,
};

/// LRU list for efficient eviction candidate selection
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
        self.removeNode(node);
        
        // Add to front
        self.addToFront(node);
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

pub const BufferPool = struct {
    const Self = @This();
    
    pages: Threading.ConcurrentPageMap,
    free_pages: std.ArrayList(*Page),
    free_pages_mutex: std.Thread.Mutex,
    capacity: usize,
    allocator: std.mem.Allocator,
    file: ?std.fs.File, // Optional file for reading pages
    buffer_mutex: std.Thread.Mutex, // Protects overall buffer pool operations
    
    // LRU tracking
    lru_list: LRUList,
    lru_map: std.HashMap(u32, *LRUNode, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    lru_mutex: std.Thread.Mutex,
    
    // Statistics
    cache_hits: std.atomic.Value(u64),
    cache_misses: std.atomic.Value(u64),
    evictions: std.atomic.Value(u64),
    write_backs: std.atomic.Value(u64),
    
    pub fn init(allocator: std.mem.Allocator, capacity: usize) Self {
        return Self{
            .pages = Threading.ConcurrentPageMap.init(allocator),
            .free_pages = std.ArrayList(*Page).init(allocator),
            .free_pages_mutex = std.Thread.Mutex{},
            .capacity = capacity,
            .allocator = allocator,
            .file = null,
            .buffer_mutex = std.Thread.Mutex{},
            .lru_list = LRUList.init(allocator),
            .lru_map = std.HashMap(u32, *LRUNode, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .lru_mutex = std.Thread.Mutex{},
            .cache_hits = std.atomic.Value(u64).init(0),
            .cache_misses = std.atomic.Value(u64).init(0),
            .evictions = std.atomic.Value(u64).init(0),
            .write_backs = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn setFile(self: *Self, file: std.fs.File) void {
        self.file = file;
    }
    
    pub fn deinit(self: *Self) void {
        // Lock to prevent concurrent access during cleanup
        self.buffer_mutex.lock();
        defer self.buffer_mutex.unlock();
        
        // Clean up LRU tracking
        self.lru_mutex.lock();
        self.lru_list.deinit();
        self.lru_map.deinit();
        self.lru_mutex.unlock();
        
        // Free all pages
        self.pages.lockForIteration();
        var iter = self.pages.iterator();
        while (iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pages.unlockAfterIteration();
        self.pages.deinit();
        
        // Free any remaining pages in free_pages list
        self.free_pages_mutex.lock();
        for (self.free_pages.items) |page| {
            self.allocator.destroy(page);
        }
        self.free_pages.deinit();
        self.free_pages_mutex.unlock();
    }
    
    /// Get page for shared (read) access
    pub fn getPageShared(self: *Self, page_id: u32) DatabaseError!*Page {
        // First try to find existing page
        if (self.pages.get(page_id)) |page| {
            page.pinShared();
            // Update LRU tracking for cache hit
            self.updateLRUAccess(page_id, page);
            _ = self.cache_hits.fetchAdd(1, .monotonic);
            return page;
        }
        
        // Page not in buffer - cache miss
        _ = self.cache_misses.fetchAdd(1, .monotonic);
        
        // Need to allocate/load with exclusive access
        self.buffer_mutex.lock();
        defer self.buffer_mutex.unlock();
        
        // Double-check after acquiring lock (another thread might have loaded it)
        if (self.pages.get(page_id)) |page| {
            page.pinShared();
            self.updateLRUAccess(page_id, page);
            return page;
        }
        
        // Page still not found, allocate new one
        const page = try self.allocatePage(page_id);
        
        // Initialize page data
        if (self.file) |*file| {
            self.readPageFromFile(file, page_id, page) catch |err| switch (err) {
                error.FileNotOpen => {
                    // File is closed/invalid, just initialize empty page
                    page.* = Page.init(page_id);
                },
                else => {
                    // Other errors (like reading beyond EOF for new pages)
                    page.* = Page.init(page_id);
                },
            };
        } else {
            page.* = Page.init(page_id);
        }
        
        // Pin for shared access before adding to map
        page.pinShared();
        
        try self.pages.put(page_id, page);
        
        // Add to LRU tracking
        self.addToLRUTracking(page_id, page) catch |err| {
            // If LRU tracking fails, continue without it
            std.debug.print("Warning: Failed to add page {} to LRU tracking: {}\n", .{ page_id, err });
        };
        
        return page;
    }
    
    /// Get page for exclusive (write) access
    pub fn getPageExclusive(self: *Self, page_id: u32) DatabaseError!*Page {
        // Always acquire buffer mutex for exclusive access to ensure atomicity
        self.buffer_mutex.lock();
        defer self.buffer_mutex.unlock();
        
        // Check if page is already in buffer
        if (self.pages.get(page_id)) |page| {
            page.pinExclusive();
            // Update LRU tracking for cache hit
            self.updateLRUAccess(page_id, page);
            _ = self.cache_hits.fetchAdd(1, .monotonic);
            return page;
        }
        
        // Page not in buffer - cache miss
        _ = self.cache_misses.fetchAdd(1, .monotonic);
        
        // Allocate new page
        const page = try self.allocatePage(page_id);
        
        // Initialize page data
        if (self.file) |*file| {
            self.readPageFromFile(file, page_id, page) catch |err| switch (err) {
                error.FileNotOpen => {
                    // File is closed/invalid, just initialize empty page
                    page.* = Page.init(page_id);
                },
                else => {
                    // Other errors (like reading beyond EOF for new pages)
                    page.* = Page.init(page_id);
                },
            };
        } else {
            page.* = Page.init(page_id);
        }
        
        // Pin for exclusive access before adding to map
        page.pinExclusive();
        
        try self.pages.put(page_id, page);
        
        // Add to LRU tracking
        self.addToLRUTracking(page_id, page) catch |err| {
            // If LRU tracking fails, continue without it
            std.debug.print("Warning: Failed to add page {} to LRU tracking: {}\n", .{ page_id, err });
        };
        
        return page;
    }
    
    /// Legacy method - defaults to shared access for compatibility
    pub fn getPage(self: *Self, page_id: u32) DatabaseError!*Page {
        return self.getPageShared(page_id);
    }
    
    /// Unpin page after shared access
    pub fn unpinPageShared(self: *Self, page_id: u32) void {
        if (self.pages.get(page_id)) |page| {
            page.unpinShared();
        }
    }
    
    /// Unpin page after exclusive access
    pub fn unpinPageExclusive(self: *Self, page_id: u32, is_dirty: bool) void {
        if (self.pages.get(page_id)) |page| {
            page.unpinExclusive(is_dirty);
        }
    }
    
    /// Legacy method - assumes shared access for compatibility
    pub fn unpinPage(self: *Self, page_id: u32, is_dirty: bool) DatabaseError!void {
        if (is_dirty) {
            self.unpinPageExclusive(page_id, true);
        } else {
            self.unpinPageShared(page_id);
        }
    }
    
    pub fn flushPage(self: *Self, page_id: u32) DatabaseError!void {
        const page = self.pages.get(page_id) orelse return;
        
        if (page.isDirtyAtomic()) {
            try self.writePageToFile(page);
            _ = self.write_backs.fetchAdd(1, .monotonic);
        }
    }
    
    pub fn flushAll(self: *Self) DatabaseError!void {
        self.pages.lockForIteration();
        defer self.pages.unlockAfterIteration();
        
        var iter = self.pages.iterator();
        while (iter.next()) |entry| {
            const page = entry.value_ptr.*;
            if (page.isDirtyAtomic()) {
                try self.writePageToFile(page);
                _ = self.write_backs.fetchAdd(1, .monotonic);
            }
        }
    }
    
    fn allocatePage(self: *Self, page_id: u32) DatabaseError!*Page {
        // Try to reuse a page from free list
        self.free_pages_mutex.lock();
        if (self.free_pages.items.len > 0) {
            const page = self.free_pages.orderedRemove(self.free_pages.items.len - 1);
            self.free_pages_mutex.unlock();
            page.* = Page.init(page_id);
            return page;
        }
        self.free_pages_mutex.unlock();
        
        // If we're at capacity, evict a page
        if (self.pages.count() >= self.capacity) {
            try self.evictPage();
        }
        
        // Allocate new page
        const page = try self.allocator.create(Page);
        page.* = Page.init(page_id);
        return page;
    }
    
    fn evictPage(self: *Self) DatabaseError!void {
        // Find LRU candidate for eviction
        self.lru_mutex.lock();
        const lru_node = self.lru_list.getLRU();
        
        if (lru_node == null) {
            self.lru_mutex.unlock();
            return DatabaseError.OutOfMemory; // No pages to evict
        }
        
        const victim_node = lru_node.?;
        const victim_page_id = victim_node.page_id;
        const victim_page = victim_node.page_ptr;
        
        // Check if page is pinned (cannot evict pinned pages)
        if (victim_page.lock.pin_count.load(.acquire) > 0) {
            self.lru_mutex.unlock();
            // Try to find another victim by scanning LRU list
            return self.evictUnpinnedPage();
        }
        
        // Remove from LRU tracking
        self.lru_list.removeNode(victim_node);
        _ = self.lru_map.remove(victim_page_id);
        self.allocator.destroy(victim_node);
        self.lru_mutex.unlock();
        
        // Write dirty page to disk if needed
        if (victim_page.isDirtyAtomic()) {
            try self.writePageToFile(victim_page);
            _ = self.write_backs.fetchAdd(1, .monotonic);
        }
        
        // Remove from page map
        _ = self.pages.remove(victim_page_id);
        
        // Add to free list for reuse
        self.free_pages_mutex.lock();
        try self.free_pages.append(victim_page);
        self.free_pages_mutex.unlock();
        
        _ = self.evictions.fetchAdd(1, .monotonic);
        
        std.debug.print("Evicted page {} (dirty: {})\n", .{ victim_page_id, victim_page.isDirtyAtomic() });
    }
    
    /// Try to find and evict an unpinned page when primary LRU candidate is pinned
    fn evictUnpinnedPage(self: *Self) DatabaseError!void {
        self.lru_mutex.lock();
        defer self.lru_mutex.unlock();
        
        // Scan from tail (LRU) towards head looking for unpinned page
        var current = self.lru_list.tail;
        var attempts: u32 = 0;
        const max_attempts = 10; // Limit search to avoid long delays
        
        while (current != null and attempts < max_attempts) {
            const node = current.?;
            const page = node.page_ptr;
            
            if (page.lock.pin_count.load(.acquire) == 0) {
                // Found unpinned page, evict it
                const page_id = node.page_id;
                
                // Write dirty page to disk if needed
                if (page.isDirtyAtomic()) {
                    // Temporarily unlock LRU mutex for disk I/O
                    self.lru_mutex.unlock();
                    self.writePageToFile(page) catch |err| {
                        self.lru_mutex.lock();
                        return err;
                    };
                    _ = self.write_backs.fetchAdd(1, .monotonic);
                    self.lru_mutex.lock();
                }
                
                // Remove from LRU tracking
                self.lru_list.removeNode(node);
                _ = self.lru_map.remove(page_id);
                
                // Remove from page map (unlock LRU mutex temporarily)
                self.lru_mutex.unlock();
                _ = self.pages.remove(page_id);
                
                // Add to free list
                self.free_pages_mutex.lock();
                self.free_pages.append(page) catch {};
                self.free_pages_mutex.unlock();
                
                self.allocator.destroy(node);
                _ = self.evictions.fetchAdd(1, .monotonic);
                
                std.debug.print("Evicted unpinned page {} (dirty: {})\n", .{ page_id, page.isDirtyAtomic() });
                return;
            }
            
            current = node.prev;
            attempts += 1;
        }
        
        // No unpinned pages found
        return DatabaseError.OutOfMemory;
    }
    
    /// Write a dirty page back to file
    fn writePageToFile(self: *Self, page: *Page) DatabaseError!void {
        if (self.file == null) return; // No file to write to
        
        const file = self.file.?;
        const offset = page.page_id * PAGE_SIZE;
        
        file.seekTo(offset) catch {
            return DatabaseError.InternalError;
        };
        
        file.writeAll(&page.data) catch {
            return DatabaseError.InternalError;
        };
        
        // Mark page as clean after successful write
        page.clearDirty();
    }
    
    /// Add page to LRU tracking
    fn addToLRUTracking(self: *Self, page_id: u32, page: *Page) DatabaseError!void {
        self.lru_mutex.lock();
        defer self.lru_mutex.unlock();
        
        // Create new LRU node
        const node = try self.allocator.create(LRUNode);
        node.* = LRUNode{
            .page_id = page_id,
            .page_ptr = page,
            .prev = null,
            .next = null,
            .last_access_time = @intCast(std.time.milliTimestamp()),
            .access_count = 1,
        };
        
        // Add to front of LRU list (most recently used)
        self.lru_list.addToFront(node);
        
        // Add to hash map for quick lookup
        try self.lru_map.put(page_id, node);
    }
    
    /// Update LRU tracking when page is accessed
    fn updateLRUAccess(self: *Self, page_id: u32, page: *Page) void {
        _ = page; // unused in current implementation
        
        self.lru_mutex.lock();
        defer self.lru_mutex.unlock();
        
        if (self.lru_map.get(page_id)) |node| {
            // Update access time and count
            node.last_access_time = @intCast(std.time.milliTimestamp());
            node.access_count += 1;
            
            // Move to front of LRU list
            self.lru_list.moveToFront(node);
        }
    }
    
    fn readPageFromFile(self: *Self, file: *std.fs.File, page_id: u32, page: *Page) !void {
        _ = self; // unused
        
        // Calculate the offset for this page
        const offset = page_id * PAGE_SIZE;
        
        // Get file size to check if page exists
        const file_size = file.getEndPos() catch {
            // Can't get file size, assume file is invalid
            return error.FileNotOpen;
        };
        
        // If the offset is beyond the file size, the page doesn't exist yet
        if (offset >= file_size) {
            return error.IncompleteRead; // Caller will handle this as "new page"
        }
        
        file.seekTo(offset) catch {
            // Seek failed, likely because file is closed
            return error.FileNotOpen;
        };
        
        const bytes_read = file.readAll(&page.data) catch {
            // File read failed, likely because file is closed or page doesn't exist
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
        
        return .{
            .cache_hits = hits,
            .cache_misses = misses,
            .evictions = self.evictions.load(.monotonic),
            .write_backs = self.write_backs.load(.monotonic),
            .hit_ratio = hit_ratio,
            .pages_in_buffer = @as(u32, @intCast(self.pages.count())),
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