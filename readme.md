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
zig run -O ReleaseFast  src/bench.zig
```
Results

```
 
Running Redis multithreaded benchmark with 16 threads and 10000 operations per thread (total: 160000)...

===== Redis Multithreaded Benchmark =====

Run 1/3
BATCH SET: 104523.19 ops/sec (total across all threads)
BATCH GET: 106742.29 ops/sec (total across all threads)

Run 2/3
BATCH SET: 108048.03 ops/sec (total across all threads)
BATCH GET: 105104.02 ops/sec (total across all threads)

Run 3/3
BATCH SET: 107039.88 ops/sec (total across all threads)
BATCH GET: 107139.94 ops/sec (total across all threads)

===== Average Results =====
Average BATCH SET: 106537.03 ops/sec
Average BATCH GET: 106328.75 ops/sec
============================
```