CREATE OR ALTER PROCEDURE dbo.usp_prepare_incremental_run
    @ProcessName       sysname,
    @InsertClassCount  int = NULL,
    @RunId             uniqueidentifier OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @ProcessId int,
        @AdapterSchema sysname,
        @AdapterView sysname,
        @TotalClasses int,
        @DefaultInsertClassCount int,
        @EffectiveInsertClassCount int,
        @Sql nvarchar(max),
        @LockResult int,
        @LockResource nvarchar(255),
        @InsertCount bigint,
        @UpdateCount bigint,
        @DeleteCount bigint,
        @DirtyCount int;

    SELECT
        @ProcessId = process_id,
        @AdapterSchema = adapter_schema,
        @AdapterView = adapter_view,
        @TotalClasses = total_classes,
        @DefaultInsertClassCount = default_insert_class_count
    FROM dbo.refresh_process
    WHERE process_name = @ProcessName;

    IF @ProcessId IS NULL
        THROW 55200, 'Unknown process.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.class_memory
        WHERE process_id = @ProcessId
    )
        THROW 55201, 'Empty memory: run bootstrap first.', 1;

    IF
    (
        SELECT COUNT(*)
        FROM dbo.class_load_memory
        WHERE process_id = @ProcessId
    ) <> @TotalClasses
        THROW 55201, 'Incomplete count memory: run bootstrap first.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.refresh_run
        WHERE process_id = @ProcessId
          AND status = 'PREPARED'
    )
        THROW 55202, 'A PREPARED run already exists.', 1;

    SET @EffectiveInsertClassCount =
        COALESCE(@InsertClassCount, @DefaultInsertClassCount);

    IF @EffectiveInsertClassCount <= 0
       OR @EffectiveInsertClassCount > @TotalClasses
        THROW 55203, 'Invalid insert_class_count.', 1;

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
            THROW 55204, 'Process is locked.', 1;

        CREATE TABLE #snapshot
        (
            source_key       nvarchar(450) NOT NULL
                CONSTRAINT PK_incremental_snapshot PRIMARY KEY,
            event_timestamp  datetime2(7) NOT NULL,
            payload_json     nvarchar(max) NOT NULL,
            class_id         int NULL,
            change_type      varchar(20) NULL,
            insert_slot      int NULL
        );

        CREATE TABLE #deleted
        (
            source_key  nvarchar(450) NOT NULL PRIMARY KEY,
            class_id    int NOT NULL
        );

        CREATE TABLE #class_load
        (
            class_id             int NOT NULL PRIMARY KEY,
            starting_row_count   bigint NOT NULL,
            deleted_row_count    bigint NOT NULL,
            selection_row_count  bigint NOT NULL,
            inserted_row_count   bigint NOT NULL,
            candidate_row_count  bigint NOT NULL,
            is_insert_target     bit NOT NULL,
            insert_rank          int NULL
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

        /* Existing keys: same historical class. */
        UPDATE s
        SET
            class_id = m.class_id,
            change_type =
                CASE
                    WHEN s.event_timestamp <> m.last_timestamp
                        THEN 'UPDATE'
                    ELSE 'UNCHANGED'
                END
        FROM #snapshot AS s
        INNER JOIN dbo.class_memory AS m
            ON m.process_id = @ProcessId
           AND m.source_key = s.source_key;

        /* DELETE = present in official memory but absent from the snapshot. */
        INSERT #deleted
        (
            source_key,
            class_id
        )
        SELECT
            m.source_key,
            m.class_id
        FROM dbo.class_memory AS m
        WHERE m.process_id = @ProcessId
          AND NOT EXISTS
          (
              SELECT 1
              FROM #snapshot AS s
              WHERE s.source_key = m.source_key
          );

        SELECT @InsertCount = COUNT_BIG(*)
        FROM #snapshot
        WHERE class_id IS NULL;

        SELECT @UpdateCount = COUNT_BIG(*)
        FROM #snapshot
        WHERE change_type = 'UPDATE';

        SELECT @DeleteCount = COUNT_BIG(*)
        FROM #deleted;

        /*
          Class state before INSERTs.

          UPDATEs do not change the number of keys in the class.
          DELETEs are instead subtracted before selecting the least-loaded
          classes for the run.
        */
        ;WITH deleted_by_class AS
        (
            SELECT
                class_id,
                COUNT_BIG(*) AS delete_count
            FROM #deleted
            GROUP BY class_id
        )
        INSERT #class_load
        (
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
            l.class_id,
            l.known_row_count,
            COALESCE(d.delete_count, 0),
            l.known_row_count - COALESCE(d.delete_count, 0),
            0,
            l.known_row_count - COALESCE(d.delete_count, 0),
            0,
            NULL
        FROM dbo.class_load_memory AS l
        LEFT JOIN deleted_by_class AS d
            ON d.class_id = l.class_id
        WHERE l.process_id = @ProcessId;

        IF EXISTS
        (
            SELECT 1
            FROM #class_load
            WHERE selection_row_count < 0
        )
            THROW 55205, 'Negative class count: class_load_memory is inconsistent.', 1;

        IF @InsertCount > 0
        BEGIN
            /*
              1) order classes by current row count;
              2) take the first m;
              3) assign an insert_rank from 1..m.

              The selected classes do not need to be contiguous and can be
              selected again in consecutive runs if they remain advantageous.
            */
            ;WITH ranked AS
            (
                SELECT
                    class_id,
                    ROW_NUMBER() OVER
                    (
                        ORDER BY selection_row_count
                    ) AS insert_rank
                FROM #class_load
            )
            UPDATE l
            SET
                is_insert_target = 1,
                insert_rank = CONVERT(int, r.insert_rank)
            FROM #class_load AS l
            INNER JOIN ranked AS r
                ON r.class_id = l.class_id
            WHERE r.insert_rank <= @EffectiveInsertClassCount;

            /*
              New keys:

              technical ROW_NUMBER -> modulo m -> slot 1..m
              JOIN slot = insert_rank -> actual selected class_id.
            */
            ;WITH inserted AS
            (
                SELECT
                    source_key,
                    ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
                FROM #snapshot
                WHERE class_id IS NULL
            ),
            slotted AS
            (
                SELECT
                    source_key,
                    CONVERT
                    (
                        int,
                        ((rn - 1) % @EffectiveInsertClassCount) + 1
                    ) AS insert_slot
                FROM inserted
            )
            UPDATE s
            SET
                insert_slot = x.insert_slot,
                class_id = l.class_id,
                change_type = 'INSERT'
            FROM #snapshot AS s
            INNER JOIN slotted AS x
                ON x.source_key = s.source_key
            INNER JOIN #class_load AS l
                ON l.insert_rank = x.insert_slot
               AND l.is_insert_target = 1;
        END;

        IF EXISTS
        (
            SELECT 1
            FROM #snapshot
            WHERE class_id IS NULL
               OR change_type IS NULL
        )
            THROW 55206, 'Incomplete snapshot classification.', 1;

        /* Candidate counts = official count - DELETE + INSERT. */
        ;WITH inserted_by_class AS
        (
            SELECT
                class_id,
                COUNT_BIG(*) AS insert_count
            FROM #snapshot
            WHERE change_type = 'INSERT'
            GROUP BY class_id
        )
        UPDATE l
        SET
            inserted_row_count = COALESCE(i.insert_count, 0),
            candidate_row_count =
                l.selection_row_count + COALESCE(i.insert_count, 0)
        FROM #class_load AS l
        LEFT JOIN inserted_by_class AS i
            ON i.class_id = l.class_id;

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
            'INCREMENTAL',
            @TotalClasses,
            @EffectiveInsertClassCount,
            @InsertCount,
            @UpdateCount,
            @DeleteCount,
            0,
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
            source_key,
            event_timestamp,
            payload_json,
            class_id,
            change_type
        FROM #snapshot;

        INSERT dbo.refresh_run_delete
        (
            run_id,
            source_key,
            class_id
        )
        SELECT
            @RunId,
            source_key,
            class_id
        FROM #deleted;

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
            class_id,
            starting_row_count,
            deleted_row_count,
            selection_row_count,
            inserted_row_count,
            candidate_row_count,
            is_insert_target,
            insert_rank
        FROM #class_load;

        /* Dirty INSERT classes: only classes that received new records. */
        INSERT dbo.refresh_run_dirty_class
        (
            run_id,
            class_id
        )
        SELECT DISTINCT
            @RunId,
            class_id
        FROM #snapshot
        WHERE change_type = 'INSERT';

        /* Dirty UPDATE classes: historical class. */
        INSERT dbo.refresh_run_dirty_class
        (
            run_id,
            class_id
        )
        SELECT DISTINCT
            @RunId,
            s.class_id
        FROM #snapshot AS s
        WHERE s.change_type = 'UPDATE'
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.refresh_run_dirty_class AS d
              WHERE d.run_id = @RunId
                AND d.class_id = s.class_id
          );

        /* Dirty DELETE classes: historical class. */
        INSERT dbo.refresh_run_dirty_class
        (
            run_id,
            class_id
        )
        SELECT DISTINCT
            @RunId,
            d.class_id
        FROM #deleted AS d
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM dbo.refresh_run_dirty_class AS x
            WHERE x.run_id = @RunId
              AND x.class_id = d.class_id
        );

        SELECT @DirtyCount = COUNT(*)
        FROM dbo.refresh_run_dirty_class
        WHERE run_id = @RunId;

        UPDATE dbo.refresh_run
        SET dirty_class_count = @DirtyCount
        WHERE run_id = @RunId;

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
