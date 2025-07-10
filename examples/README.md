# LowkeyDB Examples

This directory contains example programs demonstrating various aspects of LowkeyDB usage and functionality.

## Core Examples

### `threading_test.zig`
A basic single-threaded example that demonstrates:
- Creating a database
- Inserting a key-value pair
- Retrieving and verifying the data
- Basic error handling

**Usage:**
```bash
cp examples/threading_test.zig .
zig build-exe threading_test.zig -I src/ --name threading_test
./threading_test
rm threading_test.zig threading_test
```

### `crud_operations_example.zig`
Comprehensive CRUD (Create, Read, Update, Delete) operations example:
- INSERT: Bulk data insertion with various data types
- READ: Reading individual keys and handling missing data
- UPDATE: Modifying existing records
- DELETE: Removing records and verification
- Bulk operations patterns
- Edge cases and error handling

### `transaction_example.zig`
Complete transaction system demonstration:
- Basic transaction lifecycle (begin, commit, rollback)
- Transactional operations (put, get, delete)
- Transaction rollback with data integrity verification
- Multiple concurrent transactions
- ACID properties demonstration

### `wal_example.zig`
Write-Ahead Logging (WAL) functionality showcase:
- WAL logging for durability
- Transaction logging and recovery
- Manual WAL checkpointing
- WAL flush operations
- Recovery simulation and statistics

### `concurrency_example.zig`
Advanced concurrency and performance demonstration:
- Multi-threaded operations with fine-grained locking
- Performance metrics and timing
- Data integrity verification under concurrent load
- Thread-safe operations across multiple threads
- Scalability testing

## Legacy Examples

### `concurrent_test.zig`
Multi-threaded test with 4 threads performing 10 operations each:
- Thread-safe insertions and retrievals
- Data integrity verification under concurrent access
- Proper resource cleanup

### `simple_concurrent_test.zig`
Simplified concurrent test for debugging:
- 2 threads with 2 operations each
- Detailed operation logging
- Useful for isolating concurrency issues

## Building Examples

Due to Zig's module system, examples need to be copied to the project root to build:

```bash
cp examples/example_name.zig .
zig build-exe example_name.zig -I src/ --name output_name
./output_name
rm example_name.zig output_name
```

The `-I src/` flag allows the examples to import the database modules correctly.

## Testing Multi-threading

The concurrent examples are particularly useful for:
- Verifying thread safety
- Testing data integrity under load
- Demonstrating proper resource management
- Benchmarking concurrent performance

## Notes

- Examples automatically clean up their test database files
- Each example includes error handling and proper resource cleanup
- The concurrent tests use unique key patterns to avoid conflicts
- All examples use the same allocator pattern for consistency