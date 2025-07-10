const std = @import("std");
const Page = @import("page.zig").Page;
const PageHeader = @import("page.zig").PageHeader;
const PageType = @import("page.zig").PageType;
const PAGE_SIZE = @import("page.zig").PAGE_SIZE;
const DatabaseError = @import("../error.zig").DatabaseError;

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const SplitResult = struct {
    promotion_key: []u8,
    new_page_id: u32,
};

pub const BTreeInternalPage = struct {
    header: PageHeader,
    key_count: u16,
    children: [MAX_INTERNAL_KEYS + 1]u32, // Page IDs of children
    keys: [MAX_INTERNAL_KEYS]KeyEntry,

    const KeyEntry = struct {
        length: u16,
        data: [MAX_KEY_SIZE]u8,

        const MAX_KEY_SIZE = 64; // Reasonable max key size
    };

    // Calculate max keys without self-reference
    const FIXED_SIZE = @sizeOf(PageHeader) + @sizeOf(u16); // header + key_count
    const MAX_INTERNAL_KEYS = (PAGE_SIZE - FIXED_SIZE - @sizeOf(u32)) / (@sizeOf(KeyEntry) + @sizeOf(u32));

    pub fn init(page: *Page) *BTreeInternalPage {
        const btree_page: *BTreeInternalPage = @ptrCast(@alignCast(&page.data));
        btree_page.header.page_type = .btree_internal;
        btree_page.key_count = 0;
        return btree_page;
    }

    pub fn insertKey(self: *BTreeInternalPage, key: []const u8, child_page_id: u32) DatabaseError!void {
        if (self.key_count >= MAX_INTERNAL_KEYS) {
            return DatabaseError.InternalError; // Page is full, needs splitting
        }

        if (key.len > KeyEntry.MAX_KEY_SIZE) {
            return DatabaseError.KeyTooLarge;
        }

        // Find insertion position
        var insert_pos: usize = 0;
        while (insert_pos < self.key_count) {
            const existing_key = self.getKey(insert_pos);
            if (std.mem.order(u8, key, existing_key) == .lt) {
                break;
            }
            insert_pos += 1;
        }

        // Shift keys and children to make room
        var i = self.key_count;
        while (i > insert_pos) {
            self.keys[i] = self.keys[i - 1];
            self.children[i + 1] = self.children[i];
            i -= 1;
        }

        // Insert new key and child
        self.keys[insert_pos].length = @intCast(key.len);
        std.mem.copyForwards(u8, self.keys[insert_pos].data[0..key.len], key);
        self.children[insert_pos + 1] = child_page_id;
        self.key_count += 1;
    }

    pub fn getKey(self: *const BTreeInternalPage, index: usize) []const u8 {
        if (index >= self.key_count) return &[_]u8{};
        return self.keys[index].data[0..self.keys[index].length];
    }

    pub fn findChild(self: *const BTreeInternalPage, key: []const u8) u32 {
        var i: usize = 0;
        while (i < self.key_count) {
            const page_key = self.getKey(i);
            if (std.mem.order(u8, key, page_key) == .lt) {
                return self.children[i];
            }
            i += 1;
        }
        return self.children[self.key_count];
    }
    
    /// Check if this internal page is full
    pub fn isFull(self: *const BTreeInternalPage) bool {
        return self.key_count >= MAX_INTERNAL_KEYS;
    }
    
    /// Split this internal page when it becomes full
    pub fn split(self: *BTreeInternalPage, allocator: std.mem.Allocator, new_page: *BTreeInternalPage) !SplitResult {
        if (self.key_count < 2) {
            return DatabaseError.InternalError; // Can't split page with < 2 keys
        }
        
        const split_point = self.key_count / 2;
        const promotion_index = split_point;
        
        // Get the promotion key (middle key goes up to parent)
        const promotion_key = try allocator.dupe(u8, self.getKey(promotion_index));
        
        // Copy right half to new page (excluding promotion key)
        var new_key_count: u16 = 0;
        for (promotion_index + 1..self.key_count) |i| {
            new_page.keys[new_key_count] = self.keys[i];
            new_page.children[new_key_count] = self.children[i];
            new_key_count += 1;
        }
        // Don't forget the last child pointer
        new_page.children[new_key_count] = self.children[self.key_count];
        new_page.key_count = new_key_count;
        
        // Truncate this page to left half (excluding promotion key)
        self.key_count = @intCast(promotion_index);
        
        return SplitResult{
            .promotion_key = promotion_key,
            .new_page_id = 0, // Will be set by caller
        };
    }
    
    /// Check if this internal page is underfull and needs merging
    pub fn isUnderfull(self: *const BTreeInternalPage) bool {
        // Internal pages need at least (MAX_INTERNAL_KEYS / 2) keys
        // Exception: root can have as few as 1 key
        const min_keys = MAX_INTERNAL_KEYS / 2;
        return self.key_count < min_keys;
    }
    
    /// Check if this internal page is completely empty
    pub fn isEmpty(self: *const BTreeInternalPage) bool {
        return self.key_count == 0;
    }
    
    /// Check if this page can donate a key to a sibling
    pub fn canDonateKey(self: *const BTreeInternalPage) bool {
        const min_keys = MAX_INTERNAL_KEYS / 2;
        return self.key_count > min_keys;
    }
    
    /// Check if two internal pages can be merged
    pub fn canMergeWith(self: *const BTreeInternalPage, sibling: *const BTreeInternalPage) bool {
        // Need space for all keys plus one separator key from parent
        return self.key_count + sibling.key_count + 1 <= MAX_INTERNAL_KEYS;
    }
};

pub const BTreeLeafPage = struct {
    header: PageHeader,
    key_count: u16,
    next_leaf: u32, // Page ID of next leaf page
    free_space: u16, // Offset to free space
    slots: [MAX_SLOTS]SlotEntry,
    // Variable-length data follows

    const MAX_SLOTS = (PAGE_SIZE - @sizeOf(PageHeader) - @sizeOf(u16) - @sizeOf(u32) - @sizeOf(u16)) / @sizeOf(SlotEntry) / 2;

    const SlotEntry = struct {
        offset: u16,
        key_length: u16,
        value_length: u16,

        const SIZE = @sizeOf(SlotEntry);
    };

    pub fn init(page: *Page) *BTreeLeafPage {
        const btree_page: *BTreeLeafPage = @ptrCast(@alignCast(&page.data));
        btree_page.header.page_type = .btree_leaf;
        btree_page.key_count = 0;
        btree_page.next_leaf = 0;
        // Initialize free_space to end of the page (data grows down from PAGE_SIZE)
        btree_page.free_space = PAGE_SIZE;
        return btree_page;
    }

    pub fn insertKeyValue(self: *BTreeLeafPage, key: []const u8, value: []const u8) DatabaseError!void {
        const total_size = key.len + value.len;
        const required_space = total_size + SlotEntry.SIZE;

        if (self.getFreeSpace() < required_space) {
            return DatabaseError.InternalError; // Page is full
        }

        if (self.key_count >= MAX_SLOTS) {
            return DatabaseError.InternalError; // Too many keys
        }

        // Find insertion position
        var insert_pos: usize = 0;
        while (insert_pos < self.key_count) {
            const existing_key = self.getKey(insert_pos);
            const cmp = std.mem.order(u8, key, existing_key);
            if (cmp == .lt) {
                break;
            } else if (cmp == .eq) {
                // Update existing key
                return self.updateKeyValue(insert_pos, value);
            }
            insert_pos += 1;
        }

        // Find the correct position for data (must not overwrite existing data)
        const data_offset = self.findDataOffset(total_size);

        if (data_offset == 0) {
            return DatabaseError.InternalError; // Could not find space
        }

        // Update free_space to be the minimum of current free_space and new data position
        self.free_space = @min(self.free_space, data_offset);

        // Shift slots to make room for new slot
        var i = self.key_count;
        while (i > insert_pos) {
            self.slots[i] = self.slots[i - 1];
            i -= 1;
        }

        // Insert new slot
        self.slots[insert_pos] = SlotEntry{
            .offset = data_offset,
            .key_length = @intCast(key.len),
            .value_length = @intCast(value.len),
        };

        // Copy key-value data
        const page_ptr: [*]u8 = @ptrCast(self);
        std.mem.copyForwards(u8, page_ptr[data_offset .. data_offset + key.len], key);
        std.mem.copyForwards(u8, page_ptr[data_offset + key.len .. data_offset + total_size], value);

        self.key_count += 1;
    }

    pub fn getKey(self: *const BTreeLeafPage, index: usize) []const u8 {
        if (index >= self.key_count) return &[_]u8{};
        const slot = self.slots[index];
        const page_ptr: [*]const u8 = @ptrCast(self);
        return page_ptr[slot.offset .. slot.offset + slot.key_length];
    }

    pub fn getValue(self: *const BTreeLeafPage, index: usize) []const u8 {
        if (index >= self.key_count) return &[_]u8{};
        const slot = self.slots[index];
        const page_ptr: [*]const u8 = @ptrCast(self);
        const value_offset = slot.offset + slot.key_length;
        return page_ptr[value_offset .. value_offset + slot.value_length];
    }

    pub fn findKey(self: *const BTreeLeafPage, key: []const u8) ?usize {
        var left: usize = 0;
        var right: usize = self.key_count;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const page_key = self.getKey(mid);

            switch (std.mem.order(u8, key, page_key)) {
                .lt => right = mid,
                .gt => left = mid + 1,
                .eq => return mid,
            }
        }

        return null;
    }

    pub fn deleteKey(self: *BTreeLeafPage, key: []const u8) bool {
        const index = self.findKey(key) orelse return false;

        const slot = self.slots[index];
        const total_size = slot.key_length + slot.value_length;

        // Shift remaining slots
        var i = index;
        while (i < self.key_count - 1) {
            self.slots[i] = self.slots[i + 1];
            i += 1;
        }

        self.key_count -= 1;
        self.free_space += total_size;

        // Compact page if fragmentation is significant
        if (self.shouldCompact()) {
            self.compactPage();
        }
        
        return true;
    }

    fn updateKeyValue(self: *BTreeLeafPage, index: usize, new_value: []const u8) DatabaseError!void {
        // For thread safety and to avoid recursive calls, we'll reject updates for now
        // In a production system, you'd implement proper in-place updates or
        // use a passed-in allocator instead of the global page allocator
        _ = self;
        _ = index;
        _ = new_value;
        return DatabaseError.InvalidOperation;
    }

    /// Find a safe offset for new data that doesn't overwrite existing data
    fn findDataOffset(self: *const BTreeLeafPage, size: usize) u16 {
        // Calculate the minimum offset where slots end
        const header_size = @sizeOf(PageHeader) + @sizeOf(u16) + @sizeOf(u32) + @sizeOf(u16);
        const slots_size = (self.key_count + 1) * @sizeOf(SlotEntry); // +1 for the new slot
        const min_offset = header_size + slots_size;

        // Start searching from the top of the page and work downwards
        var candidate_offset: u16 = PAGE_SIZE;

        if (candidate_offset < size) {
            return 0; // Page is definitely too small
        }

        candidate_offset -= @intCast(size);

        // Find the highest available position that doesn't conflict
        while (candidate_offset >= min_offset) {
            if (!self.conflictsWithExistingData(candidate_offset, size)) {
                return candidate_offset;
            }

            if (candidate_offset == 0) break;
            candidate_offset -= 1;
        }

        return 0; // Could not find suitable space
    }

    /// Check if a data region conflicts with existing data
    fn conflictsWithExistingData(self: *const BTreeLeafPage, offset: u16, size: usize) bool {
        const region_start = offset;
        const region_end = offset + @as(u16, @intCast(size));

        // Check against all existing slots
        for (0..self.key_count) |i| {
            const slot = self.slots[i];
            const existing_start = slot.offset;
            const existing_end = slot.offset + slot.key_length + slot.value_length;

            // Check for overlap
            if (!(region_end <= existing_start or region_start >= existing_end)) {
                return true; // Overlap detected
            }
        }

        return false; // No conflict
    }

    fn getFreeSpace(self: *const BTreeLeafPage) usize {
        // Calculate space used by slots (growing up from header)
        const slots_size = self.key_count * @sizeOf(SlotEntry);
        const header_size = @sizeOf(PageHeader) + @sizeOf(u16) + @sizeOf(u32) + @sizeOf(u16); // header + key_count + next_leaf + free_space

        // Calculate space used by data by finding the lowest data offset
        var lowest_data_offset: u16 = PAGE_SIZE;
        for (0..self.key_count) |i| {
            const slot = self.slots[i];
            if (slot.offset < lowest_data_offset) {
                lowest_data_offset = slot.offset;
            }
        }

        // Free space is between the end of slots and the start of data
        const slots_end = header_size + slots_size;
        const data_start = lowest_data_offset;

        return if (data_start > slots_end) data_start - slots_end else 0;
    }
    
    /// Split this leaf page when it becomes full
    /// Returns the key that should be promoted to the parent and the new page ID
    pub fn split(self: *BTreeLeafPage, allocator: std.mem.Allocator, new_page: *BTreeLeafPage) !SplitResult {
        if (self.key_count < 2) {
            return DatabaseError.InternalError; // Can't split page with < 2 keys
        }
        
        const split_point = self.key_count / 2;
        
        // Copy second half of keys to new page
        for (split_point..self.key_count) |i| {
            const key = self.getKey(i);
            const value = self.getValue(i);
            
            try new_page.insertKeyValue(key, value);
        }
        
        // Get the first key of the new page (promotion key)
        const promotion_key = try allocator.dupe(u8, new_page.getKey(0));
        
        // Update next pointers for leaf linking
        new_page.next_leaf = self.next_leaf;
        // self.next_leaf will be set by caller to point to new_page
        
        // Truncate this page to only contain the first half
        self.key_count = @intCast(split_point);
        
        // Recalculate free space (simplified - in production you'd compact)
        self.free_space = PAGE_SIZE;
        
        return SplitResult{
            .promotion_key = promotion_key,
            .new_page_id = 0, // Will be set by caller
        };
    }
    
    /// Check if this page needs to be split for a new insertion
    pub fn needsSplit(self: *const BTreeLeafPage, key: []const u8, value: []const u8) bool {
        const total_size = key.len + value.len;
        const required_space = total_size + SlotEntry.SIZE;
        return self.getFreeSpace() < required_space;
    }
    
    /// Check if this page is underfull and needs merging or redistribution
    pub fn isUnderfull(self: *const BTreeLeafPage) bool {
        // A page is underfull if it has less than half the maximum keys
        // Exception: root page can have any number of keys (minimum 1)
        const min_keys = MAX_SLOTS / 2;
        return self.key_count < min_keys;
    }
    
    /// Check if this page is completely empty
    pub fn isEmpty(self: *const BTreeLeafPage) bool {
        return self.key_count == 0;
    }
    
    /// Check if this page can donate a key to a sibling (has more than minimum)
    pub fn canDonateKey(self: *const BTreeLeafPage) bool {
        const min_keys = MAX_SLOTS / 2;
        return self.key_count > min_keys;
    }
    
    /// Check if two pages can be merged (combined keys < max capacity)
    pub fn canMergeWith(self: *const BTreeLeafPage, sibling: *const BTreeLeafPage) bool {
        return self.key_count + sibling.key_count <= MAX_SLOTS;
    }
    
    /// Check if page should be compacted to reclaim fragmented space
    fn shouldCompact(self: *const BTreeLeafPage) bool {
        if (self.key_count == 0) return false;
        
        // Calculate actual free space vs theoretical free space
        const theoretical_free = self.getFreeSpace();
        const actual_free = self.calculateActualFreeSpace();
        
        // Compact if more than 25% of space is fragmented
        if (theoretical_free > 0) {
            const fragmentation_ratio = (theoretical_free - actual_free) * 100 / theoretical_free;
            return fragmentation_ratio > 25;
        }
        
        return false;
    }
    
    /// Calculate the actual contiguous free space available
    fn calculateActualFreeSpace(self: *const BTreeLeafPage) usize {
        // Find the true end of slots and start of data
        const header_size = @sizeOf(PageHeader) + @sizeOf(u16) + @sizeOf(u32) + @sizeOf(u16);
        const slots_end = header_size + (self.key_count * @sizeOf(SlotEntry));
        
        // Find the lowest data offset
        var lowest_data_offset: u16 = PAGE_SIZE;
        for (0..self.key_count) |i| {
            const slot = self.slots[i];
            if (slot.offset < lowest_data_offset) {
                lowest_data_offset = slot.offset;
            }
        }
        
        return if (lowest_data_offset > slots_end) lowest_data_offset - slots_end else 0;
    }
    
    /// Compact the page by moving all data to eliminate gaps
    fn compactPage(self: *BTreeLeafPage) void {
        if (self.key_count == 0) return;
        
        // Create a temporary buffer for compacted data
        var temp_data: [PAGE_SIZE]u8 = undefined;
        var write_offset: u16 = PAGE_SIZE;
        
        // Sort slots by their current data offset (highest to lowest)
        // This ensures we pack data from top of page downward
        var slot_indices: [MAX_SLOTS]usize = undefined;
        for (0..self.key_count) |i| {
            slot_indices[i] = i;
        }
        
        // Simple bubble sort by offset (descending)
        for (0..self.key_count) |i| {
            for (i + 1..self.key_count) |j| {
                if (self.slots[slot_indices[i]].offset < self.slots[slot_indices[j]].offset) {
                    const temp = slot_indices[i];
                    slot_indices[i] = slot_indices[j];
                    slot_indices[j] = temp;
                }
            }
        }
        
        // Copy data in order, eliminating gaps
        const page_ptr: [*]u8 = @ptrCast(self);
        for (0..self.key_count) |i| {
            const slot_idx = slot_indices[i];
            const slot = &self.slots[slot_idx];
            const data_size = slot.key_length + slot.value_length;
            
            // Calculate new offset
            write_offset -= data_size;
            
            // Copy data from old location to new compacted location
            const old_data = page_ptr[slot.offset..slot.offset + data_size];
            std.mem.copyForwards(u8, temp_data[write_offset..write_offset + data_size], old_data);
            
            // Update slot to point to new location
            slot.offset = write_offset;
        }
        
        // Copy compacted data back to page
        std.mem.copyForwards(u8, page_ptr[write_offset..PAGE_SIZE], temp_data[write_offset..PAGE_SIZE]);
        
        // Update free_space pointer to new data start
        self.free_space = write_offset;
    }
};

comptime {
    // Ensure our structures fit within a page
    std.debug.assert(@sizeOf(BTreeInternalPage) <= PAGE_SIZE);
    std.debug.assert(@sizeOf(BTreeLeafPage) <= PAGE_SIZE);
}
