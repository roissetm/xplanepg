-- ============================================================================
-- SETUP PG_CRON POUR RÉCONCILIATION AUTOMATIQUE
-- ============================================================================
-- Nécessite l'extension pg_cron installée sur le serveur.
-- pg_cron MUST be in shared_preload_libraries in postgresql.conf.
-- La réconciliation tourne toutes les 30 secondes.
-- ============================================================================

DO $$
BEGIN
    -- Check if pg_cron extension is available
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;

        -- Schedule reconciliation every 30 seconds
        PERFORM cron.schedule(
            'crossplane-reconcile',
            '30 seconds',
            'SELECT * FROM crossplane.reconcile_all()'
        );
        RAISE NOTICE 'pg_cron: crossplane-reconcile job scheduled (every 30s)';
    ELSE
        RAISE WARNING 'pg_cron is not available. Add pg_cron to shared_preload_libraries and restart PostgreSQL to enable automatic reconciliation.';
    END IF;
END;
$$;

-- Pour désactiver :
-- SELECT cron.unschedule('crossplane-reconcile');

-- Pour voir le statut des jobs :
-- SELECT * FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
