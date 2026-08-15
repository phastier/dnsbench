# dnsbench — Makefile
# Build natif, une cible par défaut. Aucune dépendance hors toolchain Swift.
#
#   make            compile le binaire optimisé
#   make run        compile puis lance avec ./dnsbench.conf
#   make debug      build non optimisé (symboles, pour lldb)
#   make clean      supprime le binaire

SWIFTC    ?= swiftc
SWIFTFLAGS ?= -O
BIN        := dnsbench
SRC        := dnsbench.swift
CONF       := dnsbench.conf

$(BIN): $(SRC)
	$(SWIFTC) $(SWIFTFLAGS) $(SRC) -o $(BIN)

.PHONY: run debug clean
run: $(BIN)
	./$(BIN) $(CONF)

debug: $(SRC)
	$(SWIFTC) -Onone -g $(SRC) -o $(BIN)

clean:
	rm -f $(BIN)

# --- Cross-compilation (Swift Static Linux SDK, swift.org) ---------------
#   Prerequis (une fois) :
#     swift sdk install https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
#       --checksum 87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b
#   Binaires statiques musl, zero dependance sur la cible.

.PHONY: linux-arm64 linux-amd64
linux-arm64:
	swift build -c release --swift-sdk aarch64-swift-linux-musl
	@mkdir -p dist && cp .build/aarch64-swift-linux-musl/release/dnsbench dist/dnsbench-linux-arm64
	@echo "-> dist/dnsbench-linux-arm64"

linux-amd64:
	swift build -c release --swift-sdk x86_64-swift-linux-musl
	@mkdir -p dist && cp .build/x86_64-swift-linux-musl/release/dnsbench dist/dnsbench-linux-amd64
	@echo "-> dist/dnsbench-linux-amd64"
