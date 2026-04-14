[![Actions Status](https://github.com/m-doughty/Raku-Tokenizers/actions/workflows/test.yml/badge.svg)](https://github.com/m-doughty/Raku-Tokenizers/actions)

NAME
====

Tokenizers - Raku bindings for HuggingFace Tokenizers via a native Rust cdylib

SYNOPSIS
========

```raku
use Tokenizers;

my $json = slurp 't/fixtures/tokenizer.json';
my $tok  = Tokenizers.new-from-json($json);

my @ids = $tok.encode('Hello, world!');   # (9906, 11, 1917, 0)
say $tok.decode(@ids);                    # Hello, world!
say $tok.count('Hello, world!');          # 4
```

DESCRIPTION
===========

`Tokenizers` is a thin Raku wrapper around the HuggingFace `tokenizers` Rust crate, exposed via a small FFI shim (`libtokenizers_ffi`). You can load any `tokenizer.json` produced by HuggingFace tooling — BPE, WordPiece, Unigram, SentencePiece, etc. — and encode/decode text or get token counts without running a Python transformer stack.

Designed to be dropped into monorepos that do synthetic roleplay data generation, local-LLM token counting, or any pipeline where you already have a `tokenizer.json` file and just want fast, lightweight tokenisation from Raku.

INSTALLATION
============

    zef install Tokenizers

On install, `Build.rakumod` tries two paths in order:

  * **Prebuilt binary download** from this repo's GitHub Releases for the detected (OS, arch) pair. Statically-linked Rust cdylib (macOS artefact is universal — arm64 + x86_64 slices), verified against a SHA256 bundled in the distribution (`resources/checksums.txt`). Typically ~15 MB, ~2–10 seconds on a decent connection. This is the default path when a matching release exists.

  * **Source compile fallback** via `cargo build --release` on the vendored `libtokenizers-ffi` crate. Used when no prebuilt is available for the platform, when the download fails, when the checksum doesn't match, or when the user has opted out of prebuilts. Takes ~5–10 minutes from a cold cargo cache — the HuggingFace tokenizers crate pulls in a sizeable dep tree.

Supported prebuilt platforms
----------------------------

  * macOS universal (arm64 + x86_64 slices in one dylib)

  * Linux x86_64 glibc

  * Linux aarch64 glibc

  * Windows x86_64

  * Windows arm64 (Copilot+ PCs, Snapdragon X)

On platforms outside this list (Alpine musl, BSDs, i686, etc.) the fallback compile path runs automatically; you'll need `cargo` and a C toolchain installed.

Environment variables
---------------------

  * `TOKENIZERS_BUILD_FROM_SOURCE=1` — skip the prebuilt path and always compile from vendored source.

  * `TOKENIZERS_BINARY_ONLY=1` — refuse to fall back to compile if the prebuilt is unavailable. Useful in CI where a 10× slower install via surprise compile is worse than a loud failure.

  * `TOKENIZERS_BINARY_URL=<url>` — override the GitHub Releases base URL. For private mirrors or air-gapped setups.

  * `TOKENIZERS_CACHE_DIR=<path>` — override the download cache location. Defaults to `$XDG_CACHE_HOME/Tokenizers-binaries/` or `~/.cache/Tokenizers-binaries/`.

  * `TOKENIZERS_LIB=<path>` — bypass `%?RESOURCES` entirely and load the library from an explicit path. Undocumented escape hatch; you take full responsibility for ABI compatibility.

Building from source (for devs)
-------------------------------

If you're hacking on the `libtokenizers-ffi` crate itself rather than the Raku bindings, the Rust crate lives at `vendor/tokenizers-ffi/`. The vendored `Makefile` supports `make`, `make test`, `make test-sanitize`. The Raku `Build.rakumod`'s fallback path invokes cargo directly rather than going through the Makefile so it's insulated from Makefile-only dev targets.

Binary release versioning
-------------------------

Prebuilt binaries are tagged independently of the Raku distribution:

    binaries-tokenizers-<upstream-version>-r<recipe-revision>

e.g. `binaries-tokenizers-0.1.0-r1`. The `upstream-version` tracks the vendored `libtokenizers-ffi` crate version; `recipe-revision` bumps only when build flags change (target triples, strip options, platform additions) while the upstream library stays the same.

`Build.rakumod` reads the pinned binary tag from the top-level `BINARY_TAG` file so a Raku-side bugfix release of `Tokenizers` can ship without rebuilding binaries — users upgrading within the same binary tag get their download from the cache, not the network.

API
===

`Tokenizers.new-from-json($json)`
---------------------------------

Builds a tokenizer from a HuggingFace `tokenizer.json` string. Returns a `Tokenizers` instance. Throws if the JSON is malformed or references an unknown tokenizer type.

`.encode($text, :$add-special-tokens = True --` List)>
------------------------------------------------------

Tokenises `$text` and returns a List of token IDs (`UInt`). With `:!add-special-tokens` you get just the content tokens — useful for concatenating into larger sequences.

`.decode(@ids, :$skip-special-tokens = False --` Str)>
------------------------------------------------------

Reconstructs a string from a List of token IDs. With `:skip-special-tokens` drops BOS/EOS/PAD tokens from the output.

`.count(Str $text, :$add-special-tokens = True --` Int)>
--------------------------------------------------------

Shortcut for `.encode($text, :$add-special-tokens).elems`.

Resource management
-------------------

The underlying Rust tokenizer is freed automatically via Raku's GC (`DESTROY`). There's no explicit `.dispose` today; if you need deterministic cleanup (long-running process holding many tokenizers) call `$tok = Nil` to trigger collection.

AUTHOR
======

Matt Doughty

COPYRIGHT AND LICENSE
=====================

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

The vendored `libtokenizers-ffi` crate is licensed under Artistic License 2.0. The HuggingFace `tokenizers` crate it wraps is Apache-2.0.

