# LowkeyDB C Integration Guide

LowkeyDB provides a comprehensive C API that allows you to integrate the high-performance embedded database into your C and C++ applications. This guide covers installation, compilation, and usage patterns.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Basic Operations](#basic-operations)
- [Advanced Features](#advanced-features)
- [Performance Optimization](#performance-optimization)
- [Complete Examples](#complete-examples)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Prerequisites

- **Zig 0.14.0+** (for building the library)
- **C compiler** (GCC, Clang, or MSVC)
- **Standard C library** (C99 or later)

## Installation

### Step 1: Build the Static Library

First, build LowkeyDB as a static library:

```bash
# Clone the repository
git clone https://github.com/bradcypert/lowkeydb
cd lowkeydb

# Build the static library with C API
zig build-lib src/c_api.zig -lc --name lowkeydb

# This creates liblowkeydb.a (Linux/macOS) or lowkeydb.lib (Windows)
```

### Step 2: Set Up Headers

Copy the header file to your include path:

```bash
# Copy header to your project
cp include/lowkeydb.h /path/to/your/project/include/

# Or install system-wide (requires sudo)
sudo cp include/lowkeydb.h /usr/local/include/
```

### Step 3: Link with Your Project

#### Using GCC/Clang:

```bash
# Compile your application
gcc -I./include -L./lib -o my_app main.c -llowkeydb -lpthread -lm

# Or with static linking
gcc -I./include -o my_app main.c liblowkeydb.a -lpthread -lm
```

#### Using CMake:

```cmake
cmake_minimum_required(VERSION 3.10)
project(MyApp)

# Find the LowkeyDB library
find_library(LOWKEYDB_LIB lowkeydb PATHS ${CMAKE_SOURCE_DIR}/lib)
find_path(LOWKEYDB_INCLUDE lowkeydb.h PATHS ${CMAKE_SOURCE_DIR}/include)

# Create executable
add_executable(my_app main.c)

# Link libraries
target_include_directories(my_app PRIVATE ${LOWKEYDB_INCLUDE})
target_link_libraries(my_app ${LOWKEYDB_LIB} pthread m)
```

#### Using Makefile:

```makefile
CC = gcc
CFLAGS = -Wall -Wextra -std=c99 -O2
INCLUDES = -I./include
LIBS = -L./lib -llowkeydb -lpthread -lm

# For static linking
# LIBS = ./lib/liblowkeydb.a -lpthread -lm

SRCDIR = src
SOURCES = $(wildcard $(SRCDIR)/*.c)
OBJECTS = $(SOURCES:.c=.o)
TARGET = my_app

$(TARGET): $(OBJECTS)
	$(CC) $(OBJECTS) $(LIBS) -o $(TARGET)

%.o: %.c
	$(CC) $(CFLAGS) $(INCLUDES) -c $< -o $@

clean:
	rm -f $(OBJECTS) $(TARGET)

.PHONY: clean
```

## Quick Start

Here's a minimal example to get you started:

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lowkeydb.h"

int main() {
    LowkeyDB* db = NULL;
    int result;
    
    // Create database
    result = lowkeydb_create("my_app.db", &db);
    if (result != LOWKEY_OK) {
        fprintf(stderr, "Failed to create database: %s\\n", 
                lowkeydb_error_message(result));
        return 1;
    }
    
    // Store some data
    result = lowkeydb_put(db, "greeting", "Hello, LowkeyDB!");
    if (result != LOWKEY_OK) {
        fprintf(stderr, "Failed to put data: %s\\n", 
                lowkeydb_error_message(result));
        lowkeydb_close(db);
        return 1;
    }
    
    // Retrieve data
    char* value = NULL;
    size_t value_len = 0;
    result = lowkeydb_get(db, "greeting", &value, &value_len);
    if (result == LOWKEY_OK && value != NULL) {
        printf("Retrieved: %s (length: %zu)\\n", value, value_len);
        lowkeydb_free(value); // Important: free retrieved values
    } else if (result == LOWKEY_ERROR_KEY_NOT_FOUND) {
        printf("Key not found\\n");
    } else {
        fprintf(stderr, "Failed to get data: %s\\n", 
                lowkeydb_error_message(result));
    }
    
    // Get database statistics
    uint64_t key_count = lowkeydb_key_count(db);
    printf("Database has %llu keys\\n", (unsigned long long)key_count);
    
    // Clean up
    lowkeydb_close(db);
    return 0;
}
```

## Basic Operations

### Database Lifecycle

```c
#include "lowkeydb.h"

int database_lifecycle_example() {
    LowkeyDB* db = NULL;
    int result;
    
    // Create a new database
    result = lowkeydb_create("example.db", &db);
    if (result != LOWKEY_OK) {
        fprintf(stderr, "Create failed: %s\\n", lowkeydb_error_message(result));
        return -1;
    }
    
    // Alternative: Open existing database
    // result = lowkeydb_open("existing.db", &db);
    
    // ... database operations ...
    
    // Always close when done
    lowkeydb_close(db);
    return 0;
}
```

### CRUD Operations

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lowkeydb.h"

void crud_operations_example(LowkeyDB* db) {
    int result;
    char* value = NULL;
    size_t value_len = 0;
    
    // CREATE/UPDATE (PUT)
    result = lowkeydb_put(db, "user:001", "Alice Johnson");
    if (result != LOWKEY_OK) {
        fprintf(stderr, "PUT failed: %s\\n", lowkeydb_error_message(result));
        return;
    }
    
    result = lowkeydb_put(db, "product:A", "Laptop Computer");
    if (result != LOWKEY_OK) {
        fprintf(stderr, "PUT failed: %s\\n", lowkeydb_error_message(result));
        return;
    }
    
    // READ (GET)
    result = lowkeydb_get(db, "user:001", &value, &value_len);
    if (result == LOWKEY_OK && value != NULL) {
        printf("User: %s\\n", value);
        lowkeydb_free(value); // Always free retrieved values
        value = NULL;
    } else if (result == LOWKEY_ERROR_KEY_NOT_FOUND) {
        printf("User not found\\n");
    } else {
        fprintf(stderr, "GET failed: %s\\n", lowkeydb_error_message(result));
    }
    
    // DELETE
    result = lowkeydb_delete(db, "product:A");
    if (result == LOWKEY_OK) {
        printf("Product deleted\\n");
    } else if (result == LOWKEY_ERROR_KEY_NOT_FOUND) {
        printf("Product not found\\n");
    } else {
        fprintf(stderr, "DELETE failed: %s\\n", lowkeydb_error_message(result));
    }
    
    // CHECK existence (by attempting to get)
    result = lowkeydb_get(db, "user:001", &value, &value_len);
    if (result == LOWKEY_OK) {
        printf("User exists\\n");
        lowkeydb_free(value);
    } else if (result == LOWKEY_ERROR_KEY_NOT_FOUND) {
        printf("User does not exist\\n");
    }
}
```

### Batch Operations

```c
#include <stdio.h>
#include "lowkeydb.h"

typedef struct {
    const char* key;
    const char* value;
} KeyValuePair;

void batch_operations_example(LowkeyDB* db) {
    // Efficient batch insertion
    KeyValuePair users[] = {
        {"user:001", "Alice Johnson"},
        {"user:002", "Bob Smith"},
        {"user:003", "Carol Davis"},
        {"user:004", "David Wilson"},
        {"user:005", "Eve Brown"}
    };
    
    int user_count = sizeof(users) / sizeof(users[0]);
    int success_count = 0;
    
    // Insert multiple records
    for (int i = 0; i < user_count; i++) {
        int result = lowkeydb_put(db, users[i].key, users[i].value);
        if (result == LOWKEY_OK) {
            success_count++;
        } else {
            fprintf(stderr, "Failed to insert %s: %s\\n", 
                    users[i].key, lowkeydb_error_message(result));
        }
    }
    
    printf("Inserted %d/%d users successfully\\n", success_count, user_count);
    printf("Total keys in database: %llu\\n", 
           (unsigned long long)lowkeydb_key_count(db));
}
```

## Advanced Features

### Transactions (ACID Compliance)

LowkeyDB supports full ACID transactions with multiple isolation levels:

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lowkeydb.h"

void transaction_example(LowkeyDB* db) {
    uint64_t tx_id;
    int result;
    
    // Begin a serializable transaction
    result = lowkeydb_begin_transaction(db, LOWKEY_SERIALIZABLE, &tx_id);
    if (result != LOWKEY_OK) {
        fprintf(stderr, "Failed to begin transaction: %s\\n", 
                lowkeydb_error_message(result));
        return;
    }
    
    // Perform operations within the transaction
    result = lowkeydb_put_transaction(db, tx_id, "account:A", "1000");
    if (result != LOWKEY_OK) {
        fprintf(stderr, "Transaction PUT failed: %s\\n", 
                lowkeydb_error_message(result));
        lowkeydb_rollback_transaction(db, tx_id);
        return;
    }
    
    result = lowkeydb_put_transaction(db, tx_id, "account:B", "500");
    if (result != LOWKEY_OK) {
        fprintf(stderr, "Transaction PUT failed: %s\\n", 
                lowkeydb_error_message(result));
        lowkeydb_rollback_transaction(db, tx_id);
        return;
    }
    
    // Read within transaction
    char* balance_a = NULL;
    size_t balance_len = 0;
    result = lowkeydb_get_transaction(db, tx_id, "account:A", &balance_a, &balance_len);
    if (result == LOWKEY_OK && balance_a != NULL) {
        printf("Account A balance: %s\\n", balance_a);
        
        // Simulate a transfer
        int current_balance = atoi(balance_a);
        int transfer_amount = 100;
        
        if (current_balance >= transfer_amount) {
            // Update accounts
            char new_balance_a[32];
            snprintf(new_balance_a, sizeof(new_balance_a), "%d", 
                     current_balance - transfer_amount);
            
            result = lowkeydb_put_transaction(db, tx_id, "account:A", new_balance_a);
            if (result == LOWKEY_OK) {
                // Commit the transaction
                result = lowkeydb_commit_transaction(db, tx_id);
                if (result == LOWKEY_OK) {
                    printf("Transfer completed successfully\\n");
                } else {
                    fprintf(stderr, "Commit failed: %s\\n", 
                            lowkeydb_error_message(result));
                }
            } else {
                fprintf(stderr, "Update failed: %s\\n", 
                        lowkeydb_error_message(result));
                lowkeydb_rollback_transaction(db, tx_id);
            }
        } else {
            // Rollback on insufficient funds
            lowkeydb_rollback_transaction(db, tx_id);
            printf("Transfer failed: insufficient funds\\n");
        }
        
        lowkeydb_free(balance_a);
    } else {
        fprintf(stderr, "Failed to read balance: %s\\n", 
                lowkeydb_error_message(result));
        lowkeydb_rollback_transaction(db, tx_id);
    }
}
```

### Different Isolation Levels

```c
void isolation_level_example(LowkeyDB* db) {
    uint64_t tx1, tx2, tx3;
    int result;
    
    // Read Committed (fastest, allows dirty reads)
    result = lowkeydb_begin_transaction(db, LOWKEY_READ_COMMITTED, &tx1);
    if (result == LOWKEY_OK) {
        // ... transaction operations ...
        lowkeydb_commit_transaction(db, tx1);
    }
    
    // Repeatable Read (prevents dirty reads and non-repeatable reads)
    result = lowkeydb_begin_transaction(db, LOWKEY_REPEATABLE_READ, &tx2);
    if (result == LOWKEY_OK) {
        // ... transaction operations ...
        lowkeydb_commit_transaction(db, tx2);
    }
    
    // Serializable (strictest, prevents all anomalies)
    result = lowkeydb_begin_transaction(db, LOWKEY_SERIALIZABLE, &tx3);
    if (result == LOWKEY_OK) {
        // ... transaction operations ...
        lowkeydb_commit_transaction(db, tx3);
    }
}
```

### Concurrent Access with Threading

LowkeyDB is fully thread-safe. Here's an example using pthreads:

```c
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>
#include "lowkeydb.h"

typedef struct {
    LowkeyDB* db;
    int thread_id;
    int operations_count;
    int completed_operations;
    int errors;
} WorkerData;

void* worker_thread(void* arg) {
    WorkerData* data = (WorkerData*)arg;
    char key[64], value[64];
    
    for (int i = 0; i < data->operations_count; i++) {
        // Create unique keys per thread
        snprintf(key, sizeof(key), "thread_%d_key_%d", data->thread_id, i);
        snprintf(value, sizeof(value), "thread_%d_value_%d", data->thread_id, i);
        
        // Random operation (simplified)
        int operation = rand() % 3; // 0=put, 1=get, 2=delete
        
        switch (operation) {
            case 0: { // PUT
                int result = lowkeydb_put(data->db, key, value);
                if (result != LOWKEY_OK) {
                    data->errors++;
                    continue;
                }
                break;
            }
            case 1: { // GET
                char* retrieved_value = NULL;
                size_t value_len = 0;
                int result = lowkeydb_get(data->db, key, &retrieved_value, &value_len);
                if (result == LOWKEY_OK && retrieved_value != NULL) {
                    lowkeydb_free(retrieved_value);
                } else if (result != LOWKEY_ERROR_KEY_NOT_FOUND) {
                    data->errors++;
                    continue;
                }
                break;
            }
            case 2: { // DELETE
                int result = lowkeydb_delete(data->db, key);
                if (result != LOWKEY_OK && result != LOWKEY_ERROR_KEY_NOT_FOUND) {
                    data->errors++;
                    continue;
                }
                break;
            }
        }
        
        data->completed_operations++;
        
        // Small delay to vary timing
        if (i % 100 == 0) {
            usleep(1000); // 1ms
        }
    }
    
    printf("Thread %d completed: %d ops, %d errors\\n", 
           data->thread_id, data->completed_operations, data->errors);
    
    return NULL;
}

void concurrent_example() {
    LowkeyDB* db = NULL;
    int result = lowkeydb_create("concurrent_test.db", &db);
    if (result != LOWKEY_OK) {
        fprintf(stderr, "Failed to create database: %s\\n", 
                lowkeydb_error_message(result));
        return;
    }
    
    const int num_threads = 4;
    const int ops_per_thread = 1000;
    pthread_t threads[num_threads];
    WorkerData worker_data[num_threads];
    
    // Start worker threads
    for (int i = 0; i < num_threads; i++) {
        worker_data[i] = (WorkerData){
            .db = db,
            .thread_id = i,
            .operations_count = ops_per_thread,
            .completed_operations = 0,
            .errors = 0
        };
        
        pthread_create(&threads[i], NULL, worker_thread, &worker_data[i]);
    }
    
    // Wait for completion
    for (int i = 0; i < num_threads; i++) {
        pthread_join(threads[i], NULL);
    }
    
    // Collect results
    int total_ops = 0, total_errors = 0;
    for (int i = 0; i < num_threads; i++) {
        total_ops += worker_data[i].completed_operations;
        total_errors += worker_data[i].errors;
    }
    
    printf("Total: %d operations, %d errors\\n", total_ops, total_errors);
    printf("Final key count: %llu\\n", 
           (unsigned long long)lowkeydb_key_count(db));
    
    lowkeydb_close(db);
}
```

### WAL and Checkpointing

```c
#include <stdio.h>
#include "lowkeydb.h"

void wal_example(LowkeyDB* db) {
    // Configure automatic checkpointing
    // Parameters: interval_ms, max_wal_size_mb, max_archived_wals
    lowkeydb_configure_checkpointing(db, 2000, 5, 10); // 2 seconds, 5MB max WAL, keep 10 archives
    
    // Start automatic checkpointing
    int result = lowkeydb_start_auto_checkpoint(db);
    if (result != LOWKEY_OK) {
        fprintf(stderr, "Failed to start auto checkpoint: %s\\n", 
                lowkeydb_error_message(result));
        return;
    }
    
    // Perform many operations...
    for (int i = 0; i < 10000; i++) {
        char key[32], value[32];
        snprintf(key, sizeof(key), "key_%d", i);
        snprintf(value, sizeof(value), "value_%d", i);
        
        result = lowkeydb_put(db, key, value);
        if (result != LOWKEY_OK) {
            fprintf(stderr, "PUT failed: %s\\n", lowkeydb_error_message(result));
            break;
        }
    }
    
    // Manual checkpoint
    result = lowkeydb_checkpoint(db);
    if (result != LOWKEY_OK) {
        fprintf(stderr, "Manual checkpoint failed: %s\\n", 
                lowkeydb_error_message(result));
    }
    
    // Flush WAL to disk
    result = lowkeydb_flush_wal(db);
    if (result != LOWKEY_OK) {
        fprintf(stderr, "WAL flush failed: %s\\n", 
                lowkeydb_error_message(result));
    }
    
    // Get checkpoint statistics
    LowkeyDBCheckpointStats stats;
    result = lowkeydb_get_checkpoint_stats(db, &stats);
    if (result == LOWKEY_OK) {
        printf("Checkpoints performed: %llu\\n", 
               (unsigned long long)stats.checkpoints_performed);
        printf("Pages written: %llu\\n", 
               (unsigned long long)stats.pages_written);
        printf("WAL size: %llu bytes\\n", 
               (unsigned long long)stats.wal_size);
    }
    
    // Stop auto checkpointing (will be done automatically on close)
    lowkeydb_stop_auto_checkpoint(db);
}
```

## Performance Optimization

### Buffer Pool Monitoring

```c
#include <stdio.h>
#include "lowkeydb.h"

void performance_monitoring(LowkeyDB* db) {
    LowkeyDBBufferStats buffer_stats;
    int result = lowkeydb_get_buffer_stats(db, &buffer_stats);
    
    if (result == LOWKEY_OK) {
        printf("Buffer Pool Statistics:\\n");
        printf("  Hit ratio: %.1f%%\\n", buffer_stats.hit_ratio);
        printf("  Cache hits: %llu\\n", (unsigned long long)buffer_stats.cache_hits);
        printf("  Cache misses: %llu\\n", (unsigned long long)buffer_stats.cache_misses);
        printf("  Pages in buffer: %u/%u\\n", 
               buffer_stats.pages_in_buffer, buffer_stats.capacity);
        printf("  Evictions: %llu\\n", (unsigned long long)buffer_stats.evictions);
        printf("  Write-backs: %llu\\n", (unsigned long long)buffer_stats.write_backs);
        
        // Optimization recommendations
        if (buffer_stats.hit_ratio < 80.0) {
            printf("  ⚠️  Consider increasing buffer pool size for better performance\\n");
        }
        
        if (buffer_stats.evictions > buffer_stats.cache_hits / 4) {
            printf("  ⚠️  High eviction rate - consider optimizing access patterns\\n");
        }
    } else {
        fprintf(stderr, "Failed to get buffer stats: %s\\n", 
                lowkeydb_error_message(result));
    }
}
```

### Efficient Key Design

```c
void efficient_key_design_example(LowkeyDB* db) {
    // Good: Use consistent prefixes for related data
    lowkeydb_put(db, "user:001:name", "Alice");
    lowkeydb_put(db, "user:001:email", "alice@example.com");
    lowkeydb_put(db, "user:001:last_login", "2024-01-15");
    
    // Good: Use hierarchical keys
    lowkeydb_put(db, "app:settings:theme", "dark");
    lowkeydb_put(db, "app:settings:language", "en");
    lowkeydb_put(db, "app:cache:session:abc123", "user_data");
    
    // Good: Use fixed-width numeric suffixes for ordering
    lowkeydb_put(db, "log:20240115:001", "Error message 1");
    lowkeydb_put(db, "log:20240115:002", "Warning message 2");
    
    // Avoid: Very long keys (impacts performance)
    // Avoid: Keys with random prefixes (impacts cache locality)
}
```

## Complete Examples

### Simple Key-Value Store with CLI

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lowkeydb.h"

#define MAX_INPUT 1024
#define MAX_ARGS 3

int main() {
    LowkeyDB* db = NULL;
    int result = lowkeydb_create("keyvalue_store.db", &db);
    if (result != LOWKEY_OK) {
        fprintf(stderr, "Failed to create database: %s\\n", 
                lowkeydb_error_message(result));
        return 1;
    }
    
    printf("LowkeyDB CLI - Enter commands (put/get/delete/stats/quit):\\n");
    
    char input[MAX_INPUT];
    while (1) {
        printf("> ");
        fflush(stdout);
        
        if (!fgets(input, sizeof(input), stdin)) {
            break;
        }
        
        // Remove newline
        input[strcspn(input, "\\n")] = 0;
        
        // Parse command
        char* args[MAX_ARGS];
        int argc = 0;
        char* token = strtok(input, " ");
        while (token && argc < MAX_ARGS) {
            args[argc++] = token;
            token = strtok(NULL, " ");
        }
        
        if (argc == 0) continue;
        
        if (strcmp(args[0], "quit") == 0 || strcmp(args[0], "exit") == 0) {
            break;
        } else if (strcmp(args[0], "put") == 0) {
            if (argc != 3) {
                printf("Usage: put <key> <value>\\n");
                continue;
            }
            
            result = lowkeydb_put(db, args[1], args[2]);
            if (result == LOWKEY_OK) {
                printf("OK\\n");
            } else {
                printf("Error: %s\\n", lowkeydb_error_message(result));
            }
        } else if (strcmp(args[0], "get") == 0) {
            if (argc != 2) {
                printf("Usage: get <key>\\n");
                continue;
            }
            
            char* value = NULL;
            size_t value_len = 0;
            result = lowkeydb_get(db, args[1], &value, &value_len);
            if (result == LOWKEY_OK && value != NULL) {
                printf("%s\\n", value);
                lowkeydb_free(value);
            } else if (result == LOWKEY_ERROR_KEY_NOT_FOUND) {
                printf("(null)\\n");
            } else {
                printf("Error: %s\\n", lowkeydb_error_message(result));
            }
        } else if (strcmp(args[0], "delete") == 0) {
            if (argc != 2) {
                printf("Usage: delete <key>\\n");
                continue;
            }
            
            result = lowkeydb_delete(db, args[1]);
            if (result == LOWKEY_OK) {
                printf("OK\\n");
            } else if (result == LOWKEY_ERROR_KEY_NOT_FOUND) {
                printf("Key not found\\n");
            } else {
                printf("Error: %s\\n", lowkeydb_error_message(result));
            }
        } else if (strcmp(args[0], "stats") == 0) {
            uint64_t key_count = lowkeydb_key_count(db);
            printf("Key count: %llu\\n", (unsigned long long)key_count);
            
            LowkeyDBBufferStats buffer_stats;
            if (lowkeydb_get_buffer_stats(db, &buffer_stats) == LOWKEY_OK) {
                printf("Cache hit ratio: %.1f%%\\n", buffer_stats.hit_ratio);
            }
        } else {
            printf("Unknown command: %s\\n", args[0]);
            printf("Available commands: put, get, delete, stats, quit\\n");
        }
    }
    
    lowkeydb_close(db);
    printf("Database closed.\\n");
    return 0;
}
```

### Configuration Manager in C

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lowkeydb.h"

typedef struct {
    LowkeyDB* db;
} ConfigManager;

ConfigManager* config_manager_create(const char* db_path) {
    ConfigManager* config = malloc(sizeof(ConfigManager));
    if (!config) return NULL;
    
    int result = lowkeydb_create(db_path, &config->db);
    if (result != LOWKEY_OK) {
        free(config);
        return NULL;
    }
    
    return config;
}

void config_manager_destroy(ConfigManager* config) {
    if (config) {
        lowkeydb_close(config->db);
        free(config);
    }
}

int config_set_string(ConfigManager* config, const char* section, 
                     const char* key, const char* value) {
    char full_key[256];
    snprintf(full_key, sizeof(full_key), "config:%s:%s", section, key);
    return lowkeydb_put(config->db, full_key, value);
}

char* config_get_string(ConfigManager* config, const char* section, 
                       const char* key) {
    char full_key[256];
    snprintf(full_key, sizeof(full_key), "config:%s:%s", section, key);
    
    char* value = NULL;
    size_t value_len = 0;
    int result = lowkeydb_get(config->db, full_key, &value, &value_len);
    
    return (result == LOWKEY_OK) ? value : NULL;
}

int config_set_int(ConfigManager* config, const char* section, 
                  const char* key, int value) {
    char value_str[32];
    snprintf(value_str, sizeof(value_str), "%d", value);
    return config_set_string(config, section, key, value_str);
}

int config_get_int(ConfigManager* config, const char* section, 
                  const char* key, int default_value) {
    char* value_str = config_get_string(config, section, key);
    if (value_str) {
        int value = atoi(value_str);
        lowkeydb_free(value_str);
        return value;
    }
    return default_value;
}

// Example usage
int main() {
    ConfigManager* config = config_manager_create("app_config.db");
    if (!config) {
        fprintf(stderr, "Failed to create config manager\\n");
        return 1;
    }
    
    // Set configuration values
    config_set_string(config, "database", "host", "localhost");
    config_set_int(config, "database", "port", 5432);
    config_set_string(config, "ui", "theme", "dark");
    
    // Read configuration values
    char* host = config_get_string(config, "database", "host");
    int port = config_get_int(config, "database", "port", 3306);
    char* theme = config_get_string(config, "ui", "theme");
    
    printf("Database Config:\\n");
    printf("  Host: %s\\n", host ? host : "unknown");
    printf("  Port: %d\\n", port);
    printf("  UI Theme: %s\\n", theme ? theme : "default");
    
    // Clean up
    if (host) lowkeydb_free(host);
    if (theme) lowkeydb_free(theme);
    config_manager_destroy(config);
    
    return 0;
}
```

## Best Practices

### 1. Memory Management

```c
// Always check return values
int result = lowkeydb_put(db, "key", "value");
if (result != LOWKEY_OK) {
    fprintf(stderr, "Operation failed: %s\\n", lowkeydb_error_message(result));
    // Handle error appropriately
}

// Always free retrieved values
char* value = NULL;
size_t len = 0;
if (lowkeydb_get(db, "key", &value, &len) == LOWKEY_OK && value != NULL) {
    // Use value...
    lowkeydb_free(value); // Critical: prevents memory leaks
}

// Always close database
lowkeydb_close(db);
```

### 2. Error Handling

```c
// Handle specific error codes
int result = lowkeydb_get(db, "key", &value, &len);
switch (result) {
    case LOWKEY_OK:
        // Success - use value
        break;
    case LOWKEY_ERROR_KEY_NOT_FOUND:
        // Key doesn't exist - handle gracefully
        break;
    case LOWKEY_ERROR_MEMORY:
        // Memory allocation failed - critical error
        fprintf(stderr, "Out of memory\\n");
        exit(1);
    default:
        // Other error
        fprintf(stderr, "Database error: %s\\n", lowkeydb_error_message(result));
        break;
}
```

### 3. Transaction Management

```c
// Always handle transaction cleanup
uint64_t tx_id;
int result = lowkeydb_begin_transaction(db, LOWKEY_SERIALIZABLE, &tx_id);
if (result != LOWKEY_OK) {
    // Handle error
    return;
}

// Use a flag to track transaction state
int transaction_completed = 0;

// ... transaction operations ...

if (/* success condition */) {
    result = lowkeydb_commit_transaction(db, tx_id);
    transaction_completed = (result == LOWKEY_OK);
}

// Rollback if not committed
if (!transaction_completed) {
    lowkeydb_rollback_transaction(db, tx_id);
}
```

### 4. Thread Safety

```c
// LowkeyDB is thread-safe, but you still need proper synchronization
// for your application logic

#include <pthread.h>

pthread_mutex_t app_mutex = PTHREAD_MUTEX_INITIALIZER;

void thread_safe_operation(LowkeyDB* db) {
    pthread_mutex_lock(&app_mutex);
    
    // Your application-specific logic here
    // (LowkeyDB operations are already thread-safe)
    
    pthread_mutex_unlock(&app_mutex);
}
```

## Troubleshooting

### Common Issues

1. **Memory Leaks**
   ```c
   // Problem: Not freeing retrieved values
   char* value;
   lowkeydb_get(db, "key", &value, &len);
   // value is leaked!
   
   // Solution: Always free
   if (value) lowkeydb_free(value);
   ```

2. **Transaction Deadlocks**
   ```c
   // Use shorter transactions and consistent key ordering
   // Always have rollback handling
   ```

3. **Compilation Issues**
   ```bash
   # Make sure to link pthread and math libraries
   gcc -o app main.c -llowkeydb -lpthread -lm
   ```

4. **Performance Issues**
   ```c
   // Monitor buffer pool statistics
   LowkeyDBBufferStats stats;
   lowkeydb_get_buffer_stats(db, &stats);
   if (stats.hit_ratio < 80.0) {
       printf("Low cache hit ratio: %.1f%%\\n", stats.hit_ratio);
   }
   ```

### Debug Information

To enable debug logging, rebuild the library with debug flags:

```bash
zig build-lib src/c_api.zig -lc --name lowkeydb -O Debug
```

This guide provides comprehensive coverage of integrating LowkeyDB into C applications. The database delivers excellent performance (>25,000 write ops/sec) with full ACID compliance and thread safety, making it ideal for embedded applications requiring reliable data storage.