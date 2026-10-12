/*
===============================================================================
 LEAST-LOADED CLASS PARTITION REFRESH - GUIDED DEMO / FUNCTIONAL SMOKE TEST
===============================================================================

PREREQUISITES

Run first, in this order:

1. schema.sql
2. demo_source.sql
3. register_process.sql
4. prepare_bootstrap.sql
5. prepare_incremental.sql
6. prepare_full.sql
7. get_dirty_class.sql
8. finalize_run.sql

This demo uses:

    total_classes      = 3
    insert_class_count = 2

The difference from the rotating window is concentrated in INSERT-class
selection: each Incremental run selects the m classes with the lowest row count
after applying the run's DELETEs.

IMPORTANT
---------
Run ONE BLOCK AT A TIME and verify the results indicated in the comments.
===============================================================================
*/


/* ============================================================================
   STEP 0 - CHECK INITIAL STATE

   EXPECTED on a clean database:
   - source_count      = 6
   - memory_count      = 0
   - load_memory_count = 0
   - run_count         = 0
============================================================================ */

SELECT COUNT(*) AS source_count
FROM dbo.demo_least_loaded_source;

SELECT COUNT(*) AS memory_count
FROM dbo.class_memory;

SELECT COUNT(*) AS load_memory_count
FROM dbo.class_load_memory;

SELECT COUNT(*) AS run_count
FROM dbo.refresh_run;


/* ============================================================================
   STEP 1 - REGISTER PROCESS

   Configuration:
   - 3 total classes
   - 2 classes selectable for INSERTs in each run
============================================================================ */

EXEC dbo.usp_register_refresh_process
    @ProcessName = N'demo_least_loaded',
    @AdapterSchema = N'dbo',
    @AdapterView = N'vw_demo_least_loaded_adapter',
    @TotalClasses = 3,
    @DefaultInsertClassCount = 2;

SELECT *
FROM dbo.refresh_process
WHERE process_name = N'demo_least_loaded';


/* ============================================================================
   STEP 2 - PREPARE BOOTSTRAP

   EXPECTED:
   - refresh_run_row       -> 6 rows
   - change_type           -> BOOTSTRAP for all rows
   - dirty classes         -> 1,2,3
   - candidate load        -> 2 rows per class

   The source_key -> class_id association is not semantically ordered:
   ROW_NUMBER produces only a technical offset.
============================================================================ */

DECLARE @BootstrapRun uniqueidentifier;

EXEC dbo.usp_prepare_bootstrap_run
    @ProcessName = N'demo_least_loaded',
    @RunId = @BootstrapRun OUTPUT;

SELECT @BootstrapRun AS bootstrap_run_id;

SELECT *
FROM dbo.refresh_run
WHERE run_id = @BootstrapRun;

SELECT *
FROM dbo.refresh_run_row
WHERE run_id = @BootstrapRun;

SELECT *
FROM dbo.refresh_run_dirty_class
WHERE run_id = @BootstrapRun
ORDER BY class_id;

SELECT
    class_id,
    candidate_row_count
FROM dbo.refresh_run_class_load
WHERE run_id = @BootstrapRun
ORDER BY class_id;


/* ============================================================================
   STEP 3 - FINALIZE BOOTSTRAP

   In a real system, FINALIZE must be called only after downstream success.

   EXPECTED AFTER FINALIZE:
   - refresh_run.status       = COMPLETED
   - class_memory             = 6 rows
   - class_load_memory        = 3 rows, 2 records per class
   - last_successful_run_id   = bootstrap RunId
   - RunId staging            = 0 rows
============================================================================ */

DECLARE @BootstrapRun uniqueidentifier;

SELECT @BootstrapRun = r.run_id
FROM dbo.refresh_run AS r
INNER JOIN dbo.refresh_process AS p
    ON p.process_id = r.process_id
WHERE p.process_name = N'demo_least_loaded'
  AND r.run_type = 'BOOTSTRAP'
  AND r.status = 'PREPARED';

EXEC dbo.usp_finalize_refresh_run
    @RunId = @BootstrapRun;

SELECT *
FROM dbo.refresh_run
WHERE run_id = @BootstrapRun;

SELECT
    m.source_key,
    m.last_timestamp,
    m.class_id
FROM dbo.class_memory AS m
INNER JOIN dbo.refresh_process AS p
    ON p.process_id = m.process_id
WHERE p.process_name = N'demo_least_loaded'
ORDER BY m.class_id, m.source_key;

SELECT
    l.class_id,
    l.known_row_count
FROM dbo.class_load_memory AS l
INNER JOIN dbo.refresh_process AS p
    ON p.process_id = l.process_id
WHERE p.process_name = N'demo_least_loaded'
ORDER BY l.class_id;

SELECT
    (SELECT COUNT(*) FROM dbo.refresh_run_row WHERE run_id = @BootstrapRun)
        AS run_row_after_finalize,
    (SELECT COUNT(*) FROM dbo.refresh_run_delete WHERE run_id = @BootstrapRun)
        AS delete_after_finalize,
    (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @BootstrapRun)
        AS dirty_after_finalize,
    (SELECT COUNT(*) FROM dbo.refresh_run_class_load WHERE run_id = @BootstrapRun)
        AS class_load_after_finalize;


/* ============================================================================
   STEP 4 - SIMULATE SOURCE CHANGES

   - 1 UPDATE
   - 1 DELETE
   - 5 INSERT

   The DELETE reduces its historical class by one row BEFORE selecting
   the two least-loaded classes.
============================================================================ */

UPDATE dbo.demo_least_loaded_source
SET
    event_timestamp = '2026-08-19T09:00:00',
    value_text = N'B v2'
WHERE source_key = N'B002';

DELETE dbo.demo_least_loaded_source
WHERE source_key = N'D004';

INSERT dbo.demo_least_loaded_source
(
    source_key,
    event_timestamp,
    value_text
)
VALUES
    (N'N001', '2026-08-19T10:00:00', N'new 1'),
    (N'N002', '2026-08-19T10:01:00', N'new 2'),
    (N'N003', '2026-08-19T10:02:00', N'new 3'),
    (N'N004', '2026-08-19T10:03:00', N'new 4'),
    (N'N005', '2026-08-19T10:04:00', N'new 5');

SELECT *
FROM dbo.demo_least_loaded_source
ORDER BY source_key;


/* ============================================================================
   STEP 5 - PREPARE INCREMENTAL

   The run must:
   - preserve the class of known keys;
   - detect UPDATEs and DELETEs;
   - subtract DELETEs from the official counts;
   - order classes by selection_row_count;
   - select the first 2;
   - assign insert_rank 1 and 2 to the selected classes;
   - number the new INSERTs;
   - convert ROW_NUMBER into slots 1..2 via modulo;
   - JOIN slot = insert_rank;
   - calculate candidate counts.
============================================================================ */

DECLARE @IncrementalRun uniqueidentifier;

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'demo_least_loaded',
    @RunId = @IncrementalRun OUTPUT;

SELECT @IncrementalRun AS incremental_run_id;

SELECT *
FROM dbo.refresh_run
WHERE run_id = @IncrementalRun;

/* Classes selected for the run's INSERTs. */
SELECT
    class_id,
    insert_rank,
    starting_row_count,
    deleted_row_count,
    selection_row_count,
    inserted_row_count,
    candidate_row_count
FROM dbo.refresh_run_class_load
WHERE run_id = @IncrementalRun
  AND is_insert_target = 1
ORDER BY insert_rank;

/* Actual mapping of new records. */
SELECT
    source_key,
    class_id,
    change_type
FROM dbo.refresh_run_row
WHERE run_id = @IncrementalRun
  AND change_type = 'INSERT'
ORDER BY source_key;

/* UPDATE: historical class unchanged. */
SELECT
    source_key,
    class_id,
    change_type
FROM dbo.refresh_run_row
WHERE run_id = @IncrementalRun
  AND change_type = 'UPDATE';

/* DELETE: the historical class is retained in run staging. */
SELECT *
FROM dbo.refresh_run_delete
WHERE run_id = @IncrementalRun;

/* Dirty set = INSERT_CLASSES U UPDATE_CLASSES U DELETE_CLASSES. */
SELECT class_id
FROM dbo.refresh_run_dirty_class
WHERE run_id = @IncrementalRun
ORDER BY class_id;

/* All candidate counts for the run. */
SELECT
    class_id,
    starting_row_count,
    deleted_row_count,
    selection_row_count,
    inserted_row_count,
    candidate_row_count,
    is_insert_target,
    insert_rank
FROM dbo.refresh_run_class_load
WHERE run_id = @IncrementalRun
ORDER BY class_id;


/* ============================================================================
   STEP 6 - FINALIZE INCREMENTAL

   EXPECTED:
   - class_memory becomes the run's candidate snapshot;
   - class_load_memory receives candidate_row_count;
   - refresh_run remains COMPLETED;
   - all operational staging for the RunId is removed.
============================================================================ */

DECLARE @IncrementalRun uniqueidentifier;

SELECT @IncrementalRun = r.run_id
FROM dbo.refresh_run AS r
INNER JOIN dbo.refresh_process AS p
    ON p.process_id = r.process_id
WHERE p.process_name = N'demo_least_loaded'
  AND r.run_type = 'INCREMENTAL'
  AND r.status = 'PREPARED';

EXEC dbo.usp_finalize_refresh_run
    @RunId = @IncrementalRun;

SELECT *
FROM dbo.refresh_run
WHERE run_id = @IncrementalRun;

SELECT
    l.class_id,
    l.known_row_count
FROM dbo.class_load_memory AS l
INNER JOIN dbo.refresh_process AS p
    ON p.process_id = l.process_id
WHERE p.process_name = N'demo_least_loaded'
ORDER BY l.class_id;

SELECT
    (SELECT COUNT(*) FROM dbo.class_memory AS m
     INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
     WHERE p.process_name = N'demo_least_loaded') AS memory_rows,
    (SELECT SUM(l.known_row_count) FROM dbo.class_load_memory AS l
     INNER JOIN dbo.refresh_process AS p ON p.process_id = l.process_id
     WHERE p.process_name = N'demo_least_loaded') AS load_memory_rows;

SELECT
    (SELECT COUNT(*) FROM dbo.refresh_run_row WHERE run_id = @IncrementalRun)
        AS run_row_after_finalize,
    (SELECT COUNT(*) FROM dbo.refresh_run_delete WHERE run_id = @IncrementalRun)
        AS delete_after_finalize,
    (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @IncrementalRun)
        AS dirty_after_finalize,
    (SELECT COUNT(*) FROM dbo.refresh_run_class_load WHERE run_id = @IncrementalRun)
        AS class_load_after_finalize;


/* ============================================================================
   STEP 7 - PREPARE FOR FULL

   Add a new unclassified key and modify a known key.

   FULL must:
   - include only keys already known in class_memory;
   - preserve historical class_id values;
   - ignore FULL-NEW;
   - make all classes dirty;
   - keep counts for known classes consistent.
============================================================================ */

INSERT dbo.demo_least_loaded_source
(
    source_key,
    event_timestamp,
    value_text
)
VALUES
    (N'FULL-NEW', '2026-08-19T11:00:00', N'not classified by full');

UPDATE dbo.demo_least_loaded_source
SET
    event_timestamp = '2026-08-19T11:05:00',
    value_text = N'A changed before full'
WHERE source_key = N'A001';


/* ============================================================================
   STEP 8 - PREPARE FULL
============================================================================ */

DECLARE @FullRun uniqueidentifier;

EXEC dbo.usp_prepare_full_run
    @ProcessName = N'demo_least_loaded',
    @RunId = @FullRun OUTPUT;

SELECT @FullRun AS full_run_id;

SELECT *
FROM dbo.refresh_run
WHERE run_id = @FullRun;

SELECT *
FROM dbo.refresh_run_row
WHERE run_id = @FullRun
ORDER BY class_id, source_key;

SELECT *
FROM dbo.refresh_run_dirty_class
WHERE run_id = @FullRun
ORDER BY class_id;

SELECT
    class_id,
    starting_row_count,
    deleted_row_count,
    candidate_row_count
FROM dbo.refresh_run_class_load
WHERE run_id = @FullRun
ORDER BY class_id;

/* Must return zero rows. */
SELECT *
FROM dbo.refresh_run_row
WHERE run_id = @FullRun
  AND source_key = N'FULL-NEW';


/* ============================================================================
   STEP 9 - FINALIZE FULL

   FULL-NEW must remain outside memory and will be classified by a future
   Incremental run. Here too, run staging is removed after success.
============================================================================ */

DECLARE @FullRun uniqueidentifier;

SELECT @FullRun = r.run_id
FROM dbo.refresh_run AS r
INNER JOIN dbo.refresh_process AS p
    ON p.process_id = r.process_id
WHERE p.process_name = N'demo_least_loaded'
  AND r.run_type = 'FULL'
  AND r.status = 'PREPARED';

EXEC dbo.usp_finalize_refresh_run
    @RunId = @FullRun;

SELECT *
FROM dbo.refresh_run
WHERE run_id = @FullRun;

SELECT
    m.source_key,
    m.last_timestamp,
    m.class_id
FROM dbo.class_memory AS m
INNER JOIN dbo.refresh_process AS p
    ON p.process_id = m.process_id
WHERE p.process_name = N'demo_least_loaded'
ORDER BY m.class_id, m.source_key;

SELECT
    l.class_id,
    l.known_row_count
FROM dbo.class_load_memory AS l
INNER JOIN dbo.refresh_process AS p
    ON p.process_id = l.process_id
WHERE p.process_name = N'demo_least_loaded'
ORDER BY l.class_id;

/* Must return zero rows: FULL-NEW was not classified. */
SELECT m.*
FROM dbo.class_memory AS m
INNER JOIN dbo.refresh_process AS p
    ON p.process_id = m.process_id
WHERE p.process_name = N'demo_least_loaded'
  AND m.source_key = N'FULL-NEW';

SELECT
    (SELECT COUNT(*) FROM dbo.refresh_run_row WHERE run_id = @FullRun)
        AS run_row_after_finalize,
    (SELECT COUNT(*) FROM dbo.refresh_run_delete WHERE run_id = @FullRun)
        AS delete_after_finalize,
    (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @FullRun)
        AS dirty_after_finalize,
    (SELECT COUNT(*) FROM dbo.refresh_run_class_load WHERE run_id = @FullRun)
        AS class_load_after_finalize;
