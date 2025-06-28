# Path to Check, settable by caller
CHECK_PREFIX ?= /usr

# Platform detection
UNAME_S := $(shell uname)
ifeq ($(OS),Windows_NT)
	LIB_EXT := dll
	DYLIB_PREFIX :=
	INSTALL_LIB_PATH := /usr/local/bin
	LIB_EXTRA := 
else ifeq ($(UNAME_S),Darwin)
	LIB_EXT := dylib
	DYLIB_PREFIX := lib
	INSTALL_LIB_PATH := /usr/local/lib
	LIB_EXTRA :=
else
	LIB_EXT := so
	DYLIB_PREFIX := lib
	INSTALL_LIB_PATH := /usr/local/lib
	LIB_EXTRA := -lm -lsubunit
endif

# Output paths
BUILD_DIR := build
LIB_DIR := target/release
DYLIB := $(LIB_DIR)/libtokenizers_ffi.$(LIB_EXT)
DYLIB_NAME := libtokenizers_ffi.$(LIB_EXT)
HEADER := include/tokenizers_ffi.h
TEST_BIN := $(BUILD_DIR)/test_ffi
TEST_BIN_SAN := $(BUILD_DIR)/test_ffi_san

# Sanitizer setup
ifeq ($(UNAME_S),Darwin)
	ASAN_ENV := ASAN_OPTIONS=halt_on_error=1
else
	ASAN_ENV := ASAN_OPTIONS=detect_leaks=1:halt_on_error=1
endif
SAN_FLAGS := -fsanitize=address,undefined -fno-omit-frame-pointer

.PHONY: all test install clean test-rust test-c test-sanitize test-c-sanitize test-rust-sanitize

all: $(DYLIB)

$(DYLIB):
	cargo build --release

test: test-rust test-c

test-rust:
	cargo test --quiet

test-c: $(TEST_BIN)
	$(TEST_BIN)

test-sanitize: test-c-sanitize test-rust-sanitize

test-c-sanitize: $(TEST_BIN_SAN)
	$(ASAN_ENV) $(TEST_BIN_SAN)

test-rust-sanitize:
	@rustup show active-toolchain | grep -q nightly || \
	(echo "❌ Rust nightly required for sanitizer tests"; exit 1)
	RUSTFLAGS="-Z sanitizer=address -C opt-level=0 -C debuginfo=2" \
	cargo +nightly test -Z build-std=std -- --nocapture

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TEST_BIN): $(DYLIB) tests/c/test_ffi.c | $(BUILD_DIR)
	cc -Iinclude -I$(CHECK_PREFIX)/include tests/c/test_ffi.c -o $(TEST_BIN) \
		-L$(LIB_DIR) $(LIB_DIR)/$(DYLIB_NAME) -L$(CHECK_PREFIX)/lib -lcheck $(LIB_EXTRA)

$(TEST_BIN_SAN): $(DYLIB) tests/c/test_ffi.c | $(BUILD_DIR)
	cc -g -O0 $(SAN_FLAGS) -Iinclude -I$(CHECK_PREFIX)/include tests/c/test_ffi.c \
		-o $(TEST_BIN_SAN) $(LIB_DIR)/$(DYLIB_NAME) -L$(CHECK_PREFIX)/lib -lcheck $(LIB_EXTRA)

install: $(DYLIB)
	install -Dm755 $(DYLIB) $(INSTALL_LIB_PATH)/$(notdir $(DYLIB))
	install -Dm644 $(HEADER) /usr/local/include/tokenizers_ffi.h

clean:
	cargo clean
	rm -rf $(BUILD_DIR)

