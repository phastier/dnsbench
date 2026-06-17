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
