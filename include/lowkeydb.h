#ifndef LOWKEYDB_H
#define LOWKEYDB_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stddef.h>

// Opaque database handle
typedef struct LowkeyDB LowkeyDB;

// Error codes
#define LOWKEY_OK                          0
#define LOWKEY_ERROR_INVALID_PARAM        -1
#define LOWKEY_ERROR_MEMORY               -2
#define LOWKEY_ERROR_IO                   -3
#define LOWKEY_ERROR_KEY_NOT_FOUND        -4
#define LOWKEY_ERROR_TRANSACTION_CONFLICT -5
#define LOWKEY_ERROR_INVALID_TRANSACTION  -6
#define LOWKEY_ERROR_GENERIC              -100

// Transaction isolation levels
#define LOWKEY_READ_COMMITTED   0
#define LOWKEY_REPEATABLE_READ  1
#define LOWKEY_SERIALIZABLE     2

// Buffer pool statistics
typedef struct {
    uint32_t capacity;
    uint32_t pages_in_buffer;
    uint64_t cache_hits;
    uint64_t cache_misses;
    double hit_ratio;
    uint64_t evictions;
    uint64_t write_backs;
} LowkeyDBBufferStats;

// WAL checkpoint statistics
typedef struct {
    uint64_t checkpoints_performed;
    uint64_t pages_written;
    uint64_t wal_size;
    uint64_t last_checkpoint_time;
} LowkeyDBCheckpointStats;

// Database lifecycle
int lowkeydb_create(const char* db_path, LowkeyDB** db_handle);
int lowkeydb_open(const char* db_path, LowkeyDB** db_handle);
void lowkeydb_close(LowkeyDB* db_handle);

// Basic operations
int lowkeydb_put(LowkeyDB* db_handle, const char* key, const char* value);
int lowkeydb_get(LowkeyDB* db_handle, const char* key, char** value_out, size_t* value_len);
int lowkeydb_delete(LowkeyDB* db_handle, const char* key);
uint64_t lowkeydb_key_count(LowkeyDB* db_handle);

// Transaction operations
int lowkeydb_begin_transaction(LowkeyDB* db_handle, int isolation_level, uint64_t* tx_id);
int lowkeydb_commit_transaction(LowkeyDB* db_handle, uint64_t tx_id);
int lowkeydb_rollback_transaction(LowkeyDB* db_handle, uint64_t tx_id);
int lowkeydb_put_transaction(LowkeyDB* db_handle, uint64_t tx_id, const char* key, const char* value);
int lowkeydb_get_transaction(LowkeyDB* db_handle, uint64_t tx_id, const char* key, char** value_out, size_t* value_len);
int lowkeydb_delete_transaction(LowkeyDB* db_handle, uint64_t tx_id, const char* key);

// Statistics and monitoring
int lowkeydb_get_buffer_stats(LowkeyDB* db_handle, LowkeyDBBufferStats* stats);
int lowkeydb_get_checkpoint_stats(LowkeyDB* db_handle, LowkeyDBCheckpointStats* stats);

// WAL and checkpointing
void lowkeydb_configure_checkpointing(LowkeyDB* db_handle, uint64_t interval_ms, uint32_t max_wal_size_mb, uint32_t max_archived_wals);
int lowkeydb_start_auto_checkpoint(LowkeyDB* db_handle);
void lowkeydb_stop_auto_checkpoint(LowkeyDB* db_handle);
int lowkeydb_checkpoint(LowkeyDB* db_handle);
int lowkeydb_flush_wal(LowkeyDB* db_handle);

// Memory management
void lowkeydb_free(void* ptr);

// Error handling
const char* lowkeydb_error_message(int error_code);

#ifdef __cplusplus
}
#endif

#endif // LOWKEYDB_H