const std = @import("std");

const RedisClient = @import("redis.zig").RedisClient;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create Redis client
    var client = try RedisClient.init(allocator, "127.0.0.1", 6379);
    defer client.deinit();

    std.debug.print("Connected to Redis server\n", .{});

    // Set a key
    try client.set("hello", "world");
    std.debug.print("Set hello -> world\n", .{});

    // Get a key
    if (try client.get("hello")) |value| {
        std.debug.print("Got hello -> {s}\n", .{value});
    } else {
        std.debug.print("Key not found\n", .{});
    }
}
