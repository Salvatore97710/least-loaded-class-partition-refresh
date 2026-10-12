# Least-Loaded Class Partition Refresh

Reference implementation of a **stable-class** refresh strategy for large, predominantly append-only fact tables.

This project is intentionally very close to a rotating-window strategy, but changes the criterion used to choose the classes available for new records:

```text
ROTATING WINDOW
-> classes determined by the window position

LEAST-LOADED
-> classes determined by the lowest current row count
```

## Project status

This repository is a **reference implementation / personal project in a prototypal stage**.

The goal is to demonstrate and validate the model, its invariants, and its trade-offs. It should not be considered an enterprise production-ready solution without further hardening, concurrency testing, and benchmarks on large datasets.

---

# The problem

Suppose we have a very large fact table with:

- a stable `source_key` identifying the record;
- a reliable timestamp representing creation or the latest update;
- a predominantly append-only flow;
- a downstream consumer that overwrites entire partitions.

The goal is not only to understand which rows have changed.

We want to control:

```text
which partitions become dirty
+
how many partitions are involved
+
how large the partitions selected to receive new records are
```

Purely time-based partitioning does not necessarily provide this control: volumes can differ greatly across periods, and a historical UPDATE can make a very large time partition dirty.

Here, the timestamp is used to detect change, while `class_id` is used to control the refresh.

---

# Algorithm idea

Each key receives a stable technical class:

```text
source_key -> class_id
```

Once classified, the key does not change class during UPDATE or FULL.

The main difference is in how INSERTs are handled.

The user configures, for example:

```text
total_classes       = 100
insert_class_count  = 10
```

At each Incremental run, the framework identifies the **10 classes with the fewest rows** and uses only those to distribute the new records.

The selected classes do not need to be contiguous:

```text
4
19
34
41
52
67
73
81
92
99
```

---

# Bootstrap

Bootstrap distributes the entire initial population using the same modulo rule as the stable-class version:

```text
class_id = (technical_offset % total_classes) + 1
```

`ROW_NUMBER()` produces only a technical offset; the source_key -> class_id assignment does not depend on a business key or on the timestamp.

## Initial count without COUNT per class

The number of rows per class is derived mathematically.

If:

```text
N = total number of rows
C = total_classes
```

then:

```text
q = N / C
r = N % C
```

Because the assignment is cyclic through modulo:

```text
classes 1 .. r       -> q + 1 rows
classes r+1 .. C     -> q rows
```

Example:

```text
N = 1000
C = 100

q = 10
r = 0

-> 10 rows per class
```

Example with remainder:

```text
N = 1003
C = 100

q = 10
r = 3

classes 1,2,3 -> 11 rows
others        -> 10 rows
```

The result is stored in `class_load_memory`.

This memory contains only:

```text
process_id
class_id
known_row_count
```

Therefore, a full `COUNT(*) GROUP BY class_id` is not executed on every run.

---

# Incremental

Incremental compares the current snapshot with `class_memory` and distinguishes:

```text
INSERT
UPDATE
DELETE
UNCHANGED
```

## 1. DELETE before selection

DELETEs are determined through an anti-join against `class_memory`.

Each DELETE retains its historical class.

To select the least-loaded classes, the framework starts from the official count and subtracts the DELETEs in the run:

```text
selection_row_count =
    known_row_count
    - delete_count_for_the_class
```

In this way, a class that has lost many records can immediately become a candidate to receive new INSERTs.

UPDATEs do not change the count because the key remains in the same class.

---

# Selecting the least-loaded classes

After mathematically applying the DELETE delta, all classes are ordered by:

```text
selection_row_count ASC
```

Classes with the same `selection_row_count` are equivalent for selection purposes: no specific ordering among them is required or guaranteed.

The first:

```text
insert_class_count
```

classes are then selected.

Example:

```text
insert_class_count = 10
```

Least-loaded classes found:

```text
class_id    row_count
--------    ---------
4           1200
19          1200
34          1201
41          1201
52          1203
67          1203
73          1204
81          1204
92          1205
99          1205
```

The classes can be completely non-contiguous.

Each selected class is assigned a technical index `insert_rank = 1..K`. When ties occur, the association between `class_id` and `insert_rank` is not meaningful and may vary.

One possible result is:

```text
class 4   -> insert_rank 1
class 19  -> insert_rank 2
class 34  -> insert_rank 3
...
class 99  -> insert_rank 10
```

---

# Distributing new INSERTs

New records also receive a technical index through `ROW_NUMBER()`.

With 500 INSERTs and 10 available classes:

```text
insert_slot = ((ROW_NUMBER() - 1) % 10) + 1
```

this produces:

```text
1,2,3,4,5,6,7,8,9,10,
1,2,3,4,5,6,7,8,9,10,
...
```

The final mapping is performed with a simple JOIN:

```text
INSERT.insert_slot
        =
selected_class.insert_rank
```

Therefore:

```text
slot 1  -> class 4
slot 2  -> class 19
slot 3  -> class 34
...
slot 10 -> class 99
```

With 500 INSERTs, each selected class receives 50 new records.

The distribution of new records therefore remains uniform **within the set of least-loaded classes selected for that run**.

---

# Mathematical count update

After assigning the INSERTs, the following is calculated for each class:

```text
candidate_row_count =
    known_row_count
    - deleted_row_count
    + inserted_row_count
```

UPDATEs are not part of the formula because they do not change the number of keys in the class.

The framework does not update `class_load_memory` immediately.

As with `class_memory`, the new state is first materialized in the run:

```text
refresh_run_class_load
```

Only after downstream success does `FINALIZE` promote both at the same time:

```text
refresh_run_row
    -> class_memory

refresh_run_class_load
    -> class_load_memory
```

This separation is fundamental for retry and consistency.

---

# Dirty classes

For an Incremental run:

```text
DIRTY_INCREMENTAL =
    INSERT_CLASSES
    UNION
    UPDATE_CLASSES
    UNION
    DELETE_CLASSES
```

INSERTs make dirty only the classes that actually received new records.

UPDATEs make the key's historical class dirty.

DELETEs make the historical class dirty so that the consumer can overwrite it with the current snapshot and remove the record downstream.

---

# Full

Full keeps the same general semantics:

```text
current snapshot
INNER JOIN
class_memory
```

New keys that have not yet been classified are ignored until the next Incremental run.

All classes become dirty.

Known keys that disappeared are detected so that both `class_memory` and `class_load_memory` remain consistent after Finalize.

---

# Operational flow

```text
                    PREPARE
                       |
                       v
                current snapshot
                       |
               compare with memory
                       |
        +--------------+--------------+
        |              |              |
      INSERT          UPDATE         DELETE
        |              |              |
        |        historical class historical class
        |
        v
official counts - DELETE
        |
        v
K least-loaded classes
        |
        v
class ranks 1..K
        |
        v
ROW_NUMBER new INSERTs
        |
        v
modulo K -> slots 1..K
        |
        v
JOIN slot = rank
        |
        v
class_id for new records
        |
        v
candidate class counts
        |
        v
PREPARED RUN
        |
        v
consumer overwrites dirty classes
        |
        v
      success?
       |     |
      NO    YES
       |     |
       |     v
       |  FINALIZE
       |     |
       v     v
retry same   new official memories
run_id
```

---

# Why it can be useful

Compared with a rotating window, this variant does not decide in advance which classes will receive the INSERTs.

It decides based on the actual state of the classes:

```text
rotating window
-> where is the window now?

least-loaded
-> which classes are smaller now?
```

This can be useful when DELETEs, historical distributions, or non-uniform batches have created size differences between partitions.

Smaller classes are automatically favored for new records.

---

# Important trade-off

The K classes are selected **once at the beginning of the run**, and the batch INSERTs are then distributed uniformly across those K classes.

This means we are not implementing a "choose the least-loaded class for every single row" algorithm.

With very large batches, a class that was initially small can temporarily grow beyond classes that were not selected.

Extreme example:

```text
class A = 10 rows
class B = 100 rows
K = 1
INSERT = 200
```

The run chooses A because it is the least loaded:

```text
A -> 210
B -> 100
```

In the next run, B becomes the least-loaded candidate.

The strategy therefore seeks **adaptive rebalancing across runs**, not perfect global balancing after every single record.

This trade-off keeps the number of partitions involved in each refresh simple and controllable.

---

# First prototype benchmark

A local benchmark was run on SQL Server Express to observe the behavior of the **Least-Loaded** strategy across multiple consecutive Incremental runs.

Configuration:

```text
initial rows            = 100,000
total_classes           = 100
insert_class_count      = 10
INSERTs per run         = 5,000
number of runs          = 10
```

The initial Bootstrap distributes the 100,000 rows across 100 classes:

```text
1,000 rows per class
```

Bootstrap is not included in the 10 runs reported below.

At each Incremental run, the 10 least-loaded classes at that moment are selected and the 5,000 new records are distributed uniformly across them:

```text
5,000 / 10 = 500 new records per selected class
```

Results from a single local execution:

| Run | Selected classes | Dirty classes | Inserted rows | Prepare ms | Finalize ms | Min rows/class | Max rows/class | Avg rows/class | Spread |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 10 | 10 | 5,000 | 7,685 | 7,308 | 1,000 | 1,500 | 1,050 | 500 |
| 2 | 10 | 10 | 5,000 | 8,270 | 7,213 | 1,000 | 1,500 | 1,100 | 500 |
| 3 | 10 | 10 | 5,000 | 8,024 | 7,379 | 1,000 | 1,500 | 1,150 | 500 |
| 4 | 10 | 10 | 5,000 | 9,093 | 9,148 | 1,000 | 1,500 | 1,200 | 500 |
| 5 | 10 | 10 | 5,000 | 9,009 | 8,055 | 1,000 | 1,500 | 1,250 | 500 |
| 6 | 10 | 10 | 5,000 | 9,052 | 9,083 | 1,000 | 1,500 | 1,300 | 500 |
| 7 | 10 | 10 | 5,000 | 9,493 | 9,415 | 1,000 | 1,500 | 1,350 | 500 |
| 8 | 10 | 10 | 5,000 | 10,078 | 9,256 | 1,000 | 1,500 | 1,400 | 500 |
| 9 | 10 | 10 | 5,000 | 10,048 | 9,970 | 1,000 | 1,500 | 1,450 | 500 |
| 10 | 10 | 10 | 5,000 | 10,258 | 9,716 | 1,500 | 1,500 | 1,500 | 0 |

The observed behavior is the expected one.

After the first run, 10 classes move from 1,000 to 1,500 rows, while the other 90 remain at 1,000. On the next run, other classes that are still less loaded are selected.

The process continues through the tenth run:

```text
run 1  -> 10 classes brought to 1,500
run 2  -> another 10 classes brought to 1,500
...
run 10 -> all 100 classes at 1,500
```

At the end of the cycle:

```text
min_rows_per_class = 1,500
max_rows_per_class = 1,500
avg_rows_per_class = 1,500
max_min_spread     = 0
```

In this regular scenario, adaptive least-loaded class selection therefore brings the distribution back to perfect balance after a full cycle.

The reported timings are only local prototype measurements and do not constitute a production-capacity estimate or a general performance comparison.

---

# Main invariants

```text
1. an already-classified source_key keeps its class_id

2. BOOTSTRAP initializes counts using modulo arithmetic

3. UPDATE does not change the number of rows in the class

4. DELETE subtracts one row from the historical class

5. INSERTs use only the selected K least-loaded classes

6. official counts change only with FINALIZE

7. a failed PREPARED run can be retried without recomputing the classes

8. FULL does not assign classes to new keys
```

---

# Goal

The central principle is:

> **keep classes stable, while dynamically choosing for each Incremental run the least-loaded partitions across which to distribute new records.**

The strategy therefore makes it possible to control the number of partitions involved by INSERTs while also reacting to actual class imbalance instead of following a predefined rotation.
