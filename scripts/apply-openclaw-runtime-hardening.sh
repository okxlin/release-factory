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

tmp_file="$(mktemp "${dockerfile}.runtime-hardening.XXXXXX")"

cleanup() {
  if [[ -n "${tmp_file}" ]]; then
    rm -f -- "${tmp_file}"
  fi
}
trap cleanup EXIT

awk -v npm_version="${npm_version}" '
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

{
  lines[NR] = $0
  total_lines = NR

  if ($0 ~ /^FROM[[:space:]]+build[[:space:]]+AS[[:space:]]+runtime-assets[[:space:]]*$/) {
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
}

END {
  if (runtime_assets_stages != 1) {
    fail("expected exactly one FROM build AS runtime-assets stage")
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
  if (failed) {
    exit 1
  }

  in_runtime_assets = 0
  in_runtime = 0
  vitest_inserted = 0
  npm_inserted = 0
  for (line_number = 1; line_number <= total_lines; line_number++) {
    line = lines[line_number]

    if (line ~ /^FROM[[:space:]]+build[[:space:]]+AS[[:space:]]+runtime-assets[[:space:]]*$/) {
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
