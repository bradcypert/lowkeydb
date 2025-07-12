# LowkeyDB Integration Guides

This directory contains comprehensive integration guides for using LowkeyDB with different programming languages and platforms.

## Available Guides

### [🦎 Zig Integration Guide](INTEGRATION_ZIG.md)
Complete guide for integrating LowkeyDB into Zig applications.
- **Installation**: Package manager, git submodule, and direct include methods
- **Features**: Full native API access, ACID transactions, concurrent operations
- **Performance**: >25,000 write ops/sec, excellent thread safety
- **Examples**: CLI tools, configuration managers, concurrent workers

**Best for**: Native Zig applications, system tools, high-performance services

### [🔧 C Integration Guide](INTEGRATION_C.md)
Comprehensive C API wrapper for maximum compatibility.
- **Installation**: Static/dynamic library compilation and linking
- **Features**: Complete C-compatible FFI, thread safety, error handling
- **Compatibility**: Works with C, C++, and any language with C FFI
- **Examples**: Key-value stores, configuration systems, embedded applications

**Best for**: C/C++ applications, embedded systems, language bindings

### [📱 Flutter/Dart Integration Guide](INTEGRATION_FLUTTER.md)
Advanced Flutter integration using Dart FFI for mobile and desktop apps.
- **Installation**: Multi-platform builds (Android, iOS, macOS, Windows, Linux)
- **Features**: Full Dart wrapper, async operations, state management integration
- **Mobile-optimized**: Background persistence, lifecycle management
- **Examples**: Mobile databases, offline-first apps, configuration management

**Best for**: Mobile apps, cross-platform desktop applications, Flutter projects

## Quick Comparison

| Language | Complexity | Performance | Platform Support | Best Use Case |
|----------|------------|-------------|------------------|---------------|
| **Zig** | ⭐ Simple | ⭐⭐⭐ Excellent | Linux, macOS, Windows | Native applications |
| **C** | ⭐⭐ Moderate | ⭐⭐⭐ Excellent | Universal | System integration |
| **Flutter** | ⭐⭐⭐ Complex | ⭐⭐ Very Good | Mobile + Desktop | Cross-platform apps |

## Key Features Across All Integrations

✅ **ACID Transactions** - Full transaction support with multiple isolation levels  
✅ **Thread Safety** - Fine-grained locking for optimal concurrency  
✅ **High Performance** - >25,000 write ops/sec, >50,000 read ops/sec  
✅ **Crash Recovery** - Write-ahead logging with automatic recovery  
✅ **Memory Efficient** - Configurable buffer pool with LRU eviction  
✅ **Production Ready** - Comprehensive error handling and monitoring  

## Getting Started

1. **Choose your language** from the guides above
2. **Follow the installation steps** for your target platform
3. **Try the quick start example** to verify everything works
4. **Explore advanced features** like transactions and monitoring
5. **Check the complete examples** for real-world usage patterns

## Performance Characteristics

LowkeyDB delivers consistent high performance across all integration methods:

- **Write Performance**: 25,000+ operations/second
- **Read Performance**: 50,000+ operations/second  
- **Concurrent Access**: Multiple threads with minimal contention
- **Memory Usage**: Configurable buffer pool (default 64MB)
- **Disk Usage**: Efficient B+ tree storage with compression
- **Recovery Time**: Fast startup with WAL replay (typically <1s)

## Architecture Overview

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Zig API       │    │     C API       │    │  Flutter FFI    │
│   (Native)      │    │   (FFI Layer)   │    │   (Dart Wrapper)│
└─────────┬───────┘    └─────────┬───────┘    └─────────┬───────┘
          │                      │                      │
          └──────────────────────┼──────────────────────┘
                                 │
                   ┌─────────────▼──────────────┐
                   │      LowkeyDB Core         │
                   │   (Zig Implementation)     │
                   │                            │
                   │ • ACID Transactions        │
                   │ • B+ Tree Storage          │
                   │ • WAL + Checkpointing      │
                   │ • Buffer Pool Management   │
                   │ • Fine-grained Locking     │
                   └────────────────────────────┘
```

## Support Matrix

| Feature | Zig | C | Flutter |
|---------|-----|---|---------|
| Basic CRUD | ✅ | ✅ | ✅ |
| Transactions | ✅ | ✅ | ✅ |
| Concurrent Access | ✅ | ✅ | ✅ |
| Statistics/Monitoring | ✅ | ✅ | ✅ |
| WAL Management | ✅ | ✅ | ✅ |
| Error Handling | ✅ | ✅ | ✅ |
| Memory Management | Manual | Manual | Automatic |
| Async Operations | Manual | Manual | Native |
| Platform Integration | Direct | Library | Framework |

## Contributing

We welcome contributions to improve these integration guides:

1. **Bug Reports**: If you find issues with any integration method
2. **Documentation**: Improvements to clarity, examples, or coverage
3. **New Examples**: Real-world usage patterns and best practices
4. **Platform Support**: Additional platform-specific guidance

## License

LowkeyDB and all integration guides are provided under the MIT License. See the main project LICENSE file for details.

---

For questions, issues, or contributions, please visit the [main LowkeyDB repository](https://github.com/bradcypert/lowkeydb).