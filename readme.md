# Minimalist Redis client for Zig

Supports linux io_uring technology

Supports only 
- get 
- set



## Example 

``` 
zig run example.zig 
```




## Benchmark on KeyDB
```
zig run -O ReleaseFast  bench.zig
```
Results

```
 
Running Redis multithreaded benchmark with 16 threads and 10000 operations per thread (total: 160000)...

===== Redis Multithreaded Benchmark =====

Run 1/3
BATCH SET: 105400.97 ops/sec (total across all threads)
BATCH GET: 104228.45 ops/sec (total across all threads)

Run 2/3
BATCH SET: 105083.75 ops/sec (total across all threads)
BATCH GET: 104271.81 ops/sec (total across all threads)

Run 3/3
BATCH SET: 104006.65 ops/sec (total across all threads)
BATCH GET: 103869.09 ops/sec (total across all threads)

===== Average Results =====
Average BATCH SET: 104830.46 ops/sec
Average BATCH GET: 104123.12 ops/sec
============================
```