# `libtokenizers_ffi`

**C FFI wrapper around HuggingFace's `tokenizers` and `tiktoken-rs`.**
Provides safe and ergonomic bindings for encoding and decoding text using pretrained tokenizers from Huggingface, usable from C or any language that supports C ABI.

## 🔧 Features

* Load a tokenizer from serialized JSON (`tokenizer.json`)
* Load a raw rank-based `tiktoken.model` with a custom regex and special tokens
* Encode text to token IDs
* Decode token IDs back to text
* Nullable/status returns and thread-local error details across the C ABI
* Idiomatic C API with memory-safe allocation/deallocation helpers

## 📦 Requirements

* Rust (latest `stable` or `nightly`)
* C compiler (`clang` or `gcc`)
* [Check](https://libcheck.github.io/check/) unit testing framework (optional, for running C tests)

## 🛠 Build Instructions

```bash
git clone https://github.com/yourusername/libtokenizers-ffi
cd libtokenizers-ffi

# Compile the FFI library
make

# Run both Rust and C test suites (C requires libcheck)
make test

# Install to system
sudo make install

# Clean
make clean
```

Build outputs:

* Dynamic library: `target/release/libtokenizers_ffi.{so,dylib,dll}`
* Test binary: `build/test_ffi`

To use a nonstandard `libcheck` installation (i.e. Homebrew on macOS):

```bash
make CHECK_PREFIX=/opt/homebrew
```

## 📚 Usage Example

Include the header:

```c
#include <tokenizers_ffi.h>
```

Load a tokenizer and encode/decode text:

```c
TokenizerHandle handle = tokenizers_new_from_str(json_data, json_len);
if (handle == NULL) {
    uint8_t *message = NULL;
    size_t message_len = 0;
    tokenizers_get_last_error(&message, &message_len);
    /* inspect message, then free it */
    tokenizers_free_cstring((char *)message);
}

// Encode text to tokens
uint32_t* ids = NULL;
size_t id_len = 0;
if (tokenizers_encode(handle, "Hello, world!", 13, 1, 0,
                      &ids, &id_len) != 0) {
    /* retrieve tokenizers_get_last_error() */
}

// Decode via 2-step flow
tokenizers_decode(handle, ids, id_len, 1);
uint8_t* decoded = NULL;
size_t decoded_len = 0;
tokenizers_get_decode_str(handle, &decoded, &decoded_len);

// Or decode in one step
uint8_t* decoded2 = NULL;
size_t len2 = 0;
tokenizers_decode_and_get(handle, ids, id_len, 1, &decoded2, &len2);

// The caller is responsible for freeing all allocated memory
tokenizers_free_ids(ids, id_len);
tokenizers_free_cstring((char*)decoded);
tokenizers_free_cstring((char*)decoded2);
tokenizers_free(handle);
```

## 🧪 Running Tests

Run both Rust and C tests with:

```bash
make test
```

Or individually:

```bash
make test-rust
make test-c
```

Sanitized builds (requires clang or gcc with ASan/UBSan & rust nightly):

```bash
make test-sanitize
```

Or individually:

```bash
make test-rust-sanitize
make test-c-sanitize
```

On MacOS, memory leak detection is limited and LSan is unsupported.

## 📜 License

Artistic License 2.0
(C) 2025 Matt Doughty `<matt@apogee.guru>`

The file at `tests/fixtures/tokenizer.json` is (C) 2025 Mistral AI.

It is extracted from Mistral Nemo, which is an Apache 2.0 licensed model.

The `tiktoken-rs` dependency is MIT licensed.
