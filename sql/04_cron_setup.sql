-- ============================================================================
-- SETUP PG_CRON POUR RÉCONCILIATION AUTOMATIQUE
-- ============================================================================
-- Nécessite l'extension pg_cron installée sur le serveur.
-- La réconciliation tourne toutes les 30 secondes.
-- ============================================================================

-- Installer pg_cron si disponible
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Planifier la réconciliation toutes les 30 secondes
SELECT cron.schedule(
    'crossplane-reconcile',
    '30 seconds',
    $$SELECT * FROM crossplane.reconcile_all()$$
);

-- Pour désactiver :
-- SELECT cron.unschedule('crossplane-reconcile');

-- Pour voir le statut des jobs :
-- SELECT * FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
