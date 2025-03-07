FROM docker.io/library/caddy:builder AS builder

RUN xcaddy build --with github.com/caddy-dns/godaddy

FROM docker.io/library/caddy:latest

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
