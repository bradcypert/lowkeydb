const std = @import("std");
const DatabaseError = @import("../error.zig").DatabaseError;

pub const PAGE_SIZE = 4096;
pub const MAGIC_NUMBER = "LOWKYDB\x00";

pub const PageType = enum(u8) {
    header = 0,
    btree_internal = 1,
    btree_leaf = 2,
    free = 3,
};

pub const PageHeader = struct {
    page_type: PageType,
    flags: u8,
    checksum: u32,
    lsn: u64, // Log sequence number for recovery
    reserved: [16]u8,
    
    const SIZE = @sizeOf(PageHeader);
};

pub const HeaderPage = struct {
    header: PageHeader,
    magic: [8]u8,
    version: u32,
    page_size: u32,
    root_page: u32,
    free_page_list: u32,
    page_count: u32,
    key_count: u64,
    // reserved space to fill the page (4096 - 32 - 40 = 4024)
    _reserved: [4024]u8,
    
    pub fn init() HeaderPage {
        var page = std.mem.zeroes(HeaderPage);
        page.header.page_type = .header;
        std.mem.copyForwards(u8, &page.magic, MAGIC_NUMBER);
        page.version = 1;
        page.page_size = PAGE_SIZE;
        page.root_page = 0; // No root initially
        page.free_page_list = 0;
        page.page_count = 1; // Just the header page
        page.key_count = 0;
        return page;
    }
    
    pub fn validate(self: *const HeaderPage) DatabaseError!void {
        if (!std.mem.eql(u8, &self.magic, MAGIC_NUMBER)) {
            return DatabaseError.InvalidMagicNumber;
        }
        if (self.version != 1) {
            return DatabaseError.UnsupportedVersion;
        }
        if (self.page_size != PAGE_SIZE) {
            return DatabaseError.InvalidPageSize;
        }
    }
};

pub const Page = struct {
    data: [PAGE_SIZE]u8,
    page_id: u32,
    lock: @import("../threading.zig").Threading.PageLock,
    
    // Note: is_dirty and pin_count are now managed by the PageLock
    // for thread safety. Legacy fields kept for compatibility during transition.
    is_dirty: bool,
    pin_count: u32,
    
    pub fn init(page_id: u32) Page {
        return Page{
            .data = std.mem.zeroes([PAGE_SIZE]u8),
            .page_id = page_id,
            .lock = @import("../threading.zig").Threading.PageLock.init(),
            .is_dirty = false,
            .pin_count = 0,
        };
    }
    
    /// Pin page for shared (read) access
    pub fn pinShared(self: *Page) void {
        self.lock.pinShared();
        // Update legacy field for compatibility
        self.pin_count = self.lock.pin_count.load(.acquire);
    }
    
    /// Pin page for exclusive (write) access
    pub fn pinExclusive(self: *Page) void {
        self.lock.pinExclusive();
        // Update legacy field for compatibility
        self.pin_count = self.lock.pin_count.load(.acquire);
    }
    
    /// Unpin page after shared access
    pub fn unpinShared(self: *Page) void {
        self.lock.unpinShared();
        // Update legacy field for compatibility
        self.pin_count = self.lock.pin_count.load(.acquire);
    }
    
    /// Unpin page after exclusive access
    pub fn unpinExclusive(self: *Page, dirty: bool) void {
        self.lock.unpinExclusive(dirty);
        // Update legacy fields for compatibility
        self.pin_count = self.lock.pin_count.load(.acquire);
        self.is_dirty = self.lock.isDirty();
    }
    
    /// Thread-safe check if page is pinned
    pub fn isPinned(self: *const Page) bool {
        return self.lock.isPinned();
    }
    
    /// Thread-safe check if page is dirty
    pub fn isDirtyAtomic(self: *const Page) bool {
        return self.lock.isDirty();
    }
    
    /// Clear dirty flag atomically
    pub fn clearDirty(self: *Page) void {
        self.lock.clearDirty();
        self.is_dirty = false; // Update legacy field
    }
    
    pub fn getHeader(self: *Page) *PageHeader {
        return @ptrCast(&self.data[0]);
    }
    
    pub fn getHeaderConst(self: *const Page) *const PageHeader {
        return @ptrCast(&self.data[0]);
    }
    
    pub fn getPayload(self: *Page) []u8 {
        return self.data[PageHeader.SIZE..];
    }
    
    pub fn getPayloadConst(self: *const Page) []const u8 {
        return self.data[PageHeader.SIZE..];
    }
    
    pub fn calculateChecksum(self: *const Page) u32 {
        // Simple CRC32 checksum of page data excluding the checksum field
        var crc = std.hash.Crc32.init();
        crc.update(self.data[0..4]); // page_type and flags
        crc.update(self.data[8..]); // everything after checksum field
        return crc.final();
    }
    
    pub fn updateChecksum(self: *Page) void {
        self.getHeader().checksum = self.calculateChecksum();
    }
    
    pub fn validateChecksum(self: *const Page) bool {
        const stored_checksum = self.getHeaderConst().checksum;
        return stored_checksum == self.calculateChecksum();
    }
};

// Note: HeaderPage size may vary, we'll handle it dynamically