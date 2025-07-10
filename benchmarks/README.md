# LowkeyDB Benchmarks

This directory contains performance benchmarks and stress tests for LowkeyDB.

## Benchmark Types

### Performance Benchmarks
- **`performance_benchmark.zig`**: Core CRUD operation performance testing
- **`concurrent_benchmark.zig`**: Multi-threaded performance testing
- **`transaction_benchmark.zig`**: Transaction performance across isolation levels

### Stress Tests
- **`transaction_stress_test.zig`**: Heavy transaction workload testing
- **`checkpoint_stress_test.zig`**: Checkpoint thread under load
- **`statistics_validation.zig`**: Statistics accuracy under concurrent operations

### Integration Tests
- **`cli_integration_test.zig`**: Automated CLI command testing
- **`recovery_test.zig`**: WAL recovery and data integrity testing

## Running Benchmarks

### Individual Benchmarks
```bash
# Performance benchmark
cp benchmarks/performance_benchmark.zig . && zig build-exe performance_benchmark.zig -I src/
./performance_benchmark

# Concurrent benchmark
cp benchmarks/concurrent_benchmark.zig . && zig build-exe concurrent_benchmark.zig -I src/
./concurrent_benchmark

# Transaction benchmark
cp benchmarks/transaction_benchmark.zig . && zig build-exe transaction_benchmark.zig -I src/
./transaction_benchmark
```

### Stress Tests
```bash
# Transaction stress test
cp benchmarks/transaction_stress_test.zig . && zig build-exe transaction_stress_test.zig -I src/
./transaction_stress_test

# Checkpoint stress test
cp benchmarks/checkpoint_stress_test.zig . && zig build-exe checkpoint_stress_test.zig -I src/
./checkpoint_stress_test
```

### All Benchmarks
```bash
# Run the benchmark suite
./benchmarks/run_all_benchmarks.sh
```

## Expected Performance

Based on the current implementation, expected performance characteristics:

- **Single-threaded CRUD**: >10,000 ops/sec
- **Multi-threaded CRUD**: >5,000 ops/sec per thread
- **Transaction throughput**: >1,000 transactions/sec
- **Buffer pool hit ratio**: >90% with sufficient memory
- **Recovery time**: <1 second for typical workloads

## Interpreting Results

### Key Metrics
- **Throughput**: Operations per second
- **Latency**: Average operation time (microseconds)
- **Cache Hit Ratio**: Buffer pool efficiency
- **Memory Usage**: Peak memory consumption
- **Recovery Time**: Time to replay WAL on startup

### Performance Factors
- **Buffer Pool Size**: Larger pools improve performance
- **Checkpoint Frequency**: More frequent checkpoints reduce recovery time
- **Isolation Level**: Higher isolation has performance cost
- **Concurrent Threads**: Optimal concurrency depends on hardware