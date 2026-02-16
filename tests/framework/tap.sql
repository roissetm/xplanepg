-- ============================================================================
-- pgTAP Test Framework Setup
-- ============================================================================
-- Ensures pgTAP is available for running tests.
-- Handles both extension install and source-loaded pgTAP (CI).
-- ============================================================================

DO $$
BEGIN
    -- Check if pgTAP is already loaded (e.g. via source SQL in CI)
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'plan') THEN
        CREATE EXTENSION IF NOT EXISTS pgtap;
    END IF;
END;
$$;
