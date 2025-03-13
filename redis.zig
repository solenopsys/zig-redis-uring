const std = @import("std");
const net = std.net;
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const RedisError = error{
    ConnectionFailed,
    ReadError,
    WriteError,
    CommandFailed,
    ParseError,
    IoUringError,
};

pub const RedisClient = struct {
    allocator: Allocator,
    socket: posix.fd_t,
    ring: linux.IoUring,
    buffer: []u8,
    connected: bool,

    const ResponseType = enum {
        String,
        Error,
        Integer,
        BulkString,
        Array,
        Unknown,
    };

    pub fn init(allocator: Allocator, host: []const u8, port: u16) !RedisClient {
        // Create a socket
        const socket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
        errdefer posix.close(socket);

        // Connect to the Redis server
        const address = try net.Address.parseIp(host, port);
        posix.connect(socket, &address.any, address.getOsSockLen()) catch {
            return RedisError.ConnectionFailed;
        };

        // Initialize io_uring
        var ring_params = std.mem.zeroes(linux.io_uring_params);
        const ring_size: u13 = 32; // Small ring size for minimal client
        var ring = try linux.IoUring.init_params(ring_size, &ring_params);
        errdefer ring.deinit();

        // Allocate buffer for responses
        const buffer = try allocator.alloc(u8, 4096);
        errdefer allocator.free(buffer);

        return RedisClient{
            .allocator = allocator,
            .socket = socket,
            .ring = ring,
            .buffer = buffer,
            .connected = true,
        };
    }

    pub fn deinit(self: *RedisClient) void {
        if (self.connected) {
            posix.close(self.socket);
            self.connected = false;
        }
        self.ring.deinit();
        self.allocator.free(self.buffer);
    }

    // Set a string value
    pub fn set(self: *RedisClient, key: []const u8, value: []const u8) !void {
        // Format the Redis SET command
        const command = try std.fmt.allocPrint(self.allocator, "*3\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{ key.len, key, value.len, value });
        defer self.allocator.free(command);

        _ = try self.executeCommand(command);
    }

    // Get a string value
    pub fn get(self: *RedisClient, key: []const u8) !?[]const u8 {
        // Format the Redis GET command
        const command = try std.fmt.allocPrint(self.allocator, "*2\r\n$3\r\nGET\r\n${d}\r\n{s}\r\n", .{ key.len, key });
        defer self.allocator.free(command);

        const response = try self.executeCommand(command);

        // Parse the response to extract the value
        if (response) |resp| {
            // Check if the response is a nil bulk string
            if (resp.len >= 5 and std.mem.eql(u8, resp[0..5], "$-1\r\n")) {
                return null; // Key doesn't exist
            }

            // Parse bulk string response
            if (resp.len > 0 and resp[0] == '$') {
                // Заменено split на splitSequence
                var lines = std.mem.splitSequence(u8, resp, "\r\n");
                _ = lines.next(); // Skip the $<length> part
                if (lines.next()) |value| {
                    return value;
                }
            }

            return RedisError.ParseError;
        }

        return null;
    }

    // Delete a key
    pub fn del(self: *RedisClient, key: []const u8) !void {
        // Format the Redis DEL command
        const command = try std.fmt.allocPrint(self.allocator, "*2\r\n$3\r\nDEL\r\n${d}\r\n{s}\r\n", .{ key.len, key });
        defer self.allocator.free(command);

        _ = try self.executeCommand(command);
    }

    // Execute a Redis command using io_uring
    fn executeCommand(self: *RedisClient, command: []const u8) !?[]const u8 {
        if (!self.connected) {
            return RedisError.ConnectionFailed;
        }

        // Write command to socket with io_uring
        try self.writeCommand(command);

        // Read response with io_uring
        return try self.readResponse();
    }

    fn writeCommand(self: *RedisClient, command: []const u8) !void {
        const write_user_data: u64 = 1;

        // Submit write operation
        _ = try self.ring.write(write_user_data, self.socket, command, 0);

        // Wait for completion
        _ = try self.ring.submit_and_wait(1);

        // Process completion
        const cqe = try self.ring.copy_cqe();

        if (cqe.res < 0) {
            return RedisError.WriteError;
        }

        // Check if all bytes were written
        if (@as(usize, @intCast(cqe.res)) != command.len) {
            return RedisError.WriteError;
        }
    }

    fn readResponse(self: *RedisClient) !?[]const u8 {
        const read_user_data: u64 = 2;

        // Clear buffer
        @memset(self.buffer, 0);

        // Submit read operation
        _ = try self.ring.read(read_user_data, self.socket, .{ .buffer = self.buffer }, 0);

        // Wait for completion
        _ = try self.ring.submit_and_wait(1);

        // Process completion
        const cqe = try self.ring.copy_cqe();

        if (cqe.res <= 0) {
            return RedisError.ReadError;
        }

        const bytes_read: usize = @intCast(cqe.res);

        // Check for error response
        if (bytes_read > 0 and self.buffer[0] == '-') {
            return RedisError.CommandFailed;
        }

        return self.buffer[0..bytes_read];
    }
};
