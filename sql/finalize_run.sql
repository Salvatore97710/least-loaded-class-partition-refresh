CREATE OR ALTER PROCEDURE dbo.usp_finalize_refresh_run
    @RunId uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @ProcessId int,
        @TotalClasses int,
        @LockResult int,
        @LockResource nvarchar(255);

    /* First read to identify the process and build the application lock. */
    SELECT
        @ProcessId = process_id,
        @TotalClasses = total_classes
    FROM dbo.refresh_run
    WHERE run_id = @RunId
      AND status = 'PREPARED';

    IF @ProcessId IS NULL
        THROW 55500, 'Run does not exist or has already been finalized.', 1;

    IF
    (
        SELECT COUNT(*)
        FROM dbo.refresh_run_class_load
        WHERE run_id = @RunId
    ) <> @TotalClasses
        THROW 55502, 'Incomplete candidate class load.', 1;

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
            THROW 55501, 'Process is locked.', 1;

        /* Re-check after acquiring the lock. */
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.refresh_run
            WHERE run_id = @RunId
              AND process_id = @ProcessId
              AND status = 'PREPARED'
        )
            THROW 55502, 'Run is in an invalid state.', 1;

        /* Complete candidate memory of keys. */
        DELETE FROM dbo.class_memory
        WHERE process_id = @ProcessId;

        INSERT dbo.class_memory
        (
            process_id,
            source_key,
            last_timestamp,
            class_id,
            updated_at
        )
        SELECT
            @ProcessId,
            source_key,
            event_timestamp,
            class_id,
            SYSUTCDATETIME()
        FROM dbo.refresh_run_row
        WHERE run_id = @RunId;

        /* Complete candidate memory of per-class counts. */
        DELETE FROM dbo.class_load_memory
        WHERE process_id = @ProcessId;

        INSERT dbo.class_load_memory
        (
            process_id,
            class_id,
            known_row_count,
            updated_at
        )
        SELECT
            @ProcessId,
            class_id,
            candidate_row_count,
            SYSUTCDATETIME()
        FROM dbo.refresh_run_class_load
        WHERE run_id = @RunId;

        UPDATE dbo.refresh_process
        SET
            last_successful_run_id = @RunId,
            updated_at = SYSUTCDATETIME()
        WHERE process_id = @ProcessId;

        /*
          RUN STAGING CLEANUP.

          refresh_run remains as lightweight history; the four operational
          structures are removed after successful promotion.
        */
        DELETE FROM dbo.refresh_run_dirty_class
        WHERE run_id = @RunId;

        DELETE FROM dbo.refresh_run_delete
        WHERE run_id = @RunId;

        DELETE FROM dbo.refresh_run_class_load
        WHERE run_id = @RunId;

        DELETE FROM dbo.refresh_run_row
        WHERE run_id = @RunId;

        UPDATE dbo.refresh_run
        SET
            status = 'COMPLETED',
            completed_at = SYSUTCDATETIME()
        WHERE run_id = @RunId
          AND status = 'PREPARED';

        IF @@ROWCOUNT = 0
            THROW 55502, 'Run is in an invalid state.', 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO
