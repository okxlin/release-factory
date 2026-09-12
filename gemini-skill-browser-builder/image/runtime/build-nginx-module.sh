#!/usr/bin/env bash
set -euo pipefail

pin() { node -p "require('/tmp/browser-components.json').variants.linuxserver.nginx[process.argv[1]]" "$1"; }
mkdir -p /build/nginx /build/fancyindex /out
curl --proto '=https' -fsSL --max-time 180 "$(pin source_url)" -o /build/nginx.tar.gz
curl --proto '=https' -fsSL --max-time 180 "$(pin fancyindex_url)" -o /build/fancyindex.tar.gz
printf '%s  %s\n' "$(pin source_sha256)" /build/nginx.tar.gz | sha256sum -c -
printf '%s  %s\n' "$(pin fancyindex_sha256)" /build/fancyindex.tar.gz | sha256sum -c -
tar -xzf /build/nginx.tar.gz --strip-components=1 -C /build/nginx
tar -xzf /build/fancyindex.tar.gz --strip-components=1 -C /build/fancyindex
cd /build/nginx
# nginx.org packages enable --with-compat for external dynamic modules.
# https://nginx.org/en/docs/configure.html
./configure --with-compat --with-threads --with-http_ssl_module \
  --add-dynamic-module=/build/fancyindex
make -j2 modules
install -m644 objs/ngx_http_fancyindex_module.so /out/
install -m644 LICENSE /out/nginx-LICENSE
install -m644 /build/fancyindex/LICENSE /out/fancyindex-LICENSE
