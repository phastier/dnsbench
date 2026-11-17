# dnsbench v2 - build & run
#
#   make                 optimized build (swiftc -O)
#   make run             build + run with ./dnsbench.conf
#   make debug           debug build -> ./dnsbench-debug (does NOT overwrite the release binary)
#   make static-stdlib   Linux/glibc: embed the Swift runtime (drop-anywhere on same-arch distros)
#   make macos-arm64     macOS release asset, pinned deployment target -> dist/dnsbench-macos-arm64
#   make linux-arm64     static musl cross-build -> dist/dnsbench-linux-arm64
#   make linux-amd64     static musl cross-build -> dist/dnsbench-linux-amd64
#   make clean

SWIFTC     ?= swiftc
SWIFTFLAGS ?= -O
BIN        := dnsbench
SRC        := dnsbench.swift
CONF       := dnsbench.conf
MACOS_TARGET ?= arm64-apple-macos26.0

$(BIN): $(SRC)
	$(SWIFTC) $(SWIFTFLAGS) $(SRC) -o $(BIN)

.PHONY: run debug static-stdlib macos-arm64 linux-arm64 linux-amd64 clean

run: $(BIN)
	./$(BIN) $(CONF)

# v1's `make debug` compiled the debug source over the release binary name;
# v2 keeps them separate. The debug binary only differs by -Onone -g
# (runtime verbosity is now the -v/--verbose flag, no forked source).
debug: $(SRC)
	$(SWIFTC) -Onone -g $(SRC) -o $(BIN)-debug

# Linux only: statically link the Swift runtime into the binary (glibc build).
static-stdlib: $(SRC)
	$(SWIFTC) $(SWIFTFLAGS) -static-stdlib $(SRC) -o $(BIN)

# macOS release asset. A plain `make` targets the build host's OS version, so
# a binary built on a newer macOS refuses to start on an older one; the asset
# pins the deployment target instead.
macos-arm64: $(SRC)
	@mkdir -p dist
	$(SWIFTC) $(SWIFTFLAGS) -target $(MACOS_TARGET) $(SRC) -o dist/dnsbench-macos-arm64
	@echo "-> dist/dnsbench-macos-arm64"

# --- Cross-compilation (Swift Static Linux SDK, swift.org) ---------------
#   Prerequisite (once):
#     swift sdk install https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
#       --checksum 87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b
#   Static musl binaries, zero dependency on the target. Same recipe as v1.

linux-arm64:
	swift build -c release --swift-sdk aarch64-swift-linux-musl
	@mkdir -p dist && cp .build/aarch64-swift-linux-musl/release/dnsbench dist/dnsbench-linux-arm64
	@echo "-> dist/dnsbench-linux-arm64"

linux-amd64:
	swift build -c release --swift-sdk x86_64-swift-linux-musl
	@mkdir -p dist && cp .build/x86_64-swift-linux-musl/release/dnsbench dist/dnsbench-linux-amd64
	@echo "-> dist/dnsbench-linux-amd64"

clean:
	rm -f $(BIN) $(BIN)-debug
