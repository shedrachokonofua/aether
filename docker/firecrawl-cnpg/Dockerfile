FROM ghcr.io/cloudnative-pg/postgresql:17.10@sha256:916d505d999e6bb85ead15dc2b965b9f968a9eb09e6d9c2e59e50a174f785e71

USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    postgresql-17-cron \
  && rm -rf /var/lib/apt/lists/* \
  && sed -i -E 's/^(postgres:x:)[0-9]+:[0-9]+:/\1999:999:/' /etc/passwd \
  && sed -i -E 's/^(postgres:x:)[0-9]+:/\1999:/' /etc/group \
  && chown -R 999:999 /var/lib/postgresql /var/run/postgresql

USER 999
