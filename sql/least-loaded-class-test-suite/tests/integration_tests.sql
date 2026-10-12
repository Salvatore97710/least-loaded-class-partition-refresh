USE LeastLoadedClassDemo;
GO

/*
===============================================================================
 AUTOMATED INTEGRATION TESTS - LEAST-LOADED CLASS STRATEGY
===============================================================================

Assumptions:
- framework SQL files are already installed in LeastLoadedClassDemo;
- DELETE classes are active dirty-class contributors;
- class_load_memory stores the official current number of rows per class;
- successful FINALIZE removes operational staging for the completed RunId:
  refresh_run_row, refresh_run_delete, refresh_run_dirty_class,
  refresh_run_class_load;
- refresh_run remains as lightweight audit history.

PASS:
    the script reaches ALL AUTOMATED INTEGRATION TESTS PASSED.

FAIL:
    an assertion raises error 570xx.
===============================================================================
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---------------------------------------------------------------------------
   CLEAN PREVIOUS TEST STATE
--------------------------------------------------------------------------- */
DECLARE
    @ProcessId int,
    @CleanupRunId uniqueidentifier;

DECLARE process_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT process_id
    FROM dbo.refresh_process
    WHERE process_name IN (N'test_least_loaded_ci', N'test_least_loaded_repeat');

OPEN process_cursor;
FETCH NEXT FROM process_cursor INTO @ProcessId;

WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE cleanup_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT run_id
        FROM dbo.refresh_run
        WHERE process_id = @ProcessId;

    OPEN cleanup_cursor;
    FETCH NEXT FROM cleanup_cursor INTO @CleanupRunId;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DELETE FROM dbo.refresh_run_dirty_class
        WHERE run_id = @CleanupRunId;

        DELETE FROM dbo.refresh_run_delete
        WHERE run_id = @CleanupRunId;

        DELETE FROM dbo.refresh_run_class_load
        WHERE run_id = @CleanupRunId;

        DELETE FROM dbo.refresh_run_row
        WHERE run_id = @CleanupRunId;

        DELETE FROM dbo.refresh_run
        WHERE run_id = @CleanupRunId;

        FETCH NEXT FROM cleanup_cursor INTO @CleanupRunId;
    END;

    CLOSE cleanup_cursor;
    DEALLOCATE cleanup_cursor;

    DELETE FROM dbo.class_memory
    WHERE process_id = @ProcessId;

    DELETE FROM dbo.class_load_memory
    WHERE process_id = @ProcessId;

    DELETE FROM dbo.refresh_process
    WHERE process_id = @ProcessId;

    FETCH NEXT FROM process_cursor INTO @ProcessId;
END;

CLOSE process_cursor;
DEALLOCATE process_cursor;
GO

DROP VIEW IF EXISTS dbo.vw_test_least_loaded_adapter;
DROP TABLE IF EXISTS dbo.test_least_loaded_source;
DROP VIEW IF EXISTS dbo.vw_test_least_loaded_repeat_adapter;
DROP TABLE IF EXISTS dbo.test_least_loaded_repeat_source;
GO

CREATE TABLE dbo.test_least_loaded_source
(
    source_key       nvarchar(100) NOT NULL
        CONSTRAINT PK_test_least_loaded_source PRIMARY KEY,
    event_timestamp  datetime2(7) NOT NULL,
    value_text       nvarchar(200) NOT NULL
);
GO

CREATE VIEW dbo.vw_test_least_loaded_adapter
AS
SELECT
    CONVERT(nvarchar(450), source_key) AS source_key,
    event_timestamp,
    (
        SELECT
            source_key AS [source_key],
            event_timestamp AS [event_timestamp],
            value_text AS [value_text]
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    ) AS payload_json
FROM dbo.test_least_loaded_source;
GO

INSERT dbo.test_least_loaded_source
(
    source_key,
    event_timestamp,
    value_text
)
VALUES
    (N'A001', '2026-08-19T08:00:00', N'A v1'),
    (N'B002', '2026-08-19T08:01:00', N'B v1'),
    (N'C003', '2026-08-19T08:02:00', N'C v1'),
    (N'D004', '2026-08-19T08:03:00', N'D v1'),
    (N'E005', '2026-08-19T08:04:00', N'E v1'),
    (N'F006', '2026-08-19T08:05:00', N'F v1');
GO

PRINT 'TEST 01 - register process';

EXEC dbo.usp_register_refresh_process
    @ProcessName = N'test_least_loaded_ci',
    @AdapterSchema = N'dbo',
    @AdapterView = N'vw_test_least_loaded_adapter',
    @TotalClasses = 3,
    @DefaultInsertClassCount = 2;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_process
    WHERE process_name = N'test_least_loaded_ci'
      AND total_classes = 3
      AND default_insert_class_count = 2
      AND last_successful_run_id IS NULL
)
    THROW 57001, 'TEST 01 FAILED: unexpected process configuration.', 1;

PRINT 'PASS 01';


/* ============================================================================
   TEST 02 - BOOTSTRAP + CLASS LOAD MEMORY
============================================================================ */
PRINT 'TEST 02 - bootstrap prepare/finalize';

DECLARE @BootstrapRun uniqueidentifier;

EXEC dbo.usp_prepare_bootstrap_run
    @ProcessName = N'test_least_loaded_ci',
    @RunId = @BootstrapRun OUTPUT;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @BootstrapRun
      AND run_type = 'BOOTSTRAP'
      AND insert_count = 6
      AND update_count = 0
      AND delete_count = 0
      AND dirty_class_count = 3
      AND status = 'PREPARED'
)
    THROW 57002, 'TEST 02 FAILED: unexpected BOOTSTRAP header.', 1;

IF (SELECT COUNT(*) FROM dbo.refresh_run_row WHERE run_id = @BootstrapRun) <> 6
    THROW 57003, 'TEST 02 FAILED: bootstrap must materialize 6 rows.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @BootstrapRun
      AND (change_type <> 'BOOTSTRAP' OR class_id NOT BETWEEN 1 AND 3)
)
    THROW 57004, 'TEST 02 FAILED: invalid BOOTSTRAP change_type/class_id values.', 1;

IF (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @BootstrapRun) <> 3
    THROW 57005, 'TEST 02 FAILED: bootstrap must make 3 classes dirty.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_class_load
    WHERE run_id = @BootstrapRun
      AND candidate_row_count <> 2
)
   OR (SELECT COUNT(*) FROM dbo.refresh_run_class_load WHERE run_id = @BootstrapRun) <> 3
    THROW 57006, 'TEST 02 FAILED: BOOTSTRAP candidate load is not balanced 2-2-2.', 1;

EXEC dbo.usp_finalize_refresh_run
    @RunId = @BootstrapRun;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @BootstrapRun
      AND status = 'COMPLETED'
      AND completed_at IS NOT NULL
)
    THROW 57007, 'TEST 02 FAILED: bootstrap is not COMPLETED.', 1;

IF
(
    SELECT COUNT(*)
    FROM dbo.class_memory AS m
    INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
    WHERE p.process_name = N'test_least_loaded_ci'
) <> 6
    THROW 57008, 'TEST 02 FAILED: class_memory must contain 6 rows.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.class_load_memory AS l
    INNER JOIN dbo.refresh_process AS p ON p.process_id = l.process_id
    WHERE p.process_name = N'test_least_loaded_ci'
      AND l.known_row_count <> 2
)
   OR
(
    SELECT COUNT(*)
    FROM dbo.class_load_memory AS l
    INNER JOIN dbo.refresh_process AS p ON p.process_id = l.process_id
    WHERE p.process_name = N'test_least_loaded_ci'
) <> 3
    THROW 57009, 'TEST 02 FAILED: unexpected official class_load_memory.', 1;

IF EXISTS (SELECT 1 FROM dbo.refresh_run_row WHERE run_id = @BootstrapRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_delete WHERE run_id = @BootstrapRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_dirty_class WHERE run_id = @BootstrapRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_class_load WHERE run_id = @BootstrapRun)
    THROW 57038, 'TEST 02 FAILED: BOOTSTRAP staging was not cleaned after finalize.', 1;

PRINT 'PASS 02';


/* ============================================================================
   TEST 03 - MIXED INCREMENTAL: LEAST-LOADED SELECTION
============================================================================ */
PRINT 'TEST 03 - mixed incremental / least-loaded selection';

DECLARE
    @DeleteClass int,
    @SecondTargetClass int;

SELECT @DeleteClass = m.class_id
FROM dbo.class_memory AS m
INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
WHERE p.process_name = N'test_least_loaded_ci'
  AND m.source_key = N'D004';

UPDATE dbo.test_least_loaded_source
SET
    event_timestamp = '2026-08-19T09:00:00',
    value_text = N'B v2'
WHERE source_key = N'B002';

DELETE dbo.test_least_loaded_source
WHERE source_key = N'D004';

INSERT dbo.test_least_loaded_source
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

DECLARE @IncrementalRun uniqueidentifier;

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_least_loaded_ci',
    @RunId = @IncrementalRun OUTPUT;

/*
  With equal selection_row_count, no specific class_id is required.
  Therefore, store the second class actually selected by the run.
*/
SELECT @SecondTargetClass = class_id
FROM dbo.refresh_run_class_load
WHERE run_id = @IncrementalRun
  AND is_insert_target = 1
  AND insert_rank = 2;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @IncrementalRun
      AND run_type = 'INCREMENTAL'
      AND insert_class_count = 2
      AND insert_count = 5
      AND update_count = 1
      AND delete_count = 1
      AND status = 'PREPARED'
)
    THROW 57010, 'TEST 03 FAILED: unexpected incremental header.', 1;

IF (SELECT COUNT(*) FROM dbo.refresh_run_row WHERE run_id = @IncrementalRun) <> 10
    THROW 57011, 'TEST 03 FAILED: incremental snapshot must contain 10 rows.', 1;

/* The DELETE class must be rank 1: after the DELETE it has 1 row. */
IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_class_load
    WHERE run_id = @IncrementalRun
      AND class_id = @DeleteClass
      AND is_insert_target = 1
      AND insert_rank = 1
      AND starting_row_count = 2
      AND deleted_row_count = 1
      AND selection_row_count = 1
      AND inserted_row_count = 3
      AND candidate_row_count = 4
)
    THROW 57012, 'TEST 03 FAILED: unexpected first least-loaded class.', 1;

/* The second class may be either of the two remaining at load 2. */
IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_class_load
    WHERE run_id = @IncrementalRun
      AND class_id = @SecondTargetClass
      AND is_insert_target = 1
      AND insert_rank = 2
      AND starting_row_count = 2
      AND deleted_row_count = 0
      AND selection_row_count = 2
      AND inserted_row_count = 2
      AND candidate_row_count = 4
)
    THROW 57013, 'TEST 03 FAILED: unexpected second least-loaded class.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @IncrementalRun
      AND change_type = 'INSERT'
      AND class_id NOT IN (@DeleteClass, @SecondTargetClass)
)
    THROW 57014, 'TEST 03 FAILED: INSERT assigned outside the selected least-loaded classes.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row AS rr
    INNER JOIN dbo.class_memory AS m
        ON m.source_key = rr.source_key
    INNER JOIN dbo.refresh_process AS p
        ON p.process_id = m.process_id
    WHERE rr.run_id = @IncrementalRun
      AND p.process_name = N'test_least_loaded_ci'
      AND rr.source_key = N'B002'
      AND rr.change_type = 'UPDATE'
      AND rr.class_id = m.class_id
)
    THROW 57015, 'TEST 03 FAILED: UPDATE must preserve the historical class.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_delete AS d
    WHERE d.run_id = @IncrementalRun
      AND d.source_key = N'D004'
      AND d.class_id = @DeleteClass
)
    THROW 57016, 'TEST 03 FAILED: DELETE not detected with its historical class.', 1;

/* Dirty set must match INSERT U UPDATE U DELETE. */
IF EXISTS
(
    SELECT expected.class_id
    FROM
    (
        SELECT DISTINCT class_id
        FROM dbo.refresh_run_row
        WHERE run_id = @IncrementalRun
          AND change_type IN ('INSERT','UPDATE')

        UNION

        SELECT DISTINCT class_id
        FROM dbo.refresh_run_delete
        WHERE run_id = @IncrementalRun
    ) AS expected
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM dbo.refresh_run_dirty_class AS actual
        WHERE actual.run_id = @IncrementalRun
          AND actual.class_id = expected.class_id
    )
)
    THROW 57017, 'TEST 03 FAILED: an expected dirty class is missing.', 1;

IF EXISTS
(
    SELECT actual.class_id
    FROM dbo.refresh_run_dirty_class AS actual
    WHERE actual.run_id = @IncrementalRun
      AND NOT EXISTS
      (
          SELECT 1
          FROM
          (
              SELECT DISTINCT class_id
              FROM dbo.refresh_run_row
              WHERE run_id = @IncrementalRun
                AND change_type IN ('INSERT','UPDATE')

              UNION

              SELECT DISTINCT class_id
              FROM dbo.refresh_run_delete
              WHERE run_id = @IncrementalRun
          ) AS expected
          WHERE expected.class_id = actual.class_id
      )
)
    THROW 57018, 'TEST 03 FAILED: unjustified dirty class.', 1;

IF (SELECT SUM(candidate_row_count) FROM dbo.refresh_run_class_load WHERE run_id = @IncrementalRun)
   <> (SELECT COUNT_BIG(*) FROM dbo.test_least_loaded_source)
    THROW 57019, 'TEST 03 FAILED: candidate class load does not match the source.', 1;

EXEC dbo.usp_finalize_refresh_run @RunId = @IncrementalRun;

IF EXISTS
(
    SELECT 1
    FROM dbo.class_memory AS m
    INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
    WHERE p.process_name = N'test_least_loaded_ci'
      AND m.source_key = N'D004'
)
    THROW 57020, 'TEST 03 FAILED: DELETE must disappear from class_memory.', 1;

IF
(
    SELECT SUM(l.known_row_count)
    FROM dbo.class_load_memory AS l
    INNER JOIN dbo.refresh_process AS p ON p.process_id = l.process_id
    WHERE p.process_name = N'test_least_loaded_ci'
) <> 10
    THROW 57021, 'TEST 03 FAILED: unexpected total in class_load_memory.', 1;

IF EXISTS (SELECT 1 FROM dbo.refresh_run_row WHERE run_id = @IncrementalRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_delete WHERE run_id = @IncrementalRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_dirty_class WHERE run_id = @IncrementalRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_class_load WHERE run_id = @IncrementalRun)
    THROW 57039, 'TEST 03 FAILED: incremental staging was not cleaned after finalize.', 1;

PRINT 'PASS 03';


/* ============================================================================
   TEST 04 - DELETE-ONLY
============================================================================ */
PRINT 'TEST 04 - delete-only incremental';

DECLARE @DeletedClass int;

SELECT @DeletedClass = m.class_id
FROM dbo.class_memory AS m
INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
WHERE p.process_name = N'test_least_loaded_ci'
  AND m.source_key = N'C003';

DELETE dbo.test_least_loaded_source
WHERE source_key = N'C003';

DECLARE @DeleteOnlyRun uniqueidentifier;

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_least_loaded_ci',
    @RunId = @DeleteOnlyRun OUTPUT;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @DeleteOnlyRun
      AND insert_count = 0
      AND update_count = 0
      AND delete_count = 1
      AND insert_class_count = 2
)
    THROW 57022, 'TEST 04 FAILED: unexpected DELETE-only header.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_class_load
    WHERE run_id = @DeleteOnlyRun
      AND is_insert_target = 1
)
    THROW 57023, 'TEST 04 FAILED: DELETE-only must not select INSERT classes.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_dirty_class
    WHERE run_id = @DeleteOnlyRun
      AND class_id = @DeletedClass
)
    THROW 57024, 'TEST 04 FAILED: the historical DELETE class must be dirty.', 1;

EXEC dbo.usp_finalize_refresh_run @RunId = @DeleteOnlyRun;

IF EXISTS (SELECT 1 FROM dbo.refresh_run_row WHERE run_id = @DeleteOnlyRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_delete WHERE run_id = @DeleteOnlyRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_dirty_class WHERE run_id = @DeleteOnlyRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_class_load WHERE run_id = @DeleteOnlyRun)
    THROW 57040, 'TEST 04 FAILED: DELETE-only staging was not cleaned after finalize.', 1;

PRINT 'PASS 04';


/* ============================================================================
   TEST 05 - ZERO CHANGE
============================================================================ */
PRINT 'TEST 05 - zero-change incremental';

DECLARE @NoChangeRun uniqueidentifier;

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_least_loaded_ci',
    @RunId = @NoChangeRun OUTPUT;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @NoChangeRun
      AND insert_count = 0
      AND update_count = 0
      AND delete_count = 0
      AND dirty_class_count = 0
)
    THROW 57025, 'TEST 05 FAILED: unexpected zero-change run.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_class_load
    WHERE run_id = @NoChangeRun
      AND is_insert_target = 1
)
    THROW 57026, 'TEST 05 FAILED: zero-change must not select INSERT classes.', 1;

EXEC dbo.usp_finalize_refresh_run @RunId = @NoChangeRun;

IF EXISTS (SELECT 1 FROM dbo.refresh_run_row WHERE run_id = @NoChangeRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_delete WHERE run_id = @NoChangeRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_dirty_class WHERE run_id = @NoChangeRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_class_load WHERE run_id = @NoChangeRun)
    THROW 57041, 'TEST 05 FAILED: zero-change staging was not cleaned after finalize.', 1;

PRINT 'PASS 05';


/* ============================================================================
   TEST 06 - THE SAME CLASS CAN BE SELECTED IN CONSECUTIVE RUNS

   Isolated process:
   - bootstrap 12 rows / 3 classes -> 4,4,4;
   - delete 2 records from one class -> 2,4,4;
   - with m=1, one INSERT brings the class to 3 -> it remains the least loaded;
   - the next run must select it again -> 4,4,4.
============================================================================ */
PRINT 'TEST 06 - repeated least-loaded target';

CREATE TABLE dbo.test_least_loaded_repeat_source
(
    source_key       nvarchar(100) NOT NULL
        CONSTRAINT PK_test_least_loaded_repeat_source PRIMARY KEY,
    event_timestamp  datetime2(7) NOT NULL,
    value_text       nvarchar(200) NOT NULL
);
GO

CREATE VIEW dbo.vw_test_least_loaded_repeat_adapter
AS
SELECT
    CONVERT(nvarchar(450), source_key) AS source_key,
    event_timestamp,
    (
        SELECT source_key, event_timestamp, value_text
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    ) AS payload_json
FROM dbo.test_least_loaded_repeat_source;
GO

;WITH n AS
(
    SELECT TOP (12)
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
    FROM sys.all_objects
)
INSERT dbo.test_least_loaded_repeat_source
(
    source_key,
    event_timestamp,
    value_text
)
SELECT
    N'R' + RIGHT(N'000' + CONVERT(nvarchar(10), rn), 3),
    DATEADD(second, CONVERT(int, rn), CONVERT(datetime2(7), '2026-08-20T08:00:00')),
    N'repeat'
FROM n;

EXEC dbo.usp_register_refresh_process
    @ProcessName = N'test_least_loaded_repeat',
    @AdapterSchema = N'dbo',
    @AdapterView = N'vw_test_least_loaded_repeat_adapter',
    @TotalClasses = 3,
    @DefaultInsertClassCount = 2;

DECLARE @RepeatBootstrap uniqueidentifier;
EXEC dbo.usp_prepare_bootstrap_run
    @ProcessName = N'test_least_loaded_repeat',
    @RunId = @RepeatBootstrap OUTPUT;
EXEC dbo.usp_finalize_refresh_run @RunId = @RepeatBootstrap;

DECLARE @RepeatTargetClass int = 1;

;WITH to_delete AS
(
    SELECT TOP (2) m.source_key
    FROM dbo.class_memory AS m
    INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
    WHERE p.process_name = N'test_least_loaded_repeat'
      AND m.class_id = @RepeatTargetClass
    ORDER BY m.source_key
)
DELETE s
FROM dbo.test_least_loaded_repeat_source AS s
INNER JOIN to_delete AS d ON d.source_key = s.source_key;

DECLARE @RepeatDeleteRun uniqueidentifier;
EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_least_loaded_repeat',
    @RunId = @RepeatDeleteRun OUTPUT;
EXEC dbo.usp_finalize_refresh_run @RunId = @RepeatDeleteRun;

INSERT dbo.test_least_loaded_repeat_source
VALUES (N'R101', '2026-08-20T10:00:00', N'repeat insert 1');

DECLARE @RepeatRun1 uniqueidentifier;
EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_least_loaded_repeat',
    @InsertClassCount = 1,
    @RunId = @RepeatRun1 OUTPUT;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @RepeatRun1
      AND source_key = N'R101'
      AND change_type = 'INSERT'
      AND class_id = @RepeatTargetClass
)
    THROW 57027, 'TEST 06 FAILED: first run did not select the least-loaded class.', 1;

EXEC dbo.usp_finalize_refresh_run @RunId = @RepeatRun1;

INSERT dbo.test_least_loaded_repeat_source
VALUES (N'R102', '2026-08-20T10:01:00', N'repeat insert 2');

DECLARE @RepeatRun2 uniqueidentifier;
EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_least_loaded_repeat',
    @InsertClassCount = 1,
    @RunId = @RepeatRun2 OUTPUT;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @RepeatRun2
      AND source_key = N'R102'
      AND change_type = 'INSERT'
      AND class_id = @RepeatTargetClass
)
    THROW 57028, 'TEST 06 FAILED: the same class should have remained least-loaded.', 1;

EXEC dbo.usp_finalize_refresh_run @RunId = @RepeatRun2;

IF EXISTS
(
    SELECT 1
    FROM dbo.class_load_memory AS l
    INNER JOIN dbo.refresh_process AS p ON p.process_id = l.process_id
    WHERE p.process_name = N'test_least_loaded_repeat'
      AND l.known_row_count <> 4
)
    THROW 57029, 'TEST 06 FAILED: unexpected final 4-4-4 rebalance.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_process
    WHERE process_name = N'test_least_loaded_repeat'
      AND default_insert_class_count = 2
)
    THROW 57030, 'TEST 06 FAILED: per-run override changed the default.', 1;

PRINT 'PASS 06';
GO


/* ============================================================================
   TEST 07 - FULL IGNORES NEW UNCLASSIFIED KEYS
============================================================================ */
PRINT 'TEST 07 - full semantics';

INSERT dbo.test_least_loaded_source VALUES
    (N'FULL-NEW', '2026-08-19T13:00:00', N'unclassified');

UPDATE dbo.test_least_loaded_source
SET event_timestamp = '2026-08-19T13:05:00',
    value_text = N'A changed before full'
WHERE source_key = N'A001';

DECLARE
    @MemoryBeforeFull int,
    @FullRun uniqueidentifier;

SELECT @MemoryBeforeFull = COUNT(*)
FROM dbo.class_memory AS m
INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
WHERE p.process_name = N'test_least_loaded_ci';

EXEC dbo.usp_prepare_full_run
    @ProcessName = N'test_least_loaded_ci',
    @RunId = @FullRun OUTPUT;

IF (SELECT COUNT(*) FROM dbo.refresh_run_row WHERE run_id = @FullRun) <> @MemoryBeforeFull
    THROW 57031, 'TEST 07 FAILED: FULL must include only already-classified keys.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @FullRun
      AND source_key = N'FULL-NEW'
)
    THROW 57032, 'TEST 07 FAILED: FULL-NEW must not enter FULL.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @FullRun
      AND change_type <> 'FULL'
)
    THROW 57033, 'TEST 07 FAILED: all FULL rows must have change_type FULL.', 1;

IF (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @FullRun) <> 3
    THROW 57034, 'TEST 07 FAILED: FULL must make all classes dirty.', 1;

IF (SELECT SUM(candidate_row_count) FROM dbo.refresh_run_class_load WHERE run_id = @FullRun) <> @MemoryBeforeFull
    THROW 57035, 'TEST 07 FAILED: inconsistent FULL candidate load.', 1;

EXEC dbo.usp_finalize_refresh_run @RunId = @FullRun;

IF EXISTS
(
    SELECT 1
    FROM dbo.class_memory AS m
    INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
    WHERE p.process_name = N'test_least_loaded_ci'
      AND m.source_key = N'FULL-NEW'
)
    THROW 57036, 'TEST 07 FAILED: FULL-NEW must not enter memory.', 1;

IF EXISTS (SELECT 1 FROM dbo.refresh_run_row WHERE run_id = @FullRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_delete WHERE run_id = @FullRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_dirty_class WHERE run_id = @FullRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_class_load WHERE run_id = @FullRun)
    THROW 57042, 'TEST 07 FAILED: FULL staging was not cleaned after finalize.', 1;

PRINT 'PASS 07';


/* ============================================================================
   TEST 08 - DIRTY CLASS API
============================================================================ */
PRINT 'TEST 08 - usp_get_dirty_class';

UPDATE dbo.test_least_loaded_source
SET event_timestamp = DATEADD(second, 1, event_timestamp),
    value_text = N'B api test'
WHERE source_key = N'B002';

DECLARE
    @ApiRun uniqueidentifier,
    @ApiClass int;

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_least_loaded_ci',
    @RunId = @ApiRun OUTPUT;

SELECT TOP (1) @ApiClass = class_id
FROM dbo.refresh_run_dirty_class
WHERE run_id = @ApiRun
ORDER BY class_id;

CREATE TABLE #DirtyClassResult
(
    source_key       nvarchar(450),
    event_timestamp  datetime2(7),
    payload_json     nvarchar(max),
    class_id         int
);

INSERT #DirtyClassResult
EXEC dbo.usp_get_dirty_class
    @RunId = @ApiRun,
    @ClassId = @ApiClass;

IF (SELECT COUNT(*) FROM #DirtyClassResult) <>
   (SELECT COUNT(*) FROM dbo.refresh_run_row WHERE run_id = @ApiRun AND class_id = @ApiClass)
    THROW 57037, 'TEST 08 FAILED: usp_get_dirty_class does not match the snapshot.', 1;

IF EXISTS
(
    SELECT 1
    FROM #DirtyClassResult
    WHERE class_id <> @ApiClass
)
    THROW 57043, 'TEST 08 FAILED: usp_get_dirty_class returned another class.', 1;

DROP TABLE #DirtyClassResult;

EXEC dbo.usp_finalize_refresh_run @RunId = @ApiRun;

IF EXISTS (SELECT 1 FROM dbo.refresh_run_row WHERE run_id = @ApiRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_delete WHERE run_id = @ApiRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_dirty_class WHERE run_id = @ApiRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_class_load WHERE run_id = @ApiRun)
    THROW 57044, 'TEST 08 FAILED: API run staging was not cleaned after finalize.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @ApiRun
      AND status = 'COMPLETED'
)
    THROW 57045, 'TEST 08 FAILED: refresh_run history was not preserved as COMPLETED.', 1;

PRINT 'PASS 08';


/* ============================================================================
   FINAL INVARIANTS
============================================================================ */
IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row AS x
    INNER JOIN dbo.refresh_run AS r ON r.run_id = x.run_id
    INNER JOIN dbo.refresh_process AS p ON p.process_id = r.process_id
    WHERE p.process_name IN (N'test_least_loaded_ci', N'test_least_loaded_repeat')
      AND r.status = 'COMPLETED'
)
    THROW 57046, 'FINAL CHECK FAILED: refresh_run_row is present for a COMPLETED run.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_delete AS x
    INNER JOIN dbo.refresh_run AS r ON r.run_id = x.run_id
    INNER JOIN dbo.refresh_process AS p ON p.process_id = r.process_id
    WHERE p.process_name IN (N'test_least_loaded_ci', N'test_least_loaded_repeat')
      AND r.status = 'COMPLETED'
)
    THROW 57047, 'FINAL CHECK FAILED: refresh_run_delete is present for a COMPLETED run.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_dirty_class AS x
    INNER JOIN dbo.refresh_run AS r ON r.run_id = x.run_id
    INNER JOIN dbo.refresh_process AS p ON p.process_id = r.process_id
    WHERE p.process_name IN (N'test_least_loaded_ci', N'test_least_loaded_repeat')
      AND r.status = 'COMPLETED'
)
    THROW 57048, 'FINAL CHECK FAILED: dirty class is present for a COMPLETED run.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_class_load AS x
    INNER JOIN dbo.refresh_run AS r ON r.run_id = x.run_id
    INNER JOIN dbo.refresh_process AS p ON p.process_id = r.process_id
    WHERE p.process_name IN (N'test_least_loaded_ci', N'test_least_loaded_repeat')
      AND r.status = 'COMPLETED'
)
    THROW 57049, 'FINAL CHECK FAILED: class load staging is present for a COMPLETED run.', 1;

/* Official count memory must agree with official key memory for every class. */
IF EXISTS
(
    SELECT l.class_id
    FROM dbo.class_load_memory AS l
    INNER JOIN dbo.refresh_process AS p ON p.process_id = l.process_id
    OUTER APPLY
    (
        SELECT COUNT_BIG(*) AS actual_count
        FROM dbo.class_memory AS m
        WHERE m.process_id = l.process_id
          AND m.class_id = l.class_id
    ) AS c
    WHERE p.process_name IN (N'test_least_loaded_ci', N'test_least_loaded_repeat')
      AND l.known_row_count <> c.actual_count
)
    THROW 57050, 'FINAL CHECK FAILED: class_load_memory does not match class_memory.', 1;

PRINT '============================================================';
PRINT 'ALL AUTOMATED INTEGRATION TESTS PASSED';
PRINT '============================================================';

SELECT
    p.process_name,
    r.run_type,
    r.status,
    COUNT(*) AS runs
FROM dbo.refresh_run AS r
INNER JOIN dbo.refresh_process AS p ON p.process_id = r.process_id
WHERE p.process_name IN (N'test_least_loaded_ci', N'test_least_loaded_repeat')
GROUP BY p.process_name, r.run_type, r.status
ORDER BY p.process_name, r.run_type, r.status;
GO
