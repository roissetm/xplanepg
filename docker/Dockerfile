FROM postgres:16

# Install pgTAP and pg_cron
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       postgresql-16-pgtap \
       postgresql-16-cron \
    && rm -rf /var/lib/apt/lists/*

# Configure pg_cron: must be in shared_preload_libraries
RUN echo "shared_preload_libraries = 'pg_cron'" >> /usr/share/postgresql/postgresql.conf.sample
RUN echo "cron.database_name = 'postgres'" >> /usr/share/postgresql/postgresql.conf.sample

# Copy SQL source files
COPY sql/ /opt/xplaneplpg/sql/

# Copy init script
COPY docker/init-xplaneplpg.sh /docker-entrypoint-initdb.d/00-init-xplaneplpg.sh
RUN chmod +x /docker-entrypoint-initdb.d/00-init-xplaneplpg.sh
