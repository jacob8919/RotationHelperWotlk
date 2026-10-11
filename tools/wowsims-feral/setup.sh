#!/usr/bin/env bash
# Builds the feral rotation comparison tool on WoWSims WotLK (Linux/WSL).
# Downloads Go, protoc and WoWSims into ~/.cache/rotationhelper-wowsims (or $WOWSIMS_CACHE);
# nothing is installed system-wide. Run once, then ./run.sh.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
C=${WOWSIMS_CACHE:-$HOME/.cache/rotationhelper-wowsims}
WOWSIMS_COMMIT=563e4a08cb15729f1fdcbcf68e6d68224553bfef # 2025-12-22
mkdir -p "$C"
cd "$C"
if [ ! -x go/bin/go ]; then
    curl -sSfL https://go.dev/dl/go1.23.4.linux-amd64.tar.gz | tar -xz
fi
if [ ! -x protoc/bin/protoc ]; then
    curl -sSfL -o protoc.zip https://github.com/protocolbuffers/protobuf/releases/download/v25.3/protoc-25.3-linux-x86_64.zip
    python3 -c "import zipfile; zipfile.ZipFile('protoc.zip').extractall('protoc')"
    chmod +x protoc/bin/protoc
    rm protoc.zip
fi
export PATH=$C/go/bin:$C/gopath/bin:$C/protoc/bin:$PATH GOPATH=$C/gopath GOCACHE=$C/gocache
[ -x gopath/bin/protoc-gen-go ] || go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.6
if [ ! -d wowsims ]; then
    git clone -q https://github.com/wowsims/wotlk wowsims
fi
cd wowsims
git checkout -q "$WOWSIMS_COMMIT"
protoc -I=./proto --go_out=./sim/core ./proto/*.proto
mkdir -p cmd/feralcmp
cp "$HERE/main.go" cmd/feralcmp/main.go
go build -tags with_db -o "$C/feralcmp" ./cmd/feralcmp
echo "Built $C/feralcmp"
