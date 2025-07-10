const std = @import("std");

const CLITestResult = struct {
    success: bool,
    output: []const u8,
    error_output: []const u8,
    
    pub fn deinit(self: *CLITestResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        allocator.free(self.error_output);
    }
};

const CLITester = struct {
    allocator: std.mem.Allocator,
    test_db_path: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, test_db_path: []const u8) CLITester {
        return CLITester{
            .allocator = allocator,
            .test_db_path = test_db_path,
        };
    }
    
    pub fn runCliCommand(self: *CLITester, commands: []const u8) !CLITestResult {
        // Create a temporary script file with the commands
        const script_path = "test_commands.txt";
        const script_file = try std.fs.cwd().createFile(script_path, .{});
        defer {
            script_file.close();
            std.fs.cwd().deleteFile(script_path) catch {};
        }
        
        try script_file.writeAll(commands);
        try script_file.writeAll("\nquit\n");
        
        // Build the CLI if not already built
        var build_process = std.process.Child.init(&[_][]const u8{ "zig", "build" }, self.allocator);
        _ = try build_process.spawnAndWait();
        
        // Run the CLI with the commands
        var cli_process = std.process.Child.init(&[_][]const u8{ "./zig-out/bin/lowkeydb", self.test_db_path }, self.allocator);
        cli_process.stdin_behavior = .Pipe;
        cli_process.stdout_behavior = .Pipe;
        cli_process.stderr_behavior = .Pipe;
        
        try cli_process.spawn();
        
        // Send commands to CLI
        const script_content = try std.fs.cwd().readFileAlloc(self.allocator, script_path, 1024 * 1024);
        defer self.allocator.free(script_content);
        
        try cli_process.stdin.?.writeAll(script_content);
        cli_process.stdin.?.close();
        cli_process.stdin = null;
        
        // Collect output
        const stdout = try cli_process.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        const stderr = try cli_process.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        
        const term = try cli_process.wait();
        const success = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
        
        return CLITestResult{
            .success = success,
            .output = stdout,
            .error_output = stderr,
        };
    }
    
    pub fn expectOutput(output: []const u8, expected: []const u8) bool {
        return std.mem.indexOf(u8, output, expected) != null;
    }
    
    pub fn expectNoError(error_output: []const u8) bool {
        return error_output.len == 0 or std.mem.indexOf(u8, error_output, "Error") == null;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== LowkeyDB CLI Integration Test ===\n\n");

    const test_db_path = "cli_integration_test.db";
    
    // Clean up any existing test files
    std.fs.cwd().deleteFile(test_db_path) catch {};
    std.fs.cwd().deleteFile("cli_integration_test.db.wal") catch {};

    var tester = CLITester.init(allocator, test_db_path);
    var total_tests: u32 = 0;
    var passed_tests: u32 = 0;

    // Test 1: Basic CRUD operations
    {
        total_tests += 1;
        std.debug.print("🧪 Test 1: Basic CRUD operations\n");
        
        var result = try tester.runCliCommand(
            \\put test_key test_value
            \\get test_key
            \\count
            \\delete test_key
            \\get test_key
            \\count
        );
        defer result.deinit(allocator);
        
        const success = result.success and
            tester.expectOutput(result.output, "OK") and
            tester.expectOutput(result.output, "Value: test_value") and
            tester.expectOutput(result.output, "Key count: 1") and
            tester.expectOutput(result.output, "Key deleted") and
            tester.expectOutput(result.output, "Key not found") and
            tester.expectOutput(result.output, "Key count: 0") and
            tester.expectNoError(result.error_output);
        
        if (success) {
            std.debug.print("  ✅ PASSED\n");
            passed_tests += 1;
        } else {
            std.debug.print("  ❌ FAILED\n");
            std.debug.print("  Output: {s}\n", .{result.output});
            std.debug.print("  Errors: {s}\n", .{result.error_output});
        }
    }

    // Test 2: Transaction operations
    {
        total_tests += 1;
        std.debug.print("🧪 Test 2: Transaction operations\n");
        
        var result = try tester.runCliCommand(
            \\begin serializable
            \\tput 1 tx_key tx_value
            \\tget 1 tx_key
            \\commit 1
            \\get tx_key
            \\transactions
        );
        defer result.deinit(allocator);
        
        const success = result.success and
            tester.expectOutput(result.output, "Transaction started with ID: 1") and
            tester.expectOutput(result.output, "OK") and
            tester.expectOutput(result.output, "Value: tx_value") and
            tester.expectOutput(result.output, "Transaction 1 committed") and
            tester.expectOutput(result.output, "Value: tx_value") and
            tester.expectOutput(result.output, "Active transactions: 0") and
            tester.expectNoError(result.error_output);
        
        if (success) {
            std.debug.print("  ✅ PASSED\n");
            passed_tests += 1;
        } else {
            std.debug.print("  ❌ FAILED\n");
            std.debug.print("  Output: {s}\n", .{result.output});
            std.debug.print("  Errors: {s}\n", .{result.error_output});
        }
    }

    // Test 3: Transaction rollback
    {
        total_tests += 1;
        std.debug.print("🧪 Test 3: Transaction rollback\n");
        
        var result = try tester.runCliCommand(
            \\begin read_committed
            \\tput 2 rollback_key rollback_value
            \\tget 2 rollback_key
            \\rollback 2
            \\get rollback_key
            \\transactions
        );
        defer result.deinit(allocator);
        
        const success = result.success and
            tester.expectOutput(result.output, "Transaction started with ID: 2") and
            tester.expectOutput(result.output, "OK") and
            tester.expectOutput(result.output, "Value: rollback_value") and
            tester.expectOutput(result.output, "Transaction 2 rolled back") and
            tester.expectOutput(result.output, "Key not found") and
            tester.expectOutput(result.output, "Active transactions: 0") and
            tester.expectNoError(result.error_output);
        
        if (success) {
            std.debug.print("  ✅ PASSED\n");
            passed_tests += 1;
        } else {
            std.debug.print("  ❌ FAILED\n");
            std.debug.print("  Output: {s}\n", .{result.output});
            std.debug.print("  Errors: {s}\n", .{result.error_output});
        }
    }

    // Test 4: Statistics commands
    {
        total_tests += 1;
        std.debug.print("🧪 Test 4: Statistics commands\n");
        
        var result = try tester.runCliCommand(
            \\put stats_test_key stats_test_value
            \\stats
            \\buffer_stats
            \\checkpoint_stats
            \\transactions
        );
        defer result.deinit(allocator);
        
        const success = result.success and
            tester.expectOutput(result.output, "OK") and
            tester.expectOutput(result.output, "Database Statistics") and
            tester.expectOutput(result.output, "Buffer Pool Statistics") and
            tester.expectOutput(result.output, "Checkpoint Statistics") and
            tester.expectOutput(result.output, "Active transactions:") and
            tester.expectNoError(result.error_output);
        
        if (success) {
            std.debug.print("  ✅ PASSED\n");
            passed_tests += 1;
        } else {
            std.debug.print("  ❌ FAILED\n");
            std.debug.print("  Output: {s}\n", .{result.output});
            std.debug.print("  Errors: {s}\n", .{result.error_output});
        }
    }

    // Test 5: WAL commands
    {
        total_tests += 1;
        std.debug.print("🧪 Test 5: WAL commands\n");
        
        var result = try tester.runCliCommand(
            \\put wal_test_key wal_test_value
            \\flush_wal
            \\checkpoint
            \\checkpoint_stats
        );
        defer result.deinit(allocator);
        
        const success = result.success and
            tester.expectOutput(result.output, "OK") and
            tester.expectOutput(result.output, "WAL flushed") and
            tester.expectOutput(result.output, "Checkpoint completed") and
            tester.expectOutput(result.output, "Checkpoint Statistics") and
            tester.expectNoError(result.error_output);
        
        if (success) {
            std.debug.print("  ✅ PASSED\n");
            passed_tests += 1;
        } else {
            std.debug.print("  ❌ FAILED\n");
            std.debug.print("  Output: {s}\n", .{result.output});
            std.debug.print("  Errors: {s}\n", .{result.error_output});
        }
    }

    // Test 6: Auto checkpoint commands
    {
        total_tests += 1;
        std.debug.print("🧪 Test 6: Auto checkpoint commands\n");
        
        var result = try tester.runCliCommand(
            \\auto_checkpoint start
            \\put auto_key auto_value
            \\auto_checkpoint stop
        );
        defer result.deinit(allocator);
        
        const success = result.success and
            tester.expectOutput(result.output, "Auto checkpoint started") and
            tester.expectOutput(result.output, "OK") and
            tester.expectOutput(result.output, "Auto checkpoint stopped") and
            tester.expectNoError(result.error_output);
        
        if (success) {
            std.debug.print("  ✅ PASSED\n");
            passed_tests += 1;
        } else {
            std.debug.print("  ❌ FAILED\n");
            std.debug.print("  Output: {s}\n", .{result.output});
            std.debug.print("  Errors: {s}\n", .{result.error_output});
        }
    }

    // Test 7: Configure checkpoint
    {
        total_tests += 1;
        std.debug.print("🧪 Test 7: Configure checkpoint\n");
        
        var result = try tester.runCliCommand(
            \\configure_checkpoint 1000 5 3
        );
        defer result.deinit(allocator);
        
        const success = result.success and
            tester.expectOutput(result.output, "Checkpoint configuration updated") and
            tester.expectNoError(result.error_output);
        
        if (success) {
            std.debug.print("  ✅ PASSED\n");
            passed_tests += 1;
        } else {
            std.debug.print("  ❌ FAILED\n");
            std.debug.print("  Output: {s}\n", .{result.output});
            std.debug.print("  Errors: {s}\n", .{result.error_output});
        }
    }

    // Test 8: Validate command
    {
        total_tests += 1;
        std.debug.print("🧪 Test 8: Validate command\n");
        
        var result = try tester.runCliCommand(
            \\put validate_key validate_value
            \\validate
        );
        defer result.deinit(allocator);
        
        const success = result.success and
            tester.expectOutput(result.output, "OK") and
            tester.expectOutput(result.output, "Database structure is valid") and
            tester.expectNoError(result.error_output);
        
        if (success) {
            std.debug.print("  ✅ PASSED\n");
            passed_tests += 1;
        } else {
            std.debug.print("  ❌ FAILED\n");
            std.debug.print("  Output: {s}\n", .{result.output});
            std.debug.print("  Errors: {s}\n", .{result.error_output});
        }
    }

    // Test 9: Error handling
    {
        total_tests += 1;
        std.debug.print("🧪 Test 9: Error handling\n");
        
        var result = try tester.runCliCommand(
            \\get nonexistent_key
            \\delete nonexistent_key
            \\commit 999
            \\tget 999 some_key
            \\invalid_command
        );
        defer result.deinit(allocator);
        
        const success = result.success and
            tester.expectOutput(result.output, "Key not found") and
            tester.expectOutput(result.output, "Key not found") and
            tester.expectOutput(result.output, "Error:") and
            tester.expectOutput(result.output, "Error:") and
            tester.expectOutput(result.output, "Unknown command: invalid_command");
        
        if (success) {
            std.debug.print("  ✅ PASSED\n");
            passed_tests += 1;
        } else {
            std.debug.print("  ❌ FAILED\n");
            std.debug.print("  Output: {s}\n", .{result.output});
            std.debug.print("  Errors: {s}\n", .{result.error_output});
        }
    }

    // Test 10: Isolation levels
    {
        total_tests += 1;
        std.debug.print("🧪 Test 10: Isolation levels\n");
        
        var result = try tester.runCliCommand(
            \\begin read_uncommitted
            \\commit 3
            \\begin repeatable_read
            \\commit 4
            \\begin serializable
            \\commit 5
        );
        defer result.deinit(allocator);
        
        const success = result.success and
            tester.expectOutput(result.output, "Transaction started with ID: 3") and
            tester.expectOutput(result.output, "Transaction 3 committed") and
            tester.expectOutput(result.output, "Transaction started with ID: 4") and
            tester.expectOutput(result.output, "Transaction 4 committed") and
            tester.expectOutput(result.output, "Transaction started with ID: 5") and
            tester.expectOutput(result.output, "Transaction 5 committed") and
            tester.expectNoError(result.error_output);
        
        if (success) {
            std.debug.print("  ✅ PASSED\n");
            passed_tests += 1;
        } else {
            std.debug.print("  ❌ FAILED\n");
            std.debug.print("  Output: {s}\n", .{result.output});
            std.debug.print("  Errors: {s}\n", .{result.error_output});
        }
    }

    // Final summary
    std.debug.print("\n=== CLI INTEGRATION TEST RESULTS ===\n");
    std.debug.print("Tests passed: {}/{}\n", .{ passed_tests, total_tests });
    std.debug.print("Success rate: {d:.1}%\n", .{@as(f64, @floatFromInt(passed_tests)) / @as(f64, @floatFromInt(total_tests)) * 100.0});
    
    if (passed_tests == total_tests) {
        std.debug.print("🎉 ALL CLI TESTS PASSED! 🎉\n");
        std.debug.print("The CLI interface is working correctly with all implemented commands.\n");
    } else {
        std.debug.print("💥 SOME TESTS FAILED\n");
        std.debug.print("CLI interface may have issues with some commands.\n");
    }
    
    // Clean up
    std.fs.cwd().deleteFile(test_db_path) catch {};
    std.fs.cwd().deleteFile("cli_integration_test.db.wal") catch {};
    
    std.debug.print("\n=== CLI INTEGRATION TEST COMPLETE ===\n");
}