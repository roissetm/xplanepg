FROM postgres:16

# Install pgTAP for testing support
RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-16-pgtap \
    && rm -rf /var/lib/apt/lists/*

# Copy SQL source files
COPY sql/ /opt/xplaneplpg/sql/

# Copy init script
COPY docker/init-xplaneplpg.sh /docker-entrypoint-initdb.d/00-init-xplaneplpg.sh
RUN chmod +x /docker-entrypoint-initdb.d/00-init-xplaneplpg.sh
