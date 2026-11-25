# Caddy with the Route 53 DNS provider, for Let's Encrypt DNS-01.
# DNS-01 is required because the site is tailnet-only: Let's Encrypt can't reach it
# over HTTP, so it proves ownership by a TXT record in Route 53 instead.
FROM caddy:2.11.9-builder AS build
RUN xcaddy build --with github.com/caddy-dns/route53@v1.6.3

FROM caddy:2.11.9
COPY --from=build /usr/bin/caddy /usr/bin/caddy
