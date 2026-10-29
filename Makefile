NIM ?= nim
# C backend: use clang (LLVM) for all Nim builds. Override with --cc: on the
# make command line (e.g. make CC=gcc) or NIM_EXTRA_FLAGS="--cc:gcc" if needed.
NIM_EXTRA_FLAGS := --cc:clang
CXX ?= c++
NATIVE_OPT ?= 1
USE_PGO ?= 0
TCP_FASTOPEN_QUEUE ?= 4096
IOURING_MAX_CONNECTIONS ?= 65536
IOURING_RECV_BUFFERS ?= 8192
IOURING_RECV_BUFFER_SIZE ?= 2048
IOURING_ENTRIES ?= 2048

USOCKETS_LIB ?= nim_usockets/usockets/uSockets.a
USOCKETS_DIR ?= nim_usockets/usockets
USOCKETS_STAMP ?= $(USOCKETS_DIR)/.uSockets.backend
PGO_DIR ?= benchmark/.pgo-data
BOLT_FDATA ?= benchmark/.bolt.fdata

# Detect OS
UNAME_S := $(shell uname -s)

# Allow override of USOCKETS_BACKEND from command line
# Default based on OS if not specified
ifeq ($(USOCKETS_BACKEND),)
  USOCKETS_BACKEND := $(shell echo $(UNAME_S) | sed 's/Darwin/gcd/; s/Linux/epoll/')
endif

ifeq ($(filter $(USOCKETS_BACKEND),epoll io_uring gcd kqueue),)
  $(error Unsupported USOCKETS_BACKEND=$(USOCKETS_BACKEND); use epoll, io_uring, gcd, or kqueue)
endif

# Paths
JEMALLOC_LIBDIR ?= $(shell test -d /opt/homebrew/lib && echo /opt/homebrew/lib || echo /usr/lib)
HAVE_JEMALLOC := $(shell test -f "$(JEMALLOC_LIBDIR)/libjemalloc.so" -o -f "$(JEMALLOC_LIBDIR)/libjemalloc.a" -o -f "$(JEMALLOC_LIBDIR)/libjemalloc.dylib" && echo 1 || echo 0)

# Base Nim flags
NIM_FLAGS ?= -d:release -d:danger --opt:speed --mm:arc --stackTrace:on --panics:off \
  --path:nim_utils/src --path:nim_usockets/src --path:nim_express/src --path:nim_fasthttpclient/src \
  --path:vendor/zippy/src --path:vendor/brotli/src --path:vendor/nim_zstd \
  --path:vendor/nim_libdeflate_gzip/src --path:vendor/malebolgia/src \
  --path:vendor/jsony/src --path:vendor/checksums --path:vendor/nimsimd/src

# Platform link flags
PLATFORM_LINK_FLAGS_DARWIN = -framework CoreFoundation
PLATFORM_LINK_FLAGS_LINUX = -lpthread -ldl

# Add jemalloc if available
ifeq ($(HAVE_JEMALLOC),1)
  ifeq ($(UNAME_S),Darwin)
    PLATFORM_LINK_FLAGS_DARWIN += -L$(JEMALLOC_LIBDIR) -ljemalloc
  else
    PLATFORM_LINK_FLAGS_LINUX += -L$(JEMALLOC_LIBDIR) -ljemalloc
  endif
endif

# Select link flags based on OS
ifeq ($(UNAME_S),Darwin)
  LINK_FLAGS := $(USOCKETS_LIB) $(PLATFORM_LINK_FLAGS_DARWIN)
else
  LINK_FLAGS := $(USOCKETS_LIB) $(PLATFORM_LINK_FLAGS_LINUX)
endif

# Backend-specific build env for uSockets
USOCKETS_BUILD_ENV :=

ifeq ($(UNAME_S),Linux)
  ifeq ($(USOCKETS_BACKEND),gcd)
    $(error USOCKETS_BACKEND=gcd is macOS-only; use epoll or io_uring on Linux)
  endif
  ifeq ($(USOCKETS_BACKEND),kqueue)
    $(error USOCKETS_BACKEND=kqueue is not a supported Linux backend; use epoll or io_uring)
  endif
endif
ifeq ($(UNAME_S),Darwin)
  ifeq ($(USOCKETS_BACKEND),epoll)
    $(error USOCKETS_BACKEND=epoll is Linux-only; use gcd on macOS)
  endif
  ifeq ($(USOCKETS_BACKEND),io_uring)
    $(error USOCKETS_BACKEND=io_uring is Linux-only; use gcd on macOS)
  endif
endif

# Backend selection logic
ifeq ($(USOCKETS_BACKEND),io_uring)
  USOCKETS_BUILD_ENV := WITH_IO_URING=1
  LINK_FLAGS += -luring
  NIM_EXTRA_FLAGS += -d:LIBUS_USE_IO_URING
else ifeq ($(USOCKETS_BACKEND),kqueue)
  ifeq ($(UNAME_S),Darwin)
    $(warning kqueue backend is not supported for this stack on macOS, using GCD)
    USOCKETS_BUILD_ENV := WITH_GCD=1
    USOCKETS_BACKEND := gcd
    NIM_EXTRA_FLAGS += -d:LIBUS_USE_GCD
  else
    USOCKETS_BUILD_ENV := WITH_GCD=0
  endif
else ifeq ($(USOCKETS_BACKEND),gcd)
  USOCKETS_BUILD_ENV := WITH_GCD=1
  NIM_EXTRA_FLAGS += -d:LIBUS_USE_GCD
else
  # epoll (Linux default)
  ifeq ($(UNAME_S),Linux)
    USOCKETS_BUILD_ENV := 
  else
    USOCKETS_BUILD_ENV := WITH_GCD=1
    NIM_EXTRA_FLAGS += -d:LIBUS_USE_GCD
  endif
endif

# LLVM BOLT
LLVM_BOLT ?= llvm-bolt
ifeq ($(USE_PGO),1)
  PGO_PROFILE_COUNT := $(shell test -d "$(PGO_DIR)" && find "$(PGO_DIR)" -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)
else
  PGO_PROFILE_COUNT := 0
endif
HAVE_LLVM_BOLT := $(shell command -v "$(LLVM_BOLT)" >/dev/null 2>&1 && echo 1 || echo 0)
HAVE_BOLT_FDATA := $(shell test -s "$(BOLT_FDATA)" && echo 1 || echo 0)

# Optimization flags
C_OPT_FLAGS := -fomit-frame-pointer -ffunction-sections -fdata-sections
L_OPT_FLAGS :=
TRANSPORT_CFLAGS := -DLIBUS_TCP_FASTOPEN_QUEUE=$(TCP_FASTOPEN_QUEUE)

ifeq ($(USOCKETS_BACKEND),io_uring)
  TRANSPORT_CFLAGS += -DLIBUS_IO_URING_MAX_CONNECTIONS=$(IOURING_MAX_CONNECTIONS) -DLIBUS_IO_URING_RECV_BUFFERS=$(IOURING_RECV_BUFFERS) -DLIBUS_IO_URING_RECV_BUFFER_SIZE=$(IOURING_RECV_BUFFER_SIZE) -DLIBUS_IO_URING_ENTRIES=$(IOURING_ENTRIES)
endif

C_OPT_FLAGS += $(TRANSPORT_CFLAGS)

ifeq ($(UNAME_S),Darwin)
  C_OPT_FLAGS += -flto=thin
  L_OPT_FLAGS += -flto=thin -Wl,-dead_strip
else
  C_OPT_FLAGS += -flto -D_GNU_SOURCE
  L_OPT_FLAGS += -flto -Wl,--gc-sections
endif

ifeq ($(NATIVE_OPT),1)
  C_OPT_FLAGS += -march=native -mtune=native
endif

# PGO
ifneq ($(PGO_PROFILE_COUNT),0)
  C_OPT_FLAGS += -fprofile-use=$(abspath $(PGO_DIR)) -fprofile-correction -Wno-error=coverage-mismatch
  L_OPT_FLAGS += -fprofile-use=$(abspath $(PGO_DIR)) -fprofile-correction
endif

# WebSocket load tester (nim_websocketcli; pairs with benchmark/ws_echo_bench)
WEBSOCKETLOAD_BIN ?= nim_websocketcli/websocketload
WS_RANDOM_OBJECT_BENCH_BIN ?= benchmark/ws_random_object_bench

# Build targets
.PHONY: all build build-all deps check-iouring-deps usockets validate-usockets-backend usockets-gcd usockets-kqueue usockets-epoll usockets-iouring bench benchmarks bench-gcd bench-kqueue bench-epoll bench-iouring bench-smoke linux-compat-check macos-smoke production-check websocketload ws-echo-bench ws-random-object-bench ws-scale-setup examples build-examples test coverage verify clean clean-examples clean-bench clean-all

NIM_PARALLEL ?= --parallelBuild:8

all: build-all

# Build uSockets.
build: build-all

build-all: deps usockets

deps:
	./scripts/ensure_deps.sh

check-iouring-deps:
	@if [ "$(UNAME_S)" = "Linux" ] && [ "$(USOCKETS_BACKEND)" = "io_uring" ]; then \
		if ! pkg-config --exists liburing 2>/dev/null && [ ! -r /usr/include/liburing.h ]; then \
			echo "USOCKETS_BACKEND=io_uring requires liburing development headers (install liburing-dev)." >&2; \
			exit 1; \
		fi; \
	fi

# GCC 14+ emits slim LTO objects (pruned .symtab, only __gnu_lto_slim). A plain
# `ar` cannot index them, so uSockets.a exposes no symbols and every us_*
# reference fails with "undefined reference". Archive with the GCC wrapper so
# the LTO plugin indexes real symbols (only needed where GNU LTO is enabled).
ifeq ($(UNAME_S),Linux)
# uSockets is compiled with clang (LLVM) + LTO; pack the bitcode objects with
# llvm-ar (gcc-ar produces an archive clang's LTO link cannot resolve).
USOCKETS_AR := AR=llvm-ar
endif

usockets: check-iouring-deps
	$(MAKE) -C $(USOCKETS_DIR) clean
	$(MAKE) -C $(USOCKETS_DIR) $(USOCKETS_BUILD_ENV) $(USOCKETS_AR) CC=clang CXX=clang++ CFLAGS="$(C_OPT_FLAGS)"
	@printf '%s\n' \
		'backend=$(USOCKETS_BACKEND)' \
		'env=$(USOCKETS_BUILD_ENV)' \
		'cflags=$(C_OPT_FLAGS)' > "$(USOCKETS_STAMP)"

validate-usockets-backend:
	@test -f "$(USOCKETS_LIB)" || { echo "missing $(USOCKETS_LIB); run make usockets USOCKETS_BACKEND=$(USOCKETS_BACKEND)" >&2; exit 1; }
	@test -f "$(USOCKETS_STAMP)" || { echo "missing $(USOCKETS_STAMP); rebuild with make usockets USOCKETS_BACKEND=$(USOCKETS_BACKEND)" >&2; exit 1; }
	@grep -Fx 'backend=$(USOCKETS_BACKEND)' "$(USOCKETS_STAMP)" >/dev/null || { \
		echo "$(USOCKETS_LIB) was built for a different backend:" >&2; \
		cat "$(USOCKETS_STAMP)" >&2; \
		echo "rebuild with make usockets USOCKETS_BACKEND=$(USOCKETS_BACKEND)" >&2; \
		exit 1; \
	}
	@grep -Fx 'cflags=$(C_OPT_FLAGS)' "$(USOCKETS_STAMP)" >/dev/null || { \
		echo "$(USOCKETS_LIB) was built with different transport/compiler flags:" >&2; \
		cat "$(USOCKETS_STAMP)" >&2; \
		echo "rebuild with make usockets USOCKETS_BACKEND=$(USOCKETS_BACKEND)" >&2; \
		exit 1; \
	}

usockets-gcd:
	$(MAKE) usockets USOCKETS_BACKEND=gcd

usockets-kqueue:
	$(MAKE) usockets USOCKETS_BACKEND=kqueue

usockets-epoll:
	$(MAKE) usockets USOCKETS_BACKEND=epoll

usockets-iouring:
	$(MAKE) usockets USOCKETS_BACKEND=io_uring

# Build bench (use USOCKETS_BACKEND=io_uring to build with io_uring)
BENCH_SRC ?= benchmark/bench_nim_express.nim
BENCH_BIN ?= benchmark/bench_nim_express
BENCH_SMOKE_DIR ?= /tmp/nim_uwebsocket_bench_smoke

bench benchmarks: deps usockets
	$(NIM) c $(NIM_FLAGS) $(NIM_EXTRA_FLAGS) \
		--passC:"$(C_OPT_FLAGS)" \
		--passL:"$(LINK_FLAGS) $(L_OPT_FLAGS)" \
		-o:$(BENCH_BIN) $(BENCH_SRC)
ifneq ($(HAVE_LLVM_BOLT),0)
ifneq ($(HAVE_BOLT_FDATA),0)
	$(LLVM_BOLT) $(BENCH_BIN) -o $(BENCH_BIN) -data=$(BOLT_FDATA) -reorder-blocks=ext-tsp -reorder-functions=hfsort+ -split-functions=3 -split-all-cold -icf=1 -dyno-stats
endif
endif

bench-gcd:
	$(MAKE) bench USOCKETS_BACKEND=gcd

bench-kqueue:
	$(MAKE) bench USOCKETS_BACKEND=kqueue

bench-epoll:
	$(MAKE) bench USOCKETS_BACKEND=epoll

bench-iouring:
	$(MAKE) bench USOCKETS_BACKEND=io_uring

bench-smoke: deps
	@mkdir -p $(BENCH_SMOKE_DIR)
	$(NIM) c --compileOnly -d:release --nimcache:$(BENCH_SMOKE_DIR)/fastmap \
		$(NIM_EXTRA_FLAGS) \
		--path:nim_utils/src \
		-o:$(BENCH_SMOKE_DIR)/bench_fastmap nim_utils/benchmark/bench_fastmap.nim
	$(NIM) c --compileOnly -d:release --nimcache:$(BENCH_SMOKE_DIR)/hpack \
		$(NIM_EXTRA_FLAGS) \
		--path:nim_utils/src --path:nim_usockets/src \
		-o:$(BENCH_SMOKE_DIR)/bench_hpack benchmark/bench_hpack.nim
	$(NIM) c --compileOnly -d:release --nimcache:$(BENCH_SMOKE_DIR)/h2_frames \
		$(NIM_EXTRA_FLAGS) \
		--path:nim_utils/src --path:nim_usockets/src \
		-o:$(BENCH_SMOKE_DIR)/bench_h2_frames benchmark/bench_h2_frames.nim
	$(NIM) c --compileOnly -d:release --nimcache:$(BENCH_SMOKE_DIR)/websocket \
		$(NIM_EXTRA_FLAGS) \
		--path:nim_utils/src --path:nim_usockets/src \
		-o:$(BENCH_SMOKE_DIR)/bench_websocket benchmark/bench_websocket.nim
	$(NIM) c --compileOnly -d:release --nimcache:$(BENCH_SMOKE_DIR)/fasthttpclient \
		$(NIM_EXTRA_FLAGS) \
		--path:nim_utils/src --path:nim_usockets/src --path:nim_fasthttpclient/src \
		--path:vendor/zippy/src --path:vendor/brotli/src --path:vendor/nim_zstd \
		--path:vendor/nim_libdeflate_gzip/src --path:vendor/malebolgia/src \
		--path:vendor/jsony/src --path:vendor/checksums --path:vendor/nimsimd/src \
		-o:$(BENCH_SMOKE_DIR)/bench_fasthttpclient nim_fasthttpclient/benchmark/bench_client.nim
		$(NIM) c --compileOnly -d:release --nimcache:$(BENCH_SMOKE_DIR)/express \
			$(NIM_EXTRA_FLAGS) \
			--path:nim_utils/src --path:nim_usockets/src --path:nim_fasthttpclient/src --path:nim_express/src \
			--path:vendor/zippy/src --path:vendor/brotli/src --path:vendor/nim_zstd \
			--path:vendor/nim_libdeflate_gzip/src --path:vendor/malebolgia/src \
			--path:vendor/jsony/src --path:vendor/checksums --path:vendor/nimsimd/src \
			-o:$(BENCH_SMOKE_DIR)/bench_nim_express benchmark/bench_nim_express.nim

linux-compat-check: deps
	NIM_EXTRA_FLAGS="$(NIM_EXTRA_FLAGS)" ./scripts/linux_target_check.sh

macos-smoke: deps
	NIM_EXTRA_FLAGS="$(NIM_EXTRA_FLAGS)" bash ./scripts/macos_smoke.sh

	# WebSocket CLI load tester (requires nim_fasthttpclient + uSockets).
# --skipProjCfg: nim_websocketcli/nim.cfg uses ../ paths for standalone builds from that dir;
# from repo root, Makefile LINK_FLAGS already supplies uSockets.a.
websocketload: deps usockets
	$(NIM) c --skipProjCfg --threads:on $(NIM_FLAGS) $(NIM_EXTRA_FLAGS) \
		--passC:"$(C_OPT_FLAGS)" \
		--passL:"$(LINK_FLAGS) $(L_OPT_FLAGS)" \
		-o:$(WEBSOCKETLOAD_BIN) nim_websocketcli/websocketload.nim

# WebSocket echo bench (`THREADS` env enables runThreaded + SO_REUSEPORT; omit for single process).
ws-echo-bench: deps usockets
	$(NIM) c --threads:on $(NIM_FLAGS) $(NIM_EXTRA_FLAGS) \
		--passC:"$(C_OPT_FLAGS)" \
		--passL:"$(LINK_FLAGS) $(L_OPT_FLAGS)" \
		-o:benchmark/ws_echo_bench benchmark/ws_echo_bench.nim

ws-random-object-bench: deps usockets
	$(NIM) c --threads:on $(NIM_FLAGS) $(NIM_EXTRA_FLAGS) \
		--passC:"$(C_OPT_FLAGS)" \
		--passL:"$(LINK_FLAGS) $(L_OPT_FLAGS)" \
		-o:$(WS_RANDOM_OBJECT_BENCH_BIN) benchmark/ws_random_object_bench.nim

# Linux: sysctl + loopback aliases for large WS client fanout (run: sudo bash …/ws_scale_linux.sh N).
ws-scale-setup:
	@chmod +x nim_websocketcli/scripts/ws_scale_linux.sh 2>/dev/null || true
	@echo "Run: sudo bash $(CURDIR)/nim_websocketcli/scripts/ws_scale_linux.sh 64"

# Build examples in parallel
examples build-examples: deps usockets
	@mkdir -p examples/bin
	@set -e; cd examples; for file in *.nim; do \
		name=$${file%.nim}; \
			echo "Building $$name"; \
			$(NIM) c $(NIM_PARALLEL) -d:release --opt:speed --mm:arc --stackTrace:on $(NIM_EXTRA_FLAGS) \
				--path:../nim_utils/src --path:../nim_usockets/src --path:../nim_express/src --path:../nim_fasthttpclient/src \
				--path:../vendor/zippy/src --path:../vendor/brotli/src --path:../vendor/nim_zstd \
				--path:../vendor/nim_libdeflate_gzip/src --path:../vendor/malebolgia/src \
				--path:../vendor/jsony/src --path:../vendor/checksums --path:../vendor/nimsimd/src \
				--passC:"$(C_OPT_FLAGS)" \
				--passL:"../$(LINK_FLAGS) $(L_OPT_FLAGS)" -o:"bin/$$name" "./$$file"; \
		done

test: deps usockets
	NIM_EXTRA_FLAGS="$(NIM_EXTRA_FLAGS)" bash scripts/test_all.sh

coverage:
	bash scripts/coverage.sh

verify: deps usockets
	NIM_EXTRA_FLAGS="$(NIM_EXTRA_FLAGS)" ./scripts/verify.sh

production-check: verify bench-smoke

# Clean targets
clean: clean-examples clean-bench
	rm -f $(USOCKETS_DIR)/*.o $(USOCKETS_DIR)/*.a $(USOCKETS_DIR)/.certs 2>/dev/null || true
	rm -f $(USOCKETS_STAMP) 2>/dev/null || true
	find nim_utils/src/nim_utils/nim_fastjson -name "*.o" -delete 2>/dev/null || true
	find nim_express/tests nim_fasthttpclient/tests nim_usockets/tests nim_utils/tests \
		-maxdepth 1 -type f -perm -111 ! -name "*.nim" -delete 2>/dev/null || true

clean-examples:
	rm -f examples/bin/* 2>/dev/null || true

clean-bench:
	rm -f benchmark/bench_nim_express benchmark/bench_nim_express_cluster benchmark/bench_nim_express_threaded \
		benchmark/bench_nim_express_multiport benchmark/bench_nim_express_bigjson \
		benchmark/ws_echo_server benchmark/ws_broadcast_server benchmark/ws_echo_bench \
		benchmark/ws_random_object_bench benchmark/bench_test \
		$(WEBSOCKETLOAD_BIN) 2>/dev/null || true

clean-all: clean
	rm -f examples/bin/* 2>/dev/null || true
	rm -f benchmark/bench_nim_express benchmark/bench_nim_express_cluster benchmark/bench_nim_express_threaded \
		benchmark/bench_nim_express_multiport benchmark/bench_nim_express_bigjson \
		benchmark/ws_echo_server benchmark/ws_broadcast_server benchmark/ws_echo_bench \
		benchmark/ws_random_object_bench benchmark/bench_test \
		$(WEBSOCKETLOAD_BIN) 2>/dev/null || true

docs: docs-express docs-usockets docs-fasthttpclient docs-fastjson docs-async-logger docs-fast-map docs-fast-set
	@echo "API docs generated in doc/api/"

docs-express:
	@echo "Generating nim_express API docs (full per-module reference)..."
	rm -rf doc/api/express/
	mkdir -p doc/api/express/
	$(NIM) doc --project --outdir:"doc/api/express/" \
		--path:nim_utils/src --path:nim_usockets/src --path:nim_express/src --path:nim_fasthttpclient/src \
		--path:vendor/zippy/src --path:vendor/brotli/src --path:vendor/nim_zstd \
		--path:vendor/nim_libdeflate_gzip/src --path:vendor/malebolgia/src \
		--path:vendor/jsony/src --path:vendor/checksums --path:vendor/nimsimd/src \
		nim_express/src/nim_express.nim

docs-fastjson:
	@echo "Generating nim_fastjson API docs..."
	rm -rf doc/api/fastjson/
	mkdir -p doc/api/fastjson/
	$(NIM) doc --outdir:"doc/api/fastjson/" \
		--path:nim_utils/src --path:vendor/nimsimd/src \
		nim_utils/src/nim_utils/nim_fastjson.nim

docs-async-logger:
	@echo "Generating async_logger API docs..."
	rm -rf doc/api/async-logger/
	mkdir -p doc/api/async-logger/
	$(NIM) doc --outdir:"doc/api/async-logger/" \
		--path:nim_utils/src --path:vendor/nimsimd/src \
		nim_utils/src/nim_utils/async_logger.nim

docs-fast-map:
	@echo "Generating fast_map API docs..."
	rm -rf doc/api/fast-map/
	mkdir -p doc/api/fast-map/
	$(NIM) doc --outdir:"doc/api/fast-map/" \
		--path:nim_utils/src --path:vendor/nimsimd/src \
		nim_utils/src/nim_utils/helpers/fast_map.nim

docs-usockets:
	@echo "Generating nim_usockets API docs..."
	rm -rf doc/api/usockets/
	mkdir -p doc/api/usockets/
	$(NIM) doc --outdir:"doc/api/usockets/" \
		--path:nim_utils/src --path:nim_usockets/src \
		--path:vendor/zippy/src --path:vendor/brotli/src --path:vendor/nim_zstd \
		--path:vendor/nim_libdeflate_gzip/src --path:vendor/malebolgia/src \
		--path:vendor/jsony/src --path:vendor/checksums --path:vendor/nimsimd/src \
		nim_usockets/src/nim_usockets.nim

docs-fasthttpclient:
	@echo "Generating nim_fasthttpclient API docs..."
	rm -rf doc/api/fasthttpclient/
	mkdir -p doc/api/fasthttpclient/
	$(NIM) doc --outdir:"doc/api/fasthttpclient/" \
		--path:nim_utils/src --path:nim_usockets/src --path:nim_fasthttpclient/src \
		--path:vendor/zippy/src --path:vendor/brotli/src --path:vendor/nim_zstd \
		--path:vendor/nim_libdeflate_gzip/src --path:vendor/malebolgia/src \
		--path:vendor/jsony/src --path:vendor/checksums --path:vendor/nimsimd/src \
		nim_fasthttpclient/src/nim_fasthttpclient.nim

docs-fast-set:
	@echo "Generating fast_set API docs..."
	rm -rf doc/api/fast-set/
	mkdir -p doc/api/fast-set/
	$(NIM) doc --outdir:"doc/api/fast-set/" \
		--path:nim_utils/src --path:vendor/nimsimd/src \
		nim_utils/src/nim_utils/helpers/fast_set.nim

.PHONY: docs docs-express docs-usockets docs-fasthttpclient docs-fastjson docs-async-logger docs-fast-map docs-fast-set

.DEFAULT_GOAL := all
