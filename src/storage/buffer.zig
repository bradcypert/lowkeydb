const std = @import("std");
const Page = @import("page.zig").Page;
const DatabaseError = @import("../error.zig").DatabaseError;
const Threading = @import("../threading.zig").Threading;

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
    write_backs: std.atomic.Value(u64)
    
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
            // Just mark as clean for now - proper file I/O will be implemented later
            page.clearDirty();
        }
    }
    
    pub fn flushAll(self: *Self) DatabaseError!void {
        self.pages.lockForIteration();
        defer self.pages.unlockAfterIteration();
        
        var iter = self.pages.iterator();
        while (iter.next()) |entry| {
            const page = entry.value_ptr.*;
            if (page.isDirtyAtomic()) {
                // Flush page directly without calling flushPage to avoid nested mutex acquisition
                page.clearDirty();
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
        _ = self; // unused
        // Simple eviction: just fail if at capacity
        // In a production system, this would implement proper LRU eviction
        return DatabaseError.OutOfMemory;
    }
    
    fn readPageFromFile(self: *Self, file: *std.fs.File, page_id: u32, page: *Page) !void {
        _ = self; // unused
        
        // Calculate the offset for this page
        const offset = page_id * @import("page.zig").PAGE_SIZE;
        
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
        
        if (bytes_read != @import("page.zig").PAGE_SIZE) {
            return error.IncompleteRead;
        }
        page.page_id = page_id;
        page.is_dirty = false;
        page.pin_count = 0;
    }
};