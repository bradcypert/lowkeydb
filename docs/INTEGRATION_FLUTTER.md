# LowkeyDB Flutter/Dart Integration Guide

This guide shows you how to integrate LowkeyDB into your Flutter applications using Dart's Foreign Function Interface (FFI). LowkeyDB provides high-performance embedded database capabilities directly in your Flutter apps.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Project Setup](#project-setup)
- [Dart FFI Wrapper](#dart-ffi-wrapper)
- [Basic Usage](#basic-usage)
- [Advanced Features](#advanced-features)
- [Performance Optimization](#performance-optimization)
- [Complete Examples](#complete-examples)
- [Platform-Specific Considerations](#platform-specific-considerations)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Prerequisites

- **Flutter SDK** (3.0 or later)
- **Dart SDK** (2.17 or later)
- **Zig 0.14.0+** (for building the native library)
- **Android NDK** (for Android builds)
- **Xcode** (for iOS builds)

## Installation

### Step 1: Build Native Libraries

First, build LowkeyDB as dynamic libraries for each target platform:

```bash
# Clone LowkeyDB
git clone https://github.com/bradcypert/lowkeydb
cd lowkeydb

# Build for different platforms
# Android (ARM64)
zig build-lib src/c_api.zig -lc -target aarch64-linux-android --name lowkeydb -dynamic

# iOS (ARM64)
zig build-lib src/c_api.zig -lc -target aarch64-ios --name lowkeydb -dynamic

# macOS (Universal)
zig build-lib src/c_api.zig -lc -target aarch64-macos --name lowkeydb -dynamic
zig build-lib src/c_api.zig -lc -target x86_64-macos --name lowkeydb -dynamic

# Linux (x64)
zig build-lib src/c_api.zig -lc -target x86_64-linux --name lowkeydb -dynamic

# Windows (x64)
zig build-lib src/c_api.zig -lc -target x86_64-windows --name lowkeydb -dynamic
```

### Step 2: Create Flutter Project

```bash
flutter create lowkeydb_example
cd lowkeydb_example
```

### Step 3: Add Dependencies

Add to your `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  ffi: ^2.1.0
  path: ^1.8.3
  path_provider: ^2.1.1

dev_dependencies:
  flutter_test:
    sdk: flutter
  ffigen: ^11.0.0

ffigen:
  output: lib/lowkeydb_bindings.dart
  headers:
    entry-points:
      - ../lowkeydb/include/lowkeydb.h
  name: LowkeyDBBindings
  description: 'Bindings for LowkeyDB'
```

## Project Setup

### Directory Structure

```
your_flutter_app/
├── lib/
│   ├── lowkeydb_bindings.dart    # Generated FFI bindings
│   ├── lowkeydb_wrapper.dart     # Dart wrapper
│   └── main.dart
├── android/
│   └── app/src/main/jniLibs/
│       └── arm64-v8a/
│           └── liblowkeydb.so
├── ios/
│   └── Runner/
│       └── Frameworks/
│           └── liblowkeydb.dylib
├── macos/
│   └── Runner/
│       └── Frameworks/
│           └── liblowkeydb.dylib
├── windows/
│   └── runner/
│       └── lowkeydb.dll
└── linux/
    └── bundle/
        └── lib/
            └── liblowkeydb.so
```

### Step 4: Generate FFI Bindings

```bash
# Install ffigen
dart pub global activate ffigen

# Generate bindings
dart run ffigen
```

## Dart FFI Wrapper

Create `lib/lowkeydb_wrapper.dart`:

```dart
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'lowkeydb_bindings.dart';

class LowkeyDBException implements Exception {
  final String message;
  final int errorCode;
  
  LowkeyDBException(this.message, this.errorCode);
  
  @override
  String toString() => 'LowkeyDBException: $message (code: $errorCode)';
}

class LowkeyDBBufferStats {
  final int capacity;
  final int pagesInBuffer;
  final int cacheHits;
  final int cacheMisses;
  final double hitRatio;
  final int evictions;
  final int writebacks;
  
  LowkeyDBBufferStats({
    required this.capacity,
    required this.pagesInBuffer,
    required this.cacheHits,
    required this.cacheMisses,
    required this.hitRatio,
    required this.evictions,
    required this.writebacks,
  });
}

class LowkeyDBCheckpointStats {
  final int checkpointsPerformed;
  final int pagesWritten;
  final int walSize;
  final int lastCheckpointTime;
  
  LowkeyDBCheckpointStats({
    required this.checkpointsPerformed,
    required this.pagesWritten,
    required this.walSize,
    required this.lastCheckpointTime,
  });
}

enum IsolationLevel {
  readCommitted(0),
  repeatableRead(1),
  serializable(2);
  
  const IsolationLevel(this.value);
  final int value;
}

class LowkeyDB {
  static LowkeyDBBindings? _bindings;
  static DynamicLibrary? _library;
  
  Pointer<Pointer<NativeType>>? _dbHandle;
  bool _isOpen = false;
  
  static LowkeyDBBindings get bindings {
    if (_bindings == null) {
      _library = _loadLibrary();
      _bindings = LowkeyDBBindings(_library!);
    }
    return _bindings!;
  }
  
  static DynamicLibrary _loadLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('liblowkeydb.so');
    } else if (Platform.isIOS) {
      return DynamicLibrary.process();
    } else if (Platform.isMacOS) {
      return DynamicLibrary.open('liblowkeydb.dylib');
    } else if (Platform.isWindows) {
      return DynamicLibrary.open('lowkeydb.dll');
    } else if (Platform.isLinux) {
      return DynamicLibrary.open('liblowkeydb.so');
    } else {
      throw UnsupportedError('Platform ${Platform.operatingSystem} is not supported');
    }
  }
  
  /// Get the default database directory for the current platform
  static Future<String> getDefaultDatabaseDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final directory = await getApplicationDocumentsDirectory();
      return directory.path;
    } else {
      final directory = await getApplicationSupportDirectory();
      return directory.path;
    }
  }
  
  /// Create a new database
  static Future<LowkeyDB> create(String dbPath) async {
    final db = LowkeyDB._();
    await db._create(dbPath);
    return db;
  }
  
  /// Open an existing database
  static Future<LowkeyDB> open(String dbPath) async {
    final db = LowkeyDB._();
    await db._open(dbPath);
    return db;
  }
  
  LowkeyDB._();
  
  Future<void> _create(String dbPath) async {
    _dbHandle = calloc<Pointer<NativeType>>();
    
    final pathPtr = dbPath.toNativeUtf8();
    try {
      final result = bindings.lowkeydb_create(pathPtr.cast(), _dbHandle!);
      if (result != 0) {
        final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
        throw LowkeyDBException(errorMsg, result);
      }
      _isOpen = true;
    } finally {
      calloc.free(pathPtr);
    }
  }
  
  Future<void> _open(String dbPath) async {
    _dbHandle = calloc<Pointer<NativeType>>();
    
    final pathPtr = dbPath.toNativeUtf8();
    try {
      final result = bindings.lowkeydb_open(pathPtr.cast(), _dbHandle!);
      if (result != 0) {
        final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
        throw LowkeyDBException(errorMsg, result);
      }
      _isOpen = true;
    } finally {
      calloc.free(pathPtr);
    }
  }
  
  void _checkOpen() {
    if (!_isOpen) {
      throw LowkeyDBException('Database is not open', -1);
    }
  }
  
  /// Put a key-value pair
  Future<void> put(String key, String value) async {
    _checkOpen();
    
    final keyPtr = key.toNativeUtf8();
    final valuePtr = value.toNativeUtf8();
    
    try {
      final result = bindings.lowkeydb_put(_dbHandle!.value, keyPtr.cast(), valuePtr.cast());
      if (result != 0) {
        final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
        throw LowkeyDBException(errorMsg, result);
      }
    } finally {
      calloc.free(keyPtr);
      calloc.free(valuePtr);
    }
  }
  
  /// Get a value by key
  Future<String?> get(String key) async {
    _checkOpen();
    
    final keyPtr = key.toNativeUtf8();
    final valuePtr = calloc<Pointer<Char>>();
    final lengthPtr = calloc<Size>();
    
    try {
      final result = bindings.lowkeydb_get(_dbHandle!.value, keyPtr.cast(), valuePtr, lengthPtr);
      
      if (result == 0) {
        if (valuePtr.value != nullptr) {
          final value = valuePtr.value.cast<Utf8>().toDartString();
          bindings.lowkeydb_free(valuePtr.value.cast());
          return value;
        }
        return null;
      } else if (result == -4) { // LOWKEY_ERROR_KEY_NOT_FOUND
        return null;
      } else {
        final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
        throw LowkeyDBException(errorMsg, result);
      }
    } finally {
      calloc.free(keyPtr);
      calloc.free(valuePtr);
      calloc.free(lengthPtr);
    }
  }
  
  /// Delete a key
  Future<bool> delete(String key) async {
    _checkOpen();
    
    final keyPtr = key.toNativeUtf8();
    
    try {
      final result = bindings.lowkeydb_delete(_dbHandle!.value, keyPtr.cast());
      
      if (result == 0) {
        return true;
      } else if (result == -4) { // LOWKEY_ERROR_KEY_NOT_FOUND
        return false;
      } else {
        final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
        throw LowkeyDBException(errorMsg, result);
      }
    } finally {
      calloc.free(keyPtr);
    }
  }
  
  /// Get the number of keys in the database
  Future<int> keyCount() async {
    _checkOpen();
    return bindings.lowkeydb_key_count(_dbHandle!.value);
  }
  
  /// Begin a transaction
  Future<int> beginTransaction([IsolationLevel isolation = IsolationLevel.readCommitted]) async {
    _checkOpen();
    
    final txIdPtr = calloc<Uint64>();
    try {
      final result = bindings.lowkeydb_begin_transaction(_dbHandle!.value, isolation.value, txIdPtr);
      if (result != 0) {
        final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
        throw LowkeyDBException(errorMsg, result);
      }
      return txIdPtr.value;
    } finally {
      calloc.free(txIdPtr);
    }
  }
  
  /// Commit a transaction
  Future<void> commitTransaction(int txId) async {
    _checkOpen();
    
    final result = bindings.lowkeydb_commit_transaction(_dbHandle!.value, txId);
    if (result != 0) {
      final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
      throw LowkeyDBException(errorMsg, result);
    }
  }
  
  /// Rollback a transaction
  Future<void> rollbackTransaction(int txId) async {
    _checkOpen();
    
    final result = bindings.lowkeydb_rollback_transaction(_dbHandle!.value, txId);
    if (result != 0) {
      final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
      throw LowkeyDBException(errorMsg, result);
    }
  }
  
  /// Put a key-value pair within a transaction
  Future<void> putTransaction(int txId, String key, String value) async {
    _checkOpen();
    
    final keyPtr = key.toNativeUtf8();
    final valuePtr = value.toNativeUtf8();
    
    try {
      final result = bindings.lowkeydb_put_transaction(_dbHandle!.value, txId, keyPtr.cast(), valuePtr.cast());
      if (result != 0) {
        final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
        throw LowkeyDBException(errorMsg, result);
      }
    } finally {
      calloc.free(keyPtr);
      calloc.free(valuePtr);
    }
  }
  
  /// Get a value by key within a transaction
  Future<String?> getTransaction(int txId, String key) async {
    _checkOpen();
    
    final keyPtr = key.toNativeUtf8();
    final valuePtr = calloc<Pointer<Char>>();
    final lengthPtr = calloc<Size>();
    
    try {
      final result = bindings.lowkeydb_get_transaction(_dbHandle!.value, txId, keyPtr.cast(), valuePtr, lengthPtr);
      
      if (result == 0) {
        if (valuePtr.value != nullptr) {
          final value = valuePtr.value.cast<Utf8>().toDartString();
          bindings.lowkeydb_free(valuePtr.value.cast());
          return value;
        }
        return null;
      } else if (result == -4) { // LOWKEY_ERROR_KEY_NOT_FOUND
        return null;
      } else {
        final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
        throw LowkeyDBException(errorMsg, result);
      }
    } finally {
      calloc.free(keyPtr);
      calloc.free(valuePtr);
      calloc.free(lengthPtr);
    }
  }
  
  /// Delete a key within a transaction
  Future<bool> deleteTransaction(int txId, String key) async {
    _checkOpen();
    
    final keyPtr = key.toNativeUtf8();
    
    try {
      final result = bindings.lowkeydb_delete_transaction(_dbHandle!.value, txId, keyPtr.cast());
      
      if (result == 0) {
        return true;
      } else if (result == -4) { // LOWKEY_ERROR_KEY_NOT_FOUND
        return false;
      } else {
        final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
        throw LowkeyDBException(errorMsg, result);
      }
    } finally {
      calloc.free(keyPtr);
    }
  }
  
  /// Get buffer pool statistics
  Future<LowkeyDBBufferStats> getBufferStats() async {
    _checkOpen();
    
    final statsPtr = calloc<LowkeyDBBufferStats>();
    try {
      final result = bindings.lowkeydb_get_buffer_stats(_dbHandle!.value, statsPtr);
      if (result != 0) {
        final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
        throw LowkeyDBException(errorMsg, result);
      }
      
      final stats = statsPtr.ref;
      return LowkeyDBBufferStats(
        capacity: stats.capacity,
        pagesInBuffer: stats.pages_in_buffer,
        cacheHits: stats.cache_hits,
        cacheMisses: stats.cache_misses,
        hitRatio: stats.hit_ratio,
        evictions: stats.evictions,
        writebacks: stats.write_backs,
      );
    } finally {
      calloc.free(statsPtr);
    }
  }
  
  /// Get checkpoint statistics
  Future<LowkeyDBCheckpointStats> getCheckpointStats() async {
    _checkOpen();
    
    final statsPtr = calloc<LowkeyDBCheckpointStats>();
    try {
      final result = bindings.lowkeydb_get_checkpoint_stats(_dbHandle!.value, statsPtr);
      if (result != 0) {
        final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
        throw LowkeyDBException(errorMsg, result);
      }
      
      final stats = statsPtr.ref;
      return LowkeyDBCheckpointStats(
        checkpointsPerformed: stats.checkpoints_performed,
        pagesWritten: stats.pages_written,
        walSize: stats.wal_size,
        lastCheckpointTime: stats.last_checkpoint_time,
      );
    } finally {
      calloc.free(statsPtr);
    }
  }
  
  /// Configure automatic checkpointing
  void configureCheckpointing(int intervalMs, int maxWalSizeMb, int maxArchivedWals) {
    _checkOpen();
    bindings.lowkeydb_configure_checkpointing(_dbHandle!.value, intervalMs, maxWalSizeMb, maxArchivedWals);
  }
  
  /// Start automatic checkpointing
  Future<void> startAutoCheckpoint() async {
    _checkOpen();
    
    final result = bindings.lowkeydb_start_auto_checkpoint(_dbHandle!.value);
    if (result != 0) {
      final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
      throw LowkeyDBException(errorMsg, result);
    }
  }
  
  /// Stop automatic checkpointing
  void stopAutoCheckpoint() {
    _checkOpen();
    bindings.lowkeydb_stop_auto_checkpoint(_dbHandle!.value);
  }
  
  /// Perform manual checkpoint
  Future<void> checkpoint() async {
    _checkOpen();
    
    final result = bindings.lowkeydb_checkpoint(_dbHandle!.value);
    if (result != 0) {
      final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
      throw LowkeyDBException(errorMsg, result);
    }
  }
  
  /// Flush WAL to disk
  Future<void> flushWAL() async {
    _checkOpen();
    
    final result = bindings.lowkeydb_flush_wal(_dbHandle!.value);
    if (result != 0) {
      final errorMsg = bindings.lowkeydb_error_message(result).cast<Utf8>().toDartString();
      throw LowkeyDBException(errorMsg, result);
    }
  }
  
  /// Close the database
  void close() {
    if (_isOpen && _dbHandle != null) {
      bindings.lowkeydb_close(_dbHandle!.value);
      calloc.free(_dbHandle!);
      _dbHandle = null;
      _isOpen = false;
    }
  }
}
```

## Basic Usage

### Simple Example

Create `lib/main.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'lowkeydb_wrapper.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LowkeyDB Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: DatabaseDemo(),
    );
  }
}

class DatabaseDemo extends StatefulWidget {
  @override
  _DatabaseDemoState createState() => _DatabaseDemoState();
}

class _DatabaseDemoState extends State<DatabaseDemo> {
  LowkeyDB? _database;
  String _output = '';
  final _keyController = TextEditingController();
  final _valueController = TextEditingController();
  
  @override
  void initState() {
    super.initState();
    _initDatabase();
  }
  
  Future<void> _initDatabase() async {
    try {
      final dbDir = await LowkeyDB.getDefaultDatabaseDirectory();
      final dbPath = path.join(dbDir, 'demo.db');
      
      _database = await LowkeyDB.create(dbPath);
      
      setState(() {
        _output = 'Database initialized at: $dbPath';
      });
    } catch (e) {
      setState(() {
        _output = 'Error initializing database: $e';
      });
    }
  }
  
  Future<void> _putValue() async {
    if (_database == null) return;
    
    try {
      await _database!.put(_keyController.text, _valueController.text);
      final count = await _database!.keyCount();
      
      setState(() {
        _output = 'Stored: ${_keyController.text} = ${_valueController.text}\\nTotal keys: $count';
      });
      
      _keyController.clear();
      _valueController.clear();
    } catch (e) {
      setState(() {
        _output = 'Error storing value: $e';
      });
    }
  }
  
  Future<void> _getValue() async {
    if (_database == null) return;
    
    try {
      final value = await _database!.get(_keyController.text);
      
      setState(() {
        if (value != null) {
          _output = 'Retrieved: ${_keyController.text} = $value';
        } else {
          _output = 'Key not found: ${_keyController.text}';
        }
      });
    } catch (e) {
      setState(() {
        _output = 'Error retrieving value: $e';
      });
    }
  }
  
  Future<void> _deleteValue() async {
    if (_database == null) return;
    
    try {
      final deleted = await _database!.delete(_keyController.text);
      final count = await _database!.keyCount();
      
      setState(() {
        if (deleted) {
          _output = 'Deleted: ${_keyController.text}\\nTotal keys: $count';
        } else {
          _output = 'Key not found: ${_keyController.text}';
        }
      });
    } catch (e) {
      setState(() {
        _output = 'Error deleting value: $e';
      });
    }
  }
  
  Future<void> _showStats() async {
    if (_database == null) return;
    
    try {
      final bufferStats = await _database!.getBufferStats();
      final checkpointStats = await _database!.getCheckpointStats();
      final keyCount = await _database!.keyCount();
      
      setState(() {
        _output = '''Database Statistics:
Key Count: $keyCount

Buffer Pool:
  Hit Ratio: ${bufferStats.hitRatio.toStringAsFixed(1)}%
  Cache Hits: ${bufferStats.cacheHits}
  Cache Misses: ${bufferStats.cacheMisses}
  Pages: ${bufferStats.pagesInBuffer}/${bufferStats.capacity}

Checkpoints:
  Performed: ${checkpointStats.checkpointsPerformed}
  Pages Written: ${checkpointStats.pagesWritten}
  WAL Size: ${checkpointStats.walSize} bytes''';
      });
    } catch (e) {
      setState(() {
        _output = 'Error getting statistics: $e';
      });
    }
  }
  
  @override
  void dispose() {
    _database?.close();
    _keyController.dispose();
    _valueController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('LowkeyDB Demo'),
      ),
      body: Padding(
        padding: EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _keyController,
              decoration: InputDecoration(
                labelText: 'Key',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 8),
            TextField(
              controller: _valueController,
              decoration: InputDecoration(
                labelText: 'Value',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: _putValue,
                  child: Text('Put'),
                ),
                ElevatedButton(
                  onPressed: _getValue,
                  child: Text('Get'),
                ),
                ElevatedButton(
                  onPressed: _deleteValue,
                  child: Text('Delete'),
                ),
                ElevatedButton(
                  onPressed: _showStats,
                  child: Text('Stats'),
                ),
              ],
            ),
            SizedBox(height: 16),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _output,
                    style: TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

## Advanced Features

### Transaction Example

```dart
import 'lowkeydb_wrapper.dart';

class BankAccount {
  final LowkeyDB _db;
  
  BankAccount(this._db);
  
  Future<void> transfer(String fromAccount, String toAccount, double amount) async {
    final txId = await _db.beginTransaction(IsolationLevel.serializable);
    
    try {
      // Get current balances
      final fromBalanceStr = await _db.getTransaction(txId, 'account:$fromAccount');
      final toBalanceStr = await _db.getTransaction(txId, 'account:$toAccount');
      
      if (fromBalanceStr == null || toBalanceStr == null) {
        throw Exception('Account not found');
      }
      
      final fromBalance = double.parse(fromBalanceStr);
      final toBalance = double.parse(toBalanceStr);
      
      if (fromBalance < amount) {
        throw Exception('Insufficient funds');
      }
      
      // Update balances
      final newFromBalance = fromBalance - amount;
      final newToBalance = toBalance + amount;
      
      await _db.putTransaction(txId, 'account:$fromAccount', newFromBalance.toString());
      await _db.putTransaction(txId, 'account:$toAccount', newToBalance.toString());
      
      // Commit the transaction
      await _db.commitTransaction(txId);
      
      print('Transfer successful: $amount from $fromAccount to $toAccount');
    } catch (e) {
      // Rollback on any error
      await _db.rollbackTransaction(txId);
      print('Transfer failed: $e');
      rethrow;
    }
  }
  
  Future<double> getBalance(String accountId) async {
    final balanceStr = await _db.get('account:$accountId');
    return balanceStr != null ? double.parse(balanceStr) : 0.0;
  }
  
  Future<void> createAccount(String accountId, double initialBalance) async {
    await _db.put('account:$accountId', initialBalance.toString());
  }
}

// Usage example
Future<void> bankingExample() async {
  final dbDir = await LowkeyDB.getDefaultDatabaseDirectory();
  final db = await LowkeyDB.create(path.join(dbDir, 'banking.db'));
  
  final bank = BankAccount(db);
  
  // Create accounts
  await bank.createAccount('alice', 1000.0);
  await bank.createAccount('bob', 500.0);
  
  // Transfer money
  await bank.transfer('alice', 'bob', 100.0);
  
  // Check balances
  final aliceBalance = await bank.getBalance('alice');
  final bobBalance = await bank.getBalance('bob');
  
  print('Alice balance: \$${aliceBalance.toStringAsFixed(2)}');
  print('Bob balance: \$${bobBalance.toStringAsFixed(2)}');
  
  db.close();
}
```

### Configuration Manager

```dart
class ConfigManager {
  final LowkeyDB _db;
  
  ConfigManager(this._db);
  
  static Future<ConfigManager> create([String? dbPath]) async {
    dbPath ??= path.join(await LowkeyDB.getDefaultDatabaseDirectory(), 'config.db');
    final db = await LowkeyDB.create(dbPath);
    return ConfigManager(db);
  }
  
  Future<void> setString(String section, String key, String value) async {
    await _db.put('config:$section:$key', value);
  }
  
  Future<String?> getString(String section, String key, [String? defaultValue]) async {
    final value = await _db.get('config:$section:$key');
    return value ?? defaultValue;
  }
  
  Future<void> setInt(String section, String key, int value) async {
    await setString(section, key, value.toString());
  }
  
  Future<int> getInt(String section, String key, [int defaultValue = 0]) async {
    final value = await getString(section, key);
    return value != null ? int.tryParse(value) ?? defaultValue : defaultValue;
  }
  
  Future<void> setBool(String section, String key, bool value) async {
    await setString(section, key, value.toString());
  }
  
  Future<bool> getBool(String section, String key, [bool defaultValue = false]) async {
    final value = await getString(section, key);
    return value != null ? value.toLowerCase() == 'true' : defaultValue;
  }
  
  Future<void> setDouble(String section, String key, double value) async {
    await setString(section, key, value.toString());
  }
  
  Future<double> getDouble(String section, String key, [double defaultValue = 0.0]) async {
    final value = await getString(section, key);
    return value != null ? double.tryParse(value) ?? defaultValue : defaultValue;
  }
  
  Future<List<String>> getKeys(String section) async {
    // This would require a custom scan function in the C API
    // For now, we'll return an empty list
    return [];
  }
  
  void close() {
    _db.close();
  }
}

// Usage example
Future<void> configExample() async {
  final config = await ConfigManager.create();
  
  // Set configuration values
  await config.setString('app', 'name', 'My Flutter App');
  await config.setString('app', 'version', '1.0.0');
  await config.setBool('app', 'debug_mode', true);
  await config.setInt('ui', 'theme_id', 2);
  await config.setDouble('performance', 'cache_size_mb', 64.5);
  
  // Read configuration values
  final appName = await config.getString('app', 'name', 'Unknown App');
  final debugMode = await config.getBool('app', 'debug_mode');
  final themeId = await config.getInt('ui', 'theme_id', 1);
  final cacheSize = await config.getDouble('performance', 'cache_size_mb', 32.0);
  
  print('App Configuration:');
  print('  Name: $appName');
  print('  Debug Mode: $debugMode');
  print('  Theme ID: $themeId');
  print('  Cache Size: ${cacheSize}MB');
  
  config.close();
}
```

## Performance Optimization

### Monitoring Widget

```dart
class DatabaseMonitor extends StatefulWidget {
  final LowkeyDB database;
  
  const DatabaseMonitor({Key? key, required this.database}) : super(key: key);
  
  @override
  _DatabaseMonitorState createState() => _DatabaseMonitorState();
}

class _DatabaseMonitorState extends State<DatabaseMonitor> {
  LowkeyDBBufferStats? _bufferStats;
  LowkeyDBCheckpointStats? _checkpointStats;
  int _keyCount = 0;
  
  Timer? _timer;
  
  @override
  void initState() {
    super.initState();
    _startMonitoring();
  }
  
  void _startMonitoring() {
    _timer = Timer.periodic(Duration(seconds: 1), (_) => _updateStats());
    _updateStats();
  }
  
  Future<void> _updateStats() async {
    try {
      final bufferStats = await widget.database.getBufferStats();
      final checkpointStats = await widget.database.getCheckpointStats();
      final keyCount = await widget.database.keyCount();
      
      setState(() {
        _bufferStats = bufferStats;
        _checkpointStats = checkpointStats;
        _keyCount = keyCount;
      });
    } catch (e) {
      print('Error updating stats: $e');
    }
  }
  
  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    if (_bufferStats == null || _checkpointStats == null) {
      return Center(child: CircularProgressIndicator());
    }
    
    return Column(
      children: [
        Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Database Statistics', style: Theme.of(context).textTheme.headline6),
                SizedBox(height: 8),
                Text('Total Keys: $_keyCount'),
                SizedBox(height: 16),
                Text('Buffer Pool', style: Theme.of(context).textTheme.subtitle1),
                LinearProgressIndicator(
                  value: _bufferStats!.hitRatio / 100,
                  backgroundColor: Colors.red[200],
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _bufferStats!.hitRatio > 80 ? Colors.green : Colors.orange,
                  ),
                ),
                Text('Hit Ratio: ${_bufferStats!.hitRatio.toStringAsFixed(1)}%'),
                Text('Cache Hits: ${_bufferStats!.cacheHits}'),
                Text('Cache Misses: ${_bufferStats!.cacheMisses}'),
                Text('Pages: ${_bufferStats!.pagesInBuffer}/${_bufferStats!.capacity}'),
                SizedBox(height: 16),
                Text('WAL & Checkpoints', style: Theme.of(context).textTheme.subtitle1),
                Text('Checkpoints: ${_checkpointStats!.checkpointsPerformed}'),
                Text('WAL Size: ${_formatBytes(_checkpointStats!.walSize)}'),
                Text('Pages Written: ${_checkpointStats!.pagesWritten}'),
              ],
            ),
          ),
        ),
      ],
    );
  }
  
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
```

### Performance Tips

```dart
class PerformanceOptimizedDB {
  final LowkeyDB _db;
  
  PerformanceOptimizedDB(this._db) {
    _configureOptimalSettings();
  }
  
  void _configureOptimalSettings() {
    // Configure checkpointing for optimal performance
    // Adjust based on your app's needs
    _db.configureCheckpointing(
      5000,  // 5 second interval
      10,    // 10MB max WAL size
      5,     // Keep 5 archived WAL files
    );
    
    // Start auto checkpointing
    _db.startAutoCheckpoint();
  }
  
  // Batch operations for better performance
  Future<void> putMany(Map<String, String> keyValues) async {
    final txId = await _db.beginTransaction(IsolationLevel.readCommitted);
    
    try {
      for (final entry in keyValues.entries) {
        await _db.putTransaction(txId, entry.key, entry.value);
      }
      await _db.commitTransaction(txId);
    } catch (e) {
      await _db.rollbackTransaction(txId);
      rethrow;
    }
  }
  
  // Efficient key design patterns
  String userKey(String userId) => 'user:$userId';
  String userProfileKey(String userId) => 'user:$userId:profile';
  String userSettingsKey(String userId) => 'user:$userId:settings';
  String sessionKey(String sessionId) => 'session:$sessionId';
  String cacheKey(String namespace, String key) => 'cache:$namespace:$key';
  
  void close() {
    _db.stopAutoCheckpoint();
    _db.close();
  }
}
```

## Platform-Specific Considerations

### Android Setup

In `android/app/build.gradle`:

```gradle
android {
    ...
    
    defaultConfig {
        ...
        ndk {
            abiFilters 'arm64-v8a', 'armeabi-v7a', 'x86_64'
        }
    }
}
```

Copy libraries to the appropriate directories:

```bash
# Copy native libraries
cp liblowkeydb_aarch64.so android/app/src/main/jniLibs/arm64-v8a/liblowkeydb.so
cp liblowkeydb_armv7.so android/app/src/main/jniLibs/armeabi-v7a/liblowkeydb.so
cp liblowkeydb_x86_64.so android/app/src/main/jniLibs/x86_64/liblowkeydb.so
```

### iOS Setup

In `ios/Runner.xcodeproj`, add the dylib to your bundle and update `Info.plist`:

```xml
<key>CFBundleExecutable</key>
<string>$(EXECUTABLE_NAME)</string>
```

### macOS Setup

In `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

## Best Practices

### 1. Resource Management

```dart
class DatabaseService {
  static LowkeyDB? _instance;
  
  static Future<LowkeyDB> getInstance() async {
    if (_instance == null) {
      final dbDir = await LowkeyDB.getDefaultDatabaseDirectory();
      _instance = await LowkeyDB.create(path.join(dbDir, 'app.db'));
    }
    return _instance!;
  }
  
  static void dispose() {
    _instance?.close();
    _instance = null;
  }
}

// Use in your app
class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DatabaseService.dispose();
    super.dispose();
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Ensure data is persisted when app goes to background
      DatabaseService.getInstance().then((db) => db.checkpoint());
    }
  }
  
  // ... rest of your app
}
```

### 2. Error Handling

```dart
class SafeDatabaseOperations {
  final LowkeyDB _db;
  
  SafeDatabaseOperations(this._db);
  
  Future<T?> safeOperation<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on LowkeyDBException catch (e) {
      print('Database error: ${e.message} (${e.errorCode})');
      return null;
    } catch (e) {
      print('Unexpected error: $e');
      return null;
    }
  }
  
  Future<String?> safeGet(String key) async {
    return await safeOperation(() => _db.get(key));
  }
  
  Future<bool> safePut(String key, String value) async {
    final result = await safeOperation(() => _db.put(key, value));
    return result != null;
  }
}
```

### 3. State Management Integration

```dart
// Example with Provider
class DatabaseProvider extends ChangeNotifier {
  LowkeyDB? _database;
  Map<String, String> _cache = {};
  
  Future<void> initialize() async {
    final dbDir = await LowkeyDB.getDefaultDatabaseDirectory();
    _database = await LowkeyDB.create(path.join(dbDir, 'app.db'));
    notifyListeners();
  }
  
  Future<void> put(String key, String value) async {
    await _database?.put(key, value);
    _cache[key] = value;
    notifyListeners();
  }
  
  Future<String?> get(String key) async {
    if (_cache.containsKey(key)) {
      return _cache[key];
    }
    
    final value = await _database?.get(key);
    if (value != null) {
      _cache[key] = value;
    }
    return value;
  }
  
  @override
  void dispose() {
    _database?.close();
    super.dispose();
  }
}
```

## Troubleshooting

### Common Issues

1. **Library Loading Errors**
   ```dart
   // Add error handling for library loading
   static DynamicLibrary _loadLibrary() {
     try {
       if (Platform.isAndroid) {
         return DynamicLibrary.open('liblowkeydb.so');
       }
       // ... other platforms
     } catch (e) {
       throw Exception('Failed to load LowkeyDB library: $e');
     }
   }
   ```

2. **FFI Binding Issues**
   ```bash
   # Regenerate bindings if headers change
   dart run ffigen
   ```

3. **Memory Management**
   ```dart
   // Always use try-finally for FFI calls
   final ptr = calloc<Pointer<Char>>();
   try {
     // Use ptr
   } finally {
     calloc.free(ptr);
   }
   ```

4. **Platform Differences**
   ```dart
   // Handle platform-specific paths
   static Future<String> getDatabasePath(String filename) async {
     if (Platform.isIOS || Platform.isAndroid) {
       final dir = await getApplicationDocumentsDirectory();
       return path.join(dir.path, filename);
     } else {
       final dir = await getApplicationSupportDirectory();
       return path.join(dir.path, filename);
     }
   }
   ```

This comprehensive guide provides everything needed to integrate LowkeyDB into Flutter applications, offering high-performance embedded database capabilities with full ACID compliance and excellent threading support.