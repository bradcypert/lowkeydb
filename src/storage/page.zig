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
        return @ptrCast(@alignCast(&self.data[0]));
    }
    
    pub fn getHeaderConst(self: *const Page) *const PageHeader {
        return @ptrCast(@alignCast(&self.data[0]));
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
        // First set checksum to 0, then calculate
        self.getHeader().checksum = 0;
        self.getHeader().checksum = self.calculateChecksum();
    }
    
    pub fn validateChecksum(self: *const Page) bool {
        const stored_checksum = self.getHeaderConst().checksum;
        // Create a temporary copy to calculate checksum with checksum field = 0
        var temp_page = self.*;
        temp_page.getHeader().checksum = 0;
        return stored_checksum == temp_page.calculateChecksum();
    }
};

// Note: HeaderPage size may vary, we'll handle it dynamically

// Comprehensive test suite for page.zig
test "Page initialization" {
    const page = Page.init(42);
    
    // Test initial values
    try std.testing.expect(page.page_id == 42);
    try std.testing.expect(!page.isPinned());
    try std.testing.expect(!page.isDirtyAtomic());
    try std.testing.expect(page.is_dirty == false);
    try std.testing.expect(page.pin_count == 0);
    
    // Test data is zeroed
    for (page.data) |byte| {
        try std.testing.expect(byte == 0);
    }
}

test "Page pin/unpin shared access" {
    var page = Page.init(1);
    
    // Test initial state
    try std.testing.expect(!page.isPinned());
    try std.testing.expect(page.pin_count == 0);
    
    // Test shared pin
    page.pinShared();
    try std.testing.expect(page.isPinned());
    try std.testing.expect(page.pin_count == 1);
    
    // Test multiple shared pins
    page.pinShared();
    try std.testing.expect(page.isPinned());
    try std.testing.expect(page.pin_count == 2);
    
    // Test shared unpins
    page.unpinShared();
    try std.testing.expect(page.isPinned());
    try std.testing.expect(page.pin_count == 1);
    
    page.unpinShared();
    try std.testing.expect(!page.isPinned());
    try std.testing.expect(page.pin_count == 0);
}

test "Page pin/unpin exclusive access" {
    var page = Page.init(2);
    
    // Test exclusive pin
    page.pinExclusive();
    try std.testing.expect(page.isPinned());
    try std.testing.expect(page.pin_count == 1);
    
    // Test exclusive unpin without dirty
    page.unpinExclusive(false);
    try std.testing.expect(!page.isPinned());
    try std.testing.expect(!page.isDirtyAtomic());
    try std.testing.expect(!page.is_dirty);
    
    // Test exclusive unpin with dirty
    page.pinExclusive();
    page.unpinExclusive(true);
    try std.testing.expect(!page.isPinned());
    try std.testing.expect(page.isDirtyAtomic());
    try std.testing.expect(page.is_dirty);
}

test "Page dirty flag management" {
    var page = Page.init(3);
    
    // Test initial clean state
    try std.testing.expect(!page.isDirtyAtomic());
    try std.testing.expect(!page.is_dirty);
    
    // Test setting dirty through exclusive unpin
    page.pinExclusive();
    page.unpinExclusive(true);
    try std.testing.expect(page.isDirtyAtomic());
    try std.testing.expect(page.is_dirty);
    
    // Test clearing dirty flag
    page.clearDirty();
    try std.testing.expect(!page.isDirtyAtomic());
    try std.testing.expect(!page.is_dirty);
}

test "Page header and payload access" {
    var page = Page.init(4);
    
    // Test header access
    const header = page.getHeader();
    header.page_type = .btree_leaf;
    header.flags = 0x01;
    header.lsn = 12345;
    
    // Test const header access
    const const_header = page.getHeaderConst();
    try std.testing.expect(const_header.page_type == .btree_leaf);
    try std.testing.expect(const_header.flags == 0x01);
    try std.testing.expect(const_header.lsn == 12345);
    
    // Test payload access
    const payload = page.getPayload();
    try std.testing.expect(payload.len == PAGE_SIZE - PageHeader.SIZE);
    
    // Test const payload access
    const const_payload = page.getPayloadConst();
    try std.testing.expect(const_payload.len == PAGE_SIZE - PageHeader.SIZE);
    
    // Test writing to payload
    payload[0] = 0xFF;
    payload[1] = 0xAA;
    try std.testing.expect(const_payload[0] == 0xFF);
    try std.testing.expect(const_payload[1] == 0xAA);
}

test "Page checksum calculation and validation" {
    var page = Page.init(5);
    
    // Set some data in the page
    const header = page.getHeader();
    header.page_type = .btree_internal;
    header.flags = 0x42;
    header.lsn = 67890;
    header.checksum = 0; // Initialize checksum to known value
    
    const payload = page.getPayload();
    payload[0] = 0x11;
    payload[1] = 0x22;
    payload[100] = 0x33;
    
    // Calculate checksum manually first
    const calculated_checksum = page.calculateChecksum();
    
    // Set the checksum
    page.updateChecksum();
    
    // Verify checksum is valid
    try std.testing.expect(page.validateChecksum());
    try std.testing.expect(header.checksum == calculated_checksum);
    
    // Modify data and verify checksum becomes invalid
    payload[0] = 0x99;
    try std.testing.expect(!page.validateChecksum());
    
    // Recalculate checksum after modification
    page.updateChecksum();
    try std.testing.expect(page.validateChecksum());
    
    // Verify the checksum changed
    try std.testing.expect(header.checksum != calculated_checksum);
}

test "HeaderPage initialization and validation" {
    var header_page = HeaderPage.init();
    
    // Test initial values
    try std.testing.expect(header_page.header.page_type == .header);
    try std.testing.expectEqualStrings(MAGIC_NUMBER, &header_page.magic);
    try std.testing.expect(header_page.version == 1);
    try std.testing.expect(header_page.page_size == PAGE_SIZE);
    try std.testing.expect(header_page.root_page == 0);
    try std.testing.expect(header_page.free_page_list == 0);
    try std.testing.expect(header_page.page_count == 1);
    try std.testing.expect(header_page.key_count == 0);
    
    // Test validation passes
    try header_page.validate();
    
    // Test invalid magic number
    header_page.magic[0] = 'X';
    try std.testing.expectError(DatabaseError.InvalidMagicNumber, header_page.validate());
    
    // Reset magic and test invalid version
    std.mem.copyForwards(u8, &header_page.magic, MAGIC_NUMBER);
    header_page.version = 2;
    try std.testing.expectError(DatabaseError.UnsupportedVersion, header_page.validate());
    
    // Reset version and test invalid page size
    header_page.version = 1;
    header_page.page_size = 8192;
    try std.testing.expectError(DatabaseError.InvalidPageSize, header_page.validate());
}

test "PageType enum" {
    // Test all page type values
    try std.testing.expect(@intFromEnum(PageType.header) == 0);
    try std.testing.expect(@intFromEnum(PageType.btree_internal) == 1);
    try std.testing.expect(@intFromEnum(PageType.btree_leaf) == 2);
    try std.testing.expect(@intFromEnum(PageType.free) == 3);
}

test "PageHeader structure" {
    var header = std.mem.zeroes(PageHeader);
    
    // Test setting values
    header.page_type = .btree_leaf;
    header.flags = 0xFF;
    header.checksum = 0x12345678;
    header.lsn = 0xABCDEF1234567890;
    
    // Test values are preserved
    try std.testing.expect(header.page_type == .btree_leaf);
    try std.testing.expect(header.flags == 0xFF);
    try std.testing.expect(header.checksum == 0x12345678);
    try std.testing.expect(header.lsn == 0xABCDEF1234567890);
    
    // Test reserved area is initially zero
    for (header.reserved) |byte| {
        try std.testing.expect(byte == 0);
    }
}

test "Page constants and sizes" {
    // Test page size constant
    try std.testing.expect(PAGE_SIZE == 4096);
    
    // Test magic number
    try std.testing.expectEqualStrings("LOWKYDB\x00", MAGIC_NUMBER);
    
    // Test header size is reasonable
    try std.testing.expect(PageHeader.SIZE > 0);
    try std.testing.expect(PageHeader.SIZE < PAGE_SIZE);
    
    // Test HeaderPage fits in a page
    try std.testing.expect(@sizeOf(HeaderPage) <= PAGE_SIZE);
}

test "Page data manipulation" {
    var page = Page.init(100);
    
    // Test writing different patterns
    for (0..256) |i| {
        page.data[i] = @as(u8, @intCast(i & 0xFF));
    }
    
    // Verify pattern
    for (0..256) |i| {
        try std.testing.expect(page.data[i] == @as(u8, @intCast(i & 0xFF)));
    }
    
    // Test clearing data
    @memset(&page.data, 0);
    for (page.data) |byte| {
        try std.testing.expect(byte == 0);
    }
}

test "Multiple page instances" {
    var page1 = Page.init(1);
    var page2 = Page.init(2);
    var page3 = Page.init(3);
    
    // Test each page has correct ID
    try std.testing.expect(page1.page_id == 1);
    try std.testing.expect(page2.page_id == 2);
    try std.testing.expect(page3.page_id == 3);
    
    // Test pages are independent
    page1.data[0] = 0x11;
    page2.data[0] = 0x22;
    page3.data[0] = 0x33;
    
    try std.testing.expect(page1.data[0] == 0x11);
    try std.testing.expect(page2.data[0] == 0x22);
    try std.testing.expect(page3.data[0] == 0x33);
    
    // Test pin states are independent
    page1.pinShared();
    page2.pinExclusive();
    
    try std.testing.expect(page1.isPinned());
    try std.testing.expect(page2.isPinned());
    try std.testing.expect(!page3.isPinned());
}