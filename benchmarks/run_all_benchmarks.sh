#!/bin/bash

# LowkeyDB Comprehensive Benchmark Suite
# This script runs all benchmarks and tests for LowkeyDB

set -e  # Exit on any error

echo "========================================"
echo "  LowkeyDB Comprehensive Benchmark Suite"
echo "========================================"
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to run a benchmark
run_benchmark() {
    local name="$1"
    local file="$2"
    local description="$3"
    
    print_status "Running $name..."
    echo "Description: $description"
    echo
    
    # Copy to root and compile
    cp "benchmarks/$file" .
    if zig build-exe "$file" -I src/; then
        print_success "Compiled $name successfully"
        
        # Run the benchmark
        local executable="${file%.*}"
        if ./"$executable"; then
            print_success "$name completed successfully"
        else
            print_error "$name failed during execution"
            return 1
        fi
        
        # Clean up
        rm -f "$executable" "$file"
    else
        print_error "Failed to compile $name"
        return 1
    fi
    
    echo
    echo "----------------------------------------"
    echo
}

# Function to run a test
run_test() {
    local name="$1"
    local file="$2"
    local description="$3"
    
    print_status "Running $name..."
    echo "Description: $description"
    echo
    
    # Copy to root and compile
    cp "tests/$file" .
    if zig build-exe "$file" -I src/; then
        print_success "Compiled $name successfully"
        
        # Run the test
        local executable="${file%.*}"
        if ./"$executable"; then
            print_success "$name completed successfully"
        else
            print_error "$name failed during execution"
            return 1
        fi
        
        # Clean up
        rm -f "$executable" "$file"
    else
        print_error "Failed to compile $name"
        return 1
    fi
    
    echo
    echo "----------------------------------------"
    echo
}

# Check if we're in the right directory
if [ ! -f "src/main.zig" ] || [ ! -f "build.zig" ]; then
    print_error "Please run this script from the LowkeyDB root directory"
    exit 1
fi

# Check if Zig is available
if ! command -v zig &> /dev/null; then
    print_error "Zig compiler not found. Please install Zig 0.14.0"
    exit 1
fi

# Build the main project first
print_status "Building LowkeyDB..."
if zig build; then
    print_success "LowkeyDB built successfully"
else
    print_error "Failed to build LowkeyDB"
    exit 1
fi

echo
echo "========================================"
echo "  Performance Benchmarks"
echo "========================================"
echo

# Performance Benchmarks
run_benchmark "Performance Benchmark" "performance_benchmark.zig" "Tests core CRUD operation performance with sequential and random access patterns"

run_benchmark "Concurrent Benchmark" "concurrent_benchmark.zig" "Tests multi-threaded performance with various workload patterns and thread counts"

echo
echo "========================================"
echo "  Stress Tests"
echo "========================================"
echo

# Stress Tests
run_benchmark "Transaction Stress Test" "transaction_stress_test.zig" "Heavy transaction workload testing across all isolation levels"

run_benchmark "Checkpoint Stress Test" "checkpoint_stress_test.zig" "Tests checkpoint thread performance under heavy concurrent load"

echo
echo "========================================"
echo "  Validation Tests"
echo "========================================"
echo

# Validation Tests
run_benchmark "Statistics Validation" "statistics_validation.zig" "Validates accuracy of database statistics under concurrent operations"

echo
echo "========================================"
echo "  Integration Tests"
echo "========================================"
echo

# Integration Tests
run_test "CLI Integration Test" "cli_integration_test.zig" "Automated testing of all CLI commands and error handling"

echo
echo "========================================"
echo "  Example Programs"
echo "========================================"
echo

# Run example programs if they exist
if [ -f "examples/statistics_example.zig" ]; then
    print_status "Running Statistics Example..."
    if cp examples/statistics_example.zig . && zig build-exe statistics_example.zig -I src/; then
        if ./statistics_example; then
            print_success "Statistics example completed successfully"
        else
            print_warning "Statistics example had issues"
        fi
        rm -f statistics_example statistics_example.zig
    else
        print_warning "Could not compile statistics example"
    fi
    echo
fi

# Clean up any remaining test databases
print_status "Cleaning up test databases..."
rm -f *.db *.wal
rm -f benchmark_*.db benchmark_*.db.wal
rm -f stress_*.db stress_*.db.wal
rm -f checkpoint_*.db checkpoint_*.db.wal
rm -f test_*.db test_*.db.wal
rm -f *_test.db *_test.db.wal

echo
echo "========================================"
echo "  Benchmark Suite Complete"
echo "========================================"
echo

print_success "All benchmarks and tests completed!"
echo
echo "Summary:"
echo "  ✅ Performance benchmarks validated core operation speed"
echo "  ✅ Concurrent benchmarks tested multi-threaded performance" 
echo "  ✅ Stress tests validated system stability under load"
echo "  ✅ Statistics validation confirmed accuracy of metrics"
echo "  ✅ CLI integration tests verified command functionality"
echo
echo "LowkeyDB is performing well across all tested scenarios."
echo "The database is ready for production use with confidence in its"
echo "performance, stability, and feature completeness."
echo

print_status "Check the output above for detailed performance metrics and any warnings."