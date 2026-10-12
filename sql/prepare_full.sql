CREATE OR ALTER PROCEDURE dbo.usp_prepare_full_run
    @ProcessName sysname,
    @RunId       uniqueidentifier OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @ProcessId int,
        @AdapterSchema sysname,
        @AdapterView sysname,
        @TotalClasses int,
        @Sql nvarchar(max),
        @LockResult int,
        @LockResource nvarchar(255);

    SELECT
        @ProcessId = process_id,
        @AdapterSchema = adapter_schema,
        @AdapterView = adapter_view,
        @TotalClasses = total_classes
    FROM dbo.refresh_process
    WHERE process_name = @ProcessName;

    IF @ProcessId IS NULL
        THROW 55300, 'Unknown process.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.class_memory
        WHERE process_id = @ProcessId
    )
        THROW 55301, 'Empty memory: the first load must be BOOTSTRAP.', 1;

    IF
    (
        SELECT COUNT(*)
        FROM dbo.class_load_memory
        WHERE process_id = @ProcessId
    ) <> @TotalClasses
        THROW 55301, 'Incomplete count memory: run BOOTSTRAP first.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.refresh_run
        WHERE process_id = @ProcessId
          AND status = 'PREPARED'
    )
        THROW 55302, 'A PREPARED run already exists.', 1;

    SET @RunId = NEWID();

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @LockResource =
            N'class-refresh:' + CONVERT(nvarchar(20), @ProcessId);

        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 0;

        IF @LockResult < 0
            THROW 55303, 'Process is locked.', 1;

        CREATE TABLE #snapshot
        (
            source_key       nvarchar(450) NOT NULL
                CONSTRAINT PK_full_snapshot PRIMARY KEY,
            event_timestamp  datetime2(7) NOT NULL,
            payload_json     nvarchar(max) NOT NULL
        );

        CREATE TABLE #deleted_by_class
        (
            class_id      int NOT NULL PRIMARY KEY,
            delete_count  bigint NOT NULL
        );

        SET @Sql = N'
            INSERT #snapshot
            (
                source_key,
                event_timestamp,
                payload_json
            )
            SELECT
                CONVERT(nvarchar(450), source_key),
                CONVERT(datetime2(7), event_timestamp),
                CONVERT(nvarchar(max), payload_json)
            FROM ' + QUOTENAME(@AdapterSchema) + N'.' + QUOTENAME(@AdapterView) + N'
            WHERE source_key IS NOT NULL
              AND event_timestamp IS NOT NULL
              AND ISJSON(payload_json) = 1;';

        EXEC sys.sp_executesql @Sql;

        /*
          FULL keeps the same semantics as the rotating variant:
          - current snapshot INNER JOIN memory only;
          - no allocation of new classes;
          - all classes are dirty;
          - run counts remain 0/0/0.

          For class_load_memory only, however, we must subtract known keys
          that disappeared, so the official count remains consistent after FINALIZE.
        */
        INSERT #deleted_by_class
        (
            class_id,
            delete_count
        )
        SELECT
            m.class_id,
            COUNT_BIG(*)
        FROM dbo.class_memory AS m
        WHERE m.process_id = @ProcessId
          AND NOT EXISTS
          (
              SELECT 1
              FROM #snapshot AS s
              WHERE s.source_key = m.source_key
          )
        GROUP BY m.class_id;

        INSERT dbo.refresh_run
        (
            run_id,
            process_id,
            run_type,
            total_classes,
            insert_class_count,
            insert_count,
            update_count,
            delete_count,
            dirty_class_count,
            status,
            created_at
        )
        VALUES
        (
            @RunId,
            @ProcessId,
            'FULL',
            @TotalClasses,
            NULL,
            0,
            0,
            0,
            @TotalClasses,
            'PREPARED',
            SYSUTCDATETIME()
        );

        INSERT dbo.refresh_run_row
        (
            run_id,
            source_key,
            event_timestamp,
            payload_json,
            class_id,
            change_type
        )
        SELECT
            @RunId,
            s.source_key,
            s.event_timestamp,
            s.payload_json,
            m.class_id,
            'FULL'
        FROM #snapshot AS s
        INNER JOIN dbo.class_memory AS m
            ON m.process_id = @ProcessId
           AND m.source_key = s.source_key;

        INSERT dbo.refresh_run_class_load
        (
            run_id,
            class_id,
            starting_row_count,
            deleted_row_count,
            selection_row_count,
            inserted_row_count,
            candidate_row_count,
            is_insert_target,
            insert_rank
        )
        SELECT
            @RunId,
            l.class_id,
            l.known_row_count,
            COALESCE(d.delete_count, 0),
            l.known_row_count - COALESCE(d.delete_count, 0),
            0,
            l.known_row_count - COALESCE(d.delete_count, 0),
            0,
            NULL
        FROM dbo.class_load_memory AS l
        LEFT JOIN #deleted_by_class AS d
            ON d.class_id = l.class_id
        WHERE l.process_id = @ProcessId;

        IF EXISTS
        (
            SELECT 1
            FROM dbo.refresh_run_class_load
            WHERE run_id = @RunId
              AND candidate_row_count < 0
        )
            THROW 55304, 'Negative class count: class_load_memory is inconsistent.', 1;

        INSERT dbo.refresh_run_dirty_class
        (
            run_id,
            class_id
        )
        SELECT
            @RunId,
            CONVERT(int, n.class_id)
        FROM
        (
            SELECT TOP (@TotalClasses)
                ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS class_id
            FROM sys.all_objects AS a
            CROSS JOIN sys.all_objects AS b
        ) AS n;

        COMMIT TRANSACTION;

        SELECT *
        FROM dbo.refresh_run
        WHERE run_id = @RunId;

        SELECT class_id
        FROM dbo.refresh_run_dirty_class
        WHERE run_id = @RunId;

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
