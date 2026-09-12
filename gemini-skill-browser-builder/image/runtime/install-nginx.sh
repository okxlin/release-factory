#!/usr/bin/env bash
set -euo pipefail

pin() { node -p "require('/tmp/browser-components.json').variants.linuxserver.nginx[process.argv[1]]" "$1"; }
installed="$(dpkg-query -W -f='${Version}' nginx)"
installed="${installed#*:}"
if dpkg --compare-versions "${installed%%-*}" ge "$(pin minimum_version)"; then
  exit 0
fi
test "$(dpkg --print-architecture)" = amd64
curl -fsSL "$(pin url)" -o /tmp/nginx.deb
printf '%s  %s\n' "$(pin sha256)" /tmp/nginx.deb | sha256sum -c -
# Preserve LinuxServer's configuration entry point (sites-enabled, PID and user).
cp -a /etc/nginx/nginx.conf /tmp/nginx.conf
had_default=false
if [[ -f /etc/nginx/conf.d/default.conf ]]; then had_default=true; fi
apt-get update
apt-get install -y --no-install-recommends /tmp/nginx.deb
cp -a /tmp/nginx.conf /etc/nginx/nginx.conf
if [[ "${had_default}" == false ]]; then rm -f /etc/nginx/conf.d/default.conf; fi
# Debian's dynamic module is tied to the old ABI and is removed on upgrade.
# Preserve LinuxServer's /files/ UI with the same module built for this version.
install -Dm644 /tmp/nginx-module/ngx_http_fancyindex_module.so /usr/lib/nginx/modules/ngx_http_fancyindex_module.so
mkdir -p /etc/nginx/modules-enabled /usr/share/doc/nginx-fancyindex
printf '%s\n' 'load_module /usr/lib/nginx/modules/ngx_http_fancyindex_module.so;' > /etc/nginx/modules-enabled/50-mod-http-fancyindex.conf
install -m644 /tmp/nginx-module/*-LICENSE /usr/share/doc/nginx-fancyindex/
cp /tmp/browser-components.json /usr/share/doc/nginx-fancyindex/components.json
nginx -v
rm -rf /tmp/nginx.deb /tmp/nginx.conf /var/lib/apt/lists/*
