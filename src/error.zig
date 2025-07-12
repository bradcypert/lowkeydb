const std = @import("std");

pub const DatabaseError = error{
    // File I/O errors
    FileNotFound,
    FileAccessDenied,
    FileCorrupted,
    FileAlreadyExists,
    FileNotOpen,
    DiskFull,
    
    // Database errors
    DatabaseNotOpen,
    DatabaseCorrupted,
    InvalidPageSize,
    InvalidMagicNumber,
    UnsupportedVersion,
    
    // Operation errors
    KeyNotFound,
    KeyTooLarge,
    ValueTooLarge,
    OutOfMemory,
    InvalidOperation,
    
    // Type system errors
    TypeMismatch,
    InvalidInput,
    
    // Transaction errors
    TransactionAborted,
    TransactionNotFound,
    TransactionNotActive,
    TransactionConflict,
    TransactionTimeout,
    TransactionDeadlock,
    
    // WAL errors
    WALCorrupted,
    WALRecoveryFailed,
    WALFlushFailed,
    CorruptedData,
    EndOfStream,
    
    // Generic errors
    InvalidArgument,
    InternalError,
} || std.mem.Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.WriteError || std.fs.File.SeekError;

pub fn fromPosixError(err: anyerror) DatabaseError {
    return switch (err) {
        error.FileNotFound => DatabaseError.FileNotFound,
        error.AccessDenied => DatabaseError.FileAccessDenied,
        error.NoSpaceLeft => DatabaseError.DiskFull,
        error.OutOfMemory => DatabaseError.OutOfMemory,
        else => DatabaseError.InternalError,
    };
}
