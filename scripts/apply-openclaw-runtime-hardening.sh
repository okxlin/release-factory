#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: apply-openclaw-runtime-hardening.sh [OPENCLAW_SOURCE_DIR]

Apply the runtime-only hardening needed by the OpenClaw sandbox image.
The transformation is idempotent and follows Dockerfile stage/path semantics
instead of depending on upstream line numbers or package-manager versions.
EOF
}

if [[ "$#" -gt 1 ]]; then
  usage >&2
  exit 2
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

source_dir="${1:-openclaw-src}"
dockerfile="${source_dir}/Dockerfile"
npm_version="${OPENCLAW_NPM_VERSION:-11.18.0}"
docker_toolchain_image="${OPENCLAW_DOCKER_TOOLCHAIN_IMAGE:-docker.io/library/golang:1.26.7-bookworm@sha256:e8c859f5632dcfde7b32d2012b4351728f6437930887c2f6a91ea242459e5514}"
docker_cli_source_ref="${OPENCLAW_DOCKER_CLI_SOURCE_REF:-a7dcaa6fdb6ed04aacbfdc76357fdae01605609e}"
docker_cli_version="${OPENCLAW_DOCKER_CLI_VERSION:-29.7.2}"
docker_compose_source_ref="${OPENCLAW_DOCKER_COMPOSE_SOURCE_REF:-870908cc8f07f5e90acdf5d34dd1b96a4fe51d16}"
docker_compose_version="${OPENCLAW_DOCKER_COMPOSE_VERSION:-5.5.0}"

if [[ -z "${source_dir}" || ! -d "${source_dir}" ]]; then
  echo "ERROR: OpenClaw source directory not found: ${source_dir}" >&2
  exit 1
fi

if [[ ! -f "${dockerfile}" ]]; then
  echo "ERROR: OpenClaw Dockerfile not found: ${dockerfile}" >&2
  exit 1
fi

if ! git -C "${source_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: OpenClaw source directory is not a Git worktree: ${source_dir}" >&2
  exit 1
fi

if [[ ! "${npm_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "ERROR: OPENCLAW_NPM_VERSION is not a valid npm version: ${npm_version}" >&2
  exit 1
fi

if [[ ! "${docker_toolchain_image}" =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "ERROR: OPENCLAW_DOCKER_TOOLCHAIN_IMAGE must be pinned by a SHA-256 digest" >&2
  exit 1
fi

for source_ref in "${docker_cli_source_ref}" "${docker_compose_source_ref}"; do
  if [[ ! "${source_ref}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: Docker tool source refs must be full lowercase commit ids: ${source_ref}" >&2
    exit 1
  fi
done

for tool_version in "${docker_cli_version}" "${docker_compose_version}"; do
  if [[ ! "${tool_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Docker tool versions must be stable semver values: ${tool_version}" >&2
    exit 1
  fi
done

tmp_file="$(mktemp "${dockerfile}.runtime-hardening.XXXXXX")"

cleanup() {
  if [[ -n "${tmp_file}" ]]; then
    rm -f -- "${tmp_file}"
  fi
}
trap cleanup EXIT

awk \
  -v npm_version="${npm_version}" \
  -v docker_toolchain_image="${docker_toolchain_image}" \
  -v docker_cli_source_ref="${docker_cli_source_ref}" \
  -v docker_cli_version="${docker_cli_version}" \
  -v docker_compose_source_ref="${docker_compose_source_ref}" \
  -v docker_compose_version="${docker_compose_version}" \
 '
function normalize_line(value) {
  sub(/^[[:space:]]+/, "", value)
  sub(/[[:space:]]+$/, "", value)
  return value
}

function has_continuation_path(value, path) {
  return normalize_line(value) == path " " "\\"
}

function fail(message) {
  print "ERROR: " message > "/dev/stderr"
  failed = 1
}

function emit_npm_upgrade(indent) {
  if (npm_arg_count == 0) {
    print indent "ARG OPENCLAW_NPM_VERSION=" npm_version
    print ""
  }
  print indent "# Keep the npm bundled tar dependency at a version with the current security fix."
  print indent "RUN npm install --global \"npm@${OPENCLAW_NPM_VERSION}\" " "\\"
  print indent "    && npm cache clean --force"
  print ""
}

function emit_docker_toolchain_stage() {
  print "ARG OPENCLAW_DOCKER_TOOLCHAIN_IMAGE=\"" docker_toolchain_image "\""
  print "ARG OPENCLAW_DOCKER_CLI_SOURCE_REF=\"" docker_cli_source_ref "\""
  print "ARG OPENCLAW_DOCKER_CLI_VERSION=\"" docker_cli_version "\""
  print "ARG OPENCLAW_DOCKER_COMPOSE_SOURCE_REF=\"" docker_compose_source_ref "\""
  print "ARG OPENCLAW_DOCKER_COMPOSE_VERSION=\"" docker_compose_version "\""
  print ""
  print "# Build the Docker tools with a patched Go toolchain instead of shipping stale upstream packages."
  print "FROM ${OPENCLAW_DOCKER_TOOLCHAIN_IMAGE} AS openclaw-runtime-docker-tools"
  print "ARG OPENCLAW_INSTALL_DOCKER_CLI"
  print "ARG OPENCLAW_DOCKER_CLI_SOURCE_REF"
  print "ARG OPENCLAW_DOCKER_CLI_VERSION"
  print "ARG OPENCLAW_DOCKER_COMPOSE_SOURCE_REF"
  print "ARG OPENCLAW_DOCKER_COMPOSE_VERSION"
  print "ARG TARGETOS"
  print "ARG TARGETARCH"
  print "ENV GOTOOLCHAIN=local"
  print "RUN set -eux; \\"
  print "    mkdir -p /out /go/src/github.com/docker && \\"
  print "    if [ -z \"${OPENCLAW_INSTALL_DOCKER_CLI}\" ]; then \\"
  print "      touch /out/disabled; \\"
  print "      exit 0; \\"
  print "    fi && \\"
  print "    for source_ref in \"${OPENCLAW_DOCKER_CLI_SOURCE_REF}\" \"${OPENCLAW_DOCKER_COMPOSE_SOURCE_REF}\"; do \\"
  print "      if ! printf \"%s\\n\" \"${source_ref}\" | grep -Eq \"^[0-9a-f]{40}\\$\"; then \\"
  print "        echo \"ERROR: Docker tool source ref is not a full lowercase commit id: ${source_ref}\" >&2; \\"
  print "        exit 1; \\"
  print "      fi; \\"
  print "    done && \\"
  print "    fetch_source() { \\"
  print "      repository=\"$1\"; \\"
  print "      source_ref=\"$2\"; \\"
  print "      destination=\"$3\"; \\"
  print "      git init --quiet \"${destination}\"; \\"
  print "      git -C \"${destination}\" remote add origin \"${repository}\"; \\"
  print "      git -C \"${destination}\" fetch --depth 1 --quiet origin \"${source_ref}\"; \\"
  print "      git -C \"${destination}\" checkout --detach --quiet FETCH_HEAD; \\"
  print "      test \"$(git -C \"${destination}\" rev-parse HEAD)\" = \"${source_ref}\"; \\"
  print "    }; \\"
  print "    fetch_source https://github.com/docker/cli.git \"${OPENCLAW_DOCKER_CLI_SOURCE_REF}\" /go/src/github.com/docker/cli && \\"
  print "    fetch_source https://github.com/docker/compose.git \"${OPENCLAW_DOCKER_COMPOSE_SOURCE_REF}\" /go/src/github.com/docker/compose && \\"
  print "    cd /go/src/github.com/docker/cli && \\"
  print "    GOOS=\"${TARGETOS}\" GOARCH=\"${TARGETARCH}\" CGO_ENABLED=0 GO111MODULE=auto \\"
  print "      GO_LINKMODE=static TARGET=/out VERSION=\"${OPENCLAW_DOCKER_CLI_VERSION}\" \\"
  print "      GITCOMMIT=\"${OPENCLAW_DOCKER_CLI_SOURCE_REF}\" BUILDTIME=1970-01-01T00:00:00Z \\"
  print "      ./scripts/build/binary && \\"
  print "    cli_binary=\"$(find /out -maxdepth 1 -type f -name \"docker-*\" -print -quit)\" && \\"
  print "    test -n \"${cli_binary}\" && \\"
  print "    rm -f /out/docker && install -m 0755 \"${cli_binary}\" /out/docker && \\"
  print "    cd /go/src/github.com/docker/compose && \\"
  print "    go mod edit -require=golang.org/x/crypto@v0.55.0 -require=golang.org/x/mod@v0.40.0 && \\"
  print "    CGO_ENABLED=0 GOOS=\"${TARGETOS}\" GOARCH=\"${TARGETARCH}\" \\"
  print "      go build -mod=mod -trimpath -tags e2e \\"
  print "      -ldflags \"-w -X github.com/docker/compose/v5/internal.Version=v${OPENCLAW_DOCKER_COMPOSE_VERSION}\" \\"
  print "      -o /out/docker-compose ./cmd && \\"
  print "    compiler_go_version=\"$(go version | awk \"{sub(/^go/, \\\"\\\", \\$3); print \\$3}\")\" && \\"
  print "    if [ \"$(printf \"%s\\n\" 1.26.6 \"${compiler_go_version}\" | sort -V | head -n1)\" != 1.26.6 ]; then \\"
  print "      echo \"ERROR: Docker toolchain Go version is too old: ${compiler_go_version}\" >&2; \\"
  print "      exit 1; \\"
  print "    fi && \\"
  print "    if ! go version -m /out/docker-compose | grep -Eq \"dep[[:space:]]+golang.org/x/crypto[[:space:]]+v0\\.55\\.0([[:space:]]|\\$)\"; then \\"
  print "      echo \"ERROR: rebuilt Compose binary does not contain golang.org/x/crypto v0.55.0\" >&2; \\"
  print "      exit 1; \\"
  print "    fi && \\"
  print "    if ! go version -m /out/docker-compose | grep -Eq \"dep[[:space:]]+golang.org/x/mod[[:space:]]+v0\\.40\\.0([[:space:]]|\\$)\"; then \\"
  print "      echo \"ERROR: rebuilt Compose binary does not contain golang.org/x/mod v0.40.0\" >&2; \\"
  print "      exit 1; \\"
  print "    fi && \\"
  print "    touch /out/enabled"
  print ""
}

function emit_docker_toolchain_overlay(indent) {
  print indent "COPY --from=openclaw-runtime-docker-tools /out/ /tmp/openclaw-runtime-docker-tools/"
  print indent "RUN set -eux; \\"
  print indent "    if [ -f /tmp/openclaw-runtime-docker-tools/enabled ]; then \\"
  print indent "      if dpkg-query -W -f=\"\\${Status}\" docker-ce-cli 2>/dev/null | grep -q \"install ok installed\" || \\"
  print indent "         dpkg-query -W -f=\"\\${Status}\" docker-compose-plugin 2>/dev/null | grep -q \"install ok installed\"; then \\"
  print indent "        DEBIAN_FRONTEND=noninteractive apt-get purge -y docker-ce-cli docker-compose-plugin; \\"
  print indent "      fi; \\"
  print indent "      install -d -m 0755 /usr/libexec/docker/cli-plugins && \\"
  print indent "      install -m 0755 /tmp/openclaw-runtime-docker-tools/docker /usr/bin/docker && \\"
  print indent "      install -m 0755 /tmp/openclaw-runtime-docker-tools/docker-compose /usr/libexec/docker/cli-plugins/docker-compose; \\"
  print indent "    fi && \\"
  print indent "    rm -rf /tmp/openclaw-runtime-docker-tools"
  print ""
}

{
  lines[NR] = $0
  total_lines = NR

  if ($0 ~ /^FROM[[:space:]]+/) {
    from_count++
  }

  if ($0 ~ /^FROM[[:space:]]+.*[[:space:]]+AS[[:space:]]+runtime-assets[[:space:]]*$/) {
    in_runtime_assets = 1
    runtime_assets_stages++
  } else if ($0 ~ /^FROM[[:space:]]+/) {
    in_runtime_assets = 0
  }

  if ($0 ~ /^FROM[[:space:]]+base-runtime([[:space:]]+AS[[:space:]]+[A-Za-z0-9_.-]+)?[[:space:]]*$/) {
    in_runtime = 1
    runtime_stages++
  } else if ($0 ~ /^FROM[[:space:]]+/) {
    in_runtime = 0
  }

  if (in_runtime_assets) {
    if (has_continuation_path($0, "/app/node_modules/@vitest")) {
      vitest_scope_count++
    }
    if (has_continuation_path($0, "/app/node_modules/vitest")) {
      vitest_package_count++
    }
    if (has_continuation_path($0, "/app/node_modules/openclaw")) {
      openclaw_anchor_count++
    }
  }

  if (in_runtime) {
    if ($0 ~ /^ARG[[:space:]]+OPENCLAW_NPM_VERSION([=[:space:]]|$)/) {
      npm_arg_count++
    }
    if ($0 ~ /npm[[:space:]]+install[[:space:]]+(-g|--global)([[:space:]]|$)/) {
      npm_refresh_count++
    }
    if ($0 ~ /^USER[[:space:]]+/) {
      runtime_user_count++
    }
  }

  if ($0 ~ /^RUN[[:space:]]+ln[[:space:]]+-sf[[:space:]]+\/app\/openclaw\.mjs([[:space:]]|$)/) {
    docker_toolchain_overlay_anchor_count++
  }

  if ($0 ~ /^FROM[[:space:]]+\$\{OPENCLAW_DOCKER_TOOLCHAIN_IMAGE\}[[:space:]]+AS[[:space:]]+openclaw-runtime-docker-tools[[:space:]]*$/) {
    docker_toolchain_stage_count++
  }
  if ($0 ~ /^COPY[[:space:]]+--from=openclaw-runtime-docker-tools[[:space:]]+\/out\/[[:space:]]+\/tmp\/openclaw-runtime-docker-tools\/[[:space:]]*$/) {
    docker_toolchain_copy_count++
  }
}

END {
  if (runtime_assets_stages != 1) {
    fail("expected exactly one FROM ... AS runtime-assets stage")
  }
  if (openclaw_anchor_count != 1) {
    fail("expected exactly one OpenClaw runtime-assets removal anchor")
  }
  if (vitest_scope_count != vitest_package_count) {
    fail("Vitest runtime cleanup is only partially present")
  }
  if (runtime_stages != 1) {
    fail("expected exactly one FROM base-runtime stage")
  }
  if (runtime_user_count == 0 && npm_refresh_count == 0) {
    fail("runtime stage has no USER anchor for npm hardening")
  }
  if (docker_toolchain_overlay_anchor_count != 1) {
    fail("expected exactly one OpenClaw runtime binary anchor")
  }
  if (docker_toolchain_stage_count > 1 || docker_toolchain_copy_count > 1) {
    fail("OpenClaw Docker toolchain hardening is duplicated")
  }
  if (docker_toolchain_stage_count != docker_toolchain_copy_count) {
    fail("OpenClaw Docker toolchain hardening is only partially present")
  }
  if (from_count == 0) {
    fail("OpenClaw Dockerfile has no FROM stage")
  }
  if (failed) {
    exit 1
  }

  in_runtime_assets = 0
  in_runtime = 0
  vitest_inserted = 0
  npm_inserted = 0
  for (line_number = 1; line_number <= total_lines; line_number++) {
    line = lines[line_number]

    if (!docker_toolchain_stage_emitted && line ~ /^FROM[[:space:]]+/) {
      if (docker_toolchain_stage_count == 0) {
        emit_docker_toolchain_stage()
      }
      docker_toolchain_stage_emitted = 1
    }

    if (line ~ /^FROM[[:space:]]+.*[[:space:]]+AS[[:space:]]+runtime-assets[[:space:]]*$/) {
      in_runtime_assets = 1
    } else if (line ~ /^FROM[[:space:]]+/) {
      in_runtime_assets = 0
    }

    if (line ~ /^FROM[[:space:]]+base-runtime([[:space:]]+AS[[:space:]]+[A-Za-z0-9_.-]+)?[[:space:]]*$/) {
      in_runtime = 1
    } else if (line ~ /^FROM[[:space:]]+/) {
      in_runtime = 0
    }

    if (in_runtime_assets && has_continuation_path(line, "/app/node_modules/openclaw")) {
      if (vitest_scope_count == 0 && vitest_package_count == 0 && !vitest_inserted) {
        indent = line
        sub(/[^[:space:]].*$/, "", indent)
        print indent "/app/node_modules/@vitest" " " "\\"
        print indent "/app/node_modules/vitest" " " "\\"
        vitest_inserted = 1
      }
    }

    if (in_runtime && line ~ /^USER[[:space:]]+/) {
      if (npm_refresh_count == 0 && !npm_inserted) {
        indent = line
        sub(/[^[:space:]].*$/, "", indent)
        emit_npm_upgrade(indent)
        npm_inserted = 1
      }
    }

    if (in_runtime && docker_toolchain_copy_count == 0 && line ~ /^RUN[[:space:]]+ln[[:space:]]+-sf[[:space:]]+\/app\/openclaw\.mjs([[:space:]]|$)/) {
      emit_docker_toolchain_overlay("")
    }

    print line
  }
}
' "${dockerfile}" > "${tmp_file}"

chmod --reference="${dockerfile}" "${tmp_file}"

if cmp -s "${tmp_file}" "${dockerfile}"; then
  echo "OpenClaw runtime hardening already satisfied for ${source_dir}"
  exit 0
fi

mv -- "${tmp_file}" "${dockerfile}"
tmp_file=""

git -C "${source_dir}" diff --check
echo "Applied OpenClaw runtime hardening to ${dockerfile}"
