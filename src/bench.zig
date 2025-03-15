const std = @import("std");
const time = std.time;
const Thread = std.Thread;
const atomic = std.atomic;
const RedisClient = @import("redis.zig").RedisClient;

// Конфигурация для бенчмарка
const BenchConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    batch_size: usize = 10000, // Операций на поток
    key_prefix: []const u8 = "bench:",
    value_size: usize = 100,
    num_runs: usize = 3,
    num_threads: usize = 16, // Количество потоков
};

// Структура для передачи аргументов потоку
const ThreadArg = struct {
    allocator: std.mem.Allocator,
    thread_id: usize,
    config: *const BenchConfig,
    barrier: *Barrier,
    set_results: *std.ArrayList(f64),
    get_results: *std.ArrayList(f64),
};

// Простая реализация барьера для синхронизации потоков
const Barrier = struct {
    mutex: Thread.Mutex,
    cond: Thread.Condition,
    count: atomic.Value(usize),
    waiting: atomic.Value(usize),
    generation: atomic.Value(usize),

    pub fn init(count: usize) Barrier {
        return Barrier{
            .mutex = Thread.Mutex{},
            .cond = Thread.Condition{},
            .count = atomic.Value(usize).init(count),
            .waiting = atomic.Value(usize).init(0),
            .generation = atomic.Value(usize).init(0),
        };
    }

    pub fn wait(self: *Barrier) void {
        const mutex = &self.mutex;
        const cond = &self.cond;

        mutex.lock();
        defer mutex.unlock();

        const gen = self.generation.load(.monotonic);
        const wait_count = self.waiting.fetchAdd(1, .monotonic) + 1;

        if (wait_count == self.count.load(.monotonic)) {
            // Последний поток, достигший барьера
            self.waiting.store(0, .monotonic);
            _ = self.generation.fetchAdd(1, .monotonic);
            cond.broadcast();
        } else {
            // Ждем, пока все потоки достигнут барьера
            while (gen == self.generation.load(.monotonic)) {
                cond.wait(mutex);
            }
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = BenchConfig{};
    const total_operations = config.batch_size * config.num_threads;

    std.debug.print("Running Redis multithreaded benchmark with {d} threads and {d} operations per thread (total: {d})...\n", .{ config.num_threads, config.batch_size, total_operations });

    // Создаем барьер для синхронизации потоков
    var barrier = Barrier.init(config.num_threads);

    // Создаем списки для хранения результатов
    var set_results = std.ArrayList(f64).init(allocator);
    defer set_results.deinit();

    var get_results = std.ArrayList(f64).init(allocator);
    defer get_results.deinit();

    try runMultithreadedBenchmark(allocator, &config, &barrier, &set_results, &get_results);
}

fn runMultithreadedBenchmark(allocator: std.mem.Allocator, config: *const BenchConfig, barrier: *Barrier, set_results: *std.ArrayList(f64), get_results: *std.ArrayList(f64)) !void {
    std.debug.print("\n===== Redis Multithreaded Benchmark =====\n", .{});

    var total_set_ops_per_sec: f64 = 0;
    var total_get_ops_per_sec: f64 = 0;

    for (0..config.num_runs) |run| {
        std.debug.print("\nRun {d}/{d}\n", .{ run + 1, config.num_runs });

        // Очищаем предыдущие результаты
        set_results.clearRetainingCapacity();
        get_results.clearRetainingCapacity();

        // Создаем и запускаем потоки
        var threads = try allocator.alloc(Thread, config.num_threads);
        defer allocator.free(threads);

        var args = try allocator.alloc(ThreadArg, config.num_threads);
        defer allocator.free(args);

        for (0..config.num_threads) |i| {
            args[i] = ThreadArg{
                .allocator = allocator,
                .thread_id = i,
                .config = config,
                .barrier = barrier,
                .set_results = set_results,
                .get_results = get_results,
            };

            threads[i] = try Thread.spawn(.{}, workerThread, .{&args[i]});
        }

        // Ждем завершения всех потоков
        for (threads) |thread| {
            thread.join();
        }

        // Вычисляем общую производительность
        var run_set_ops_per_sec: f64 = 0;
        var run_get_ops_per_sec: f64 = 0;

        for (set_results.items) |ops| {
            run_set_ops_per_sec += ops;
        }

        for (get_results.items) |ops| {
            run_get_ops_per_sec += ops;
        }

        std.debug.print("BATCH SET: {d:.2} ops/sec (total across all threads)\n", .{run_set_ops_per_sec});
        std.debug.print("BATCH GET: {d:.2} ops/sec (total across all threads)\n", .{run_get_ops_per_sec});

        total_set_ops_per_sec += run_set_ops_per_sec;
        total_get_ops_per_sec += run_get_ops_per_sec;
    }

    // Вычисляем и выводим средние значения
    const avg_set_ops = total_set_ops_per_sec / @as(f64, @floatFromInt(config.num_runs));
    const avg_get_ops = total_get_ops_per_sec / @as(f64, @floatFromInt(config.num_runs));

    std.debug.print("\n===== Average Results =====\n", .{});
    std.debug.print("Average BATCH SET: {d:.2} ops/sec\n", .{avg_set_ops});
    std.debug.print("Average BATCH GET: {d:.2} ops/sec\n", .{avg_get_ops});
    std.debug.print("============================\n\n", .{});

    // Очистка не требуется, каждый поток очищает свои ключи
}

fn workerThread(arg: *ThreadArg) !void {
    const thread_id = arg.thread_id;
    const config = arg.config;
    const allocator = arg.allocator;
    const barrier = arg.barrier;

    // Подключаемся к Redis
    var client = try RedisClient.init(allocator, config.host, config.port);
    defer client.deinit();

    // Создаем тестовое значение указанного размера
    const test_value = try allocator.alloc(u8, config.value_size);
    defer allocator.free(test_value);
    for (test_value, 0..) |*byte, i| {
        byte.* = @as(u8, @truncate(i % 256));
    }

    // Генерируем ключи для этого потока
    var keys = std.ArrayList([]u8).init(allocator);
    defer {
        for (keys.items) |key| {
            allocator.free(key);
        }
        keys.deinit();
    }

    const start_idx = thread_id * config.batch_size;
    for (0..config.batch_size) |i| {
        const key = try std.fmt.allocPrint(allocator, "{s}{d}", .{ config.key_prefix, start_idx + i });
        try keys.append(key);
    }

    // Очищаем существующие ключи
    for (keys.items) |key| {
        _ = try client.set(key, "");
    }

    // Ждем, пока все потоки будут готовы к тесту SET
    barrier.wait();

    // Тестирование SET
    const set_start = time.nanoTimestamp();

    for (keys.items) |key| {
        _ = try client.set(key, test_value);
    }

    const set_end = time.nanoTimestamp();
    const set_duration_ns = @as(f64, @floatFromInt(set_end - set_start));
    const set_duration_sec = set_duration_ns / 1_000_000_000.0;
    const set_ops_per_sec = @as(f64, @floatFromInt(config.batch_size)) / set_duration_sec;

    try arg.set_results.append(set_ops_per_sec);

    // Ждем, пока все потоки завершат SET и будут готовы к тесту GET
    barrier.wait();

    // Тестирование GET
    const get_start = time.nanoTimestamp();

    for (keys.items) |key| {
        _ = try client.get(key);
    }

    const get_end = time.nanoTimestamp();
    const get_duration_ns = @as(f64, @floatFromInt(get_end - get_start));
    const get_duration_sec = get_duration_ns / 1_000_000_000.0;
    const get_ops_per_sec = @as(f64, @floatFromInt(config.batch_size)) / get_duration_sec;

    try arg.get_results.append(get_ops_per_sec);

    // Ждем, пока все потоки завершат GET
    barrier.wait();

    // Очищаем ключи этого потока
    for (keys.items) |key| {
        _ = try client.set(key, "");
    }
}
