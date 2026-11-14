#!/usr/bin/env bash
set -euo pipefail

# Mirrored into the two workstation image contexts; keep all three copies identical.
mode="${1:-all}"
[[ "$mode" == all || "$mode" == plugins ]] || { echo 'unsupported tool selection' >&2; exit 1; }
tools_root=/tmp/release-factory-go-tools
tools_out=/out
[[ ! -e "$tools_root" && ! -e "$tools_out" ]] || { echo 'tool roots already exist' >&2; exit 1; }
[[ "$(go env GOVERSION)" == go1.27.4 ]] || { echo 'unreviewed Go toolchain' >&2; exit 1; }
export GOTOOLCHAIN=local GOWORK=off CGO_ENABLED=0

actionlint_version="${ACTIONLINT_VERSION:-1.7.12}"
actionlint_sha="${ACTIONLINT_SOURCE_SHA256:-454800bd4f854592bcfe79b161f71d56e35940eb7016e48a26dd356adc9d400a}"
gh_version="${GH_VERSION:-2.104.0}"
gh_sha="${GH_SOURCE_SHA256:-779060cbdc5a354fa2fc8afb56e9277f64a29ac599daefd941558356509081e4}"
docker_version="${DOCKER_VERSION:-29.9.3}"
docker_sha="${DOCKER_SOURCE_SHA256:-23d7472c80bc7483e57655085d687c631b398837bbc92535528c4582fc17e95b}"
buildx_version="${DOCKER_BUILDX_VERSION:-0.39.0}"
buildx_sha="${DOCKER_BUILDX_SOURCE_SHA256:-45aa68ee053b9bfa3c82f3dc7a2562e118be33e20ac87f572fa6e9f3d9ad67da}"
compose_version="${DOCKER_COMPOSE_VERSION:-5.7.1}"
compose_sha="${DOCKER_COMPOSE_SOURCE_SHA256:-bd108789759d3e17ae5532dd6eee67b427dade4c85089daa2f85d6c8f3e3ccb6}"
for version in "$actionlint_version" "$gh_version" "$docker_version" "$buildx_version" "$compose_version"; do
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'invalid tool version' >&2; exit 1; }
done
for digest in "$actionlint_sha" "$gh_sha" "$docker_sha" "$buildx_sha" "$compose_sha"; do
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || { echo 'invalid source digest' >&2; exit 1; }
done
mkdir -p "$tools_root" "$tools_out/bin" "$tools_out/cli-plugins" "$tools_out/licenses"
[[ "$(realpath "$tools_root")" == "$tools_root" && "$(realpath "$tools_out")" == "$tools_out" ]]
printf 'Source build roots: %s -> %s\n' "$(realpath "$tools_root")" "$(realpath "$tools_out")"

fetch_source() {
  local name="$1" repository="$2" version="$3" digest="$4"
  local archive="$tools_root/$name.tar.gz" directory="$tools_root/$name"
  [[ "$name" =~ ^[a-z-]+$ && "$repository" =~ ^[a-z-]+/[a-z-]+$ && ! -e "$directory" ]]
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --retry-all-errors \
    --connect-timeout 20 --max-time 180 -fsSLo "$archive" \
    "https://codeload.github.com/$repository/tar.gz/refs/tags/v$version"
  printf '%s  %s\n' "$digest" "$archive" | sha256sum -c -
  printf 'Source archive: %s; entries=%s; bytes=%s; target=%s\n' "$archive" \
    "$(tar -tzf "$archive" | wc -l)" "$(stat -c %s "$archive")" "$directory"
  mkdir "$directory"
  tar -xzf "$archive" -C "$directory" --strip-components=1
}

record_binary() {
  local binary="$1" name="$2"
  go version -m "$binary" | tee "$tools_out/licenses/$name.buildinfo.txt"
  grep -F 'go1.27.4' "$tools_out/licenses/$name.buildinfo.txt"
}

if [[ "$mode" == all ]]; then
  fetch_source actionlint rhysd/actionlint "$actionlint_version" "$actionlint_sha"
  cd "$tools_root/actionlint"
  grep -Fx 'module github.com/rhysd/actionlint' go.mod
  go mod edit -require=golang.org/x/sys@v0.50.0
  go mod tidy && go mod download && go mod verify
  go build -mod=readonly -trimpath -ldflags="-s -w -X github.com/rhysd/actionlint.version=$actionlint_version" \
    -o "$tools_out/bin/actionlint" ./cmd/actionlint
  "$tools_out/bin/actionlint" -version | grep -Fx "$actionlint_version"
  install -m 0644 LICENSE.txt "$tools_out/licenses/ACTIONLINT_LICENSE"
  record_binary "$tools_out/bin/actionlint" actionlint
  grep -Eq 'golang\.org/x/sys[[:space:]]+v0\.50\.0([[:space:]]|$)' "$tools_out/licenses/actionlint.buildinfo.txt"

  fetch_source gh cli/cli "$gh_version" "$gh_sha"
  cd "$tools_root/gh"
  grep -Fx 'module github.com/cli/cli/v2' go.mod
  go mod edit -require=golang.org/x/net@v0.62.0 -require=golang.org/x/crypto@v0.59.0
  go build -mod=mod -trimpath -ldflags="-s -w -X github.com/cli/cli/v2/internal/build.Version=$gh_version" \
    -o "$tools_out/bin/gh" ./cmd/gh
  go mod verify
  go list -mod=mod -deps ./cmd/gh > "$tools_out/licenses/GITHUB_CLI_GO_PACKAGES.txt"
  ! grep -E '^golang\.org/x/crypto/openpgp(/|$)' "$tools_out/licenses/GITHUB_CLI_GO_PACKAGES.txt"
  "$tools_out/bin/gh" --version | grep -F "gh version $gh_version"
  install -m 0644 LICENSE "$tools_out/licenses/GITHUB_CLI_LICENSE"
  record_binary "$tools_out/bin/gh" gh
  grep -Eq 'golang\.org/x/net[[:space:]]+v0\.62\.0([[:space:]]|$)' "$tools_out/licenses/gh.buildinfo.txt"

  fetch_source docker-cli docker/cli "$docker_version" "$docker_sha"
  cd "$tools_root/docker-cli"
  cp vendor.mod go.mod && cp vendor.sum go.sum
  go mod edit -require=golang.org/x/net@v0.62.0 -require=golang.org/x/mod@v0.43.0 \
    -require=golang.org/x/crypto@v0.59.0 -require=google.golang.org/grpc@v1.85.0 \
    -require=go.opentelemetry.io/otel@v1.47.0 -require=go.opentelemetry.io/otel/sdk@v1.47.0 \
    -require=go.opentelemetry.io/otel/trace@v1.47.0
  go build -mod=mod -trimpath \
    -ldflags="-s -w -X github.com/docker/cli/cli/version.Version=$docker_version -X github.com/docker/cli/cli/version.GitCommit=v$docker_version" \
    -o "$tools_out/bin/docker" ./cmd/docker
  "$tools_out/bin/docker" --version | grep -F "Docker version $docker_version,"
  go mod verify
  go list -mod=mod -deps ./cmd/docker > "$tools_out/licenses/DOCKER_CLI_GO_PACKAGES.txt"
  ! grep -Eq '^github.com/docker/docker(/|$)' "$tools_out/licenses/DOCKER_CLI_GO_PACKAGES.txt"
  install -m 0644 LICENSE "$tools_out/licenses/DOCKER_CLI_LICENSE"
  record_binary "$tools_out/bin/docker" docker
  for module in golang.org/x/net go.opentelemetry.io/otel/sdk go.opentelemetry.io/otel/trace; do
    version=1.47.0
    [[ "$module" != golang.org/x/net ]] || version=0.62.0
    grep -Eq "$module[[:space:]]+v$version([[:space:]]|$)" "$tools_out/licenses/docker.buildinfo.txt"
  done
fi

fetch_source buildx docker/buildx "$buildx_version" "$buildx_sha"
cd "$tools_root/buildx"
grep -Fx 'module github.com/docker/buildx' go.mod
go mod edit -require=github.com/moby/go-archive@v0.3.3 -require=golang.org/x/mod@v0.43.0 \
  -require=golang.org/x/net@v0.62.0 -require=golang.org/x/crypto@v0.59.0
go build -mod=mod -trimpath \
  -ldflags="-s -w -X github.com/docker/buildx/version.Version=v$buildx_version -X github.com/docker/buildx/version.Revision=v$buildx_version -X github.com/docker/buildx/version.Package=github.com/docker/buildx" \
  -o "$tools_out/cli-plugins/docker-buildx" ./cmd/buildx
go mod verify
"$tools_out/cli-plugins/docker-buildx" version | grep -F "github.com/docker/buildx v$buildx_version "
go list -mod=mod -deps ./cmd/buildx > "$tools_out/licenses/DOCKER_BUILDX_GO_PACKAGES.txt"
install -m 0644 LICENSE "$tools_out/licenses/DOCKER_BUILDX_LICENSE"
record_binary "$tools_out/cli-plugins/docker-buildx" buildx
grep -Eq 'github\.com/moby/go-archive[[:space:]]+v0\.3\.3([[:space:]]|$)' "$tools_out/licenses/buildx.buildinfo.txt"

fetch_source compose docker/compose "$compose_version" "$compose_sha"
cd "$tools_root/compose"
grep -Fx 'module github.com/docker/compose/v5' go.mod
go mod edit -require="github.com/docker/buildx@v$buildx_version" -require=github.com/moby/go-archive@v0.3.3 \
  -require=golang.org/x/net@v0.62.0 -require=golang.org/x/mod@v0.43.0 -require=golang.org/x/crypto@v0.59.0
go build -mod=mod -trimpath -ldflags="-s -w -X github.com/docker/compose/v5/internal.Version=v$compose_version" \
  -o "$tools_out/cli-plugins/docker-compose" ./cmd
go mod verify
"$tools_out/cli-plugins/docker-compose" version | grep -F "Docker Compose version v$compose_version"
go list -mod=mod -deps ./cmd > "$tools_out/licenses/DOCKER_COMPOSE_GO_PACKAGES.txt"
install -m 0644 LICENSE "$tools_out/licenses/DOCKER_COMPOSE_LICENSE"
record_binary "$tools_out/cli-plugins/docker-compose" compose

for tool in buildx compose; do
  grep -Eq 'golang\.org/x/net[[:space:]]+v0\.62\.0([[:space:]]|$)' "$tools_out/licenses/$tool.buildinfo.txt"
  grep -Eq 'golang\.org/x/crypto[[:space:]]+v0\.59\.0([[:space:]]|$)' "$tools_out/licenses/$tool.buildinfo.txt"
done
for component in BUILDX COMPOSE; do
  inventory="$tools_out/licenses/DOCKER_${component}_GO_PACKAGES.txt"
  legacy="$(grep -E '^github.com/docker/docker(/|$)' "$inventory" || true)"
  [[ -z "$legacy" || "$legacy" == github.com/docker/docker/pkg/namesgenerator ]]
  ! grep -E '^github.com/(docker/docker|moby/moby(/v[0-9]+)?)/(pkg/authorization|daemon)(/|$)' "$inventory"
  ! grep -E '^golang\.org/x/crypto/openpgp(/|$)' "$inventory"
done
install -m 0644 /usr/local/go/LICENSE "$tools_out/licenses/GO_LICENSE"
