#| Build.rakumod for Tokenizers.
#|
#| Two paths, tried in order:
#|
#|   1. Prebuilt binary download from GitHub Releases for the detected
#|      (OS, arch) pair. Universal-on-macOS (arm64+x86_64 slices),
#|      statically-linked Rust deps elsewhere. ~2–15 seconds on a
#|      decent connection (bigger dylib than CRoaring because the
#|      HuggingFace tokenizers crate is hefty).
#|
#|   2. Fallback: compile via the vendored Makefile which shells to
#|      `cargo build --release`. Needs rustc + cargo (1.70+ ideally)
#|      and a C toolchain for the build.rs shims. Takes 5–10 minutes
#|      from cold on a clean cargo cache.
#|
#| Env-var knobs:
#|
#|   TOKENIZERS_BUILD_FROM_SOURCE=1   skip prebuilt path, always compile
#|   TOKENIZERS_BINARY_ONLY=1         refuse to fall back to compile
#|   TOKENIZERS_BINARY_URL=<url>      override GH release base URL
#|                                    (mirrors, air-gapped repos)
#|   TOKENIZERS_CACHE_DIR=<path>      override cache directory
#|                                    (default $XDG_CACHE_HOME / ~/.cache)
#|
#| Linux prebuilts are built on ubuntu-22.04 (glibc 2.35 — see the
#| $MIN-GLIBC constant). On systems with older glibc (Ubuntu 20.04 /
#| Debian 11 / RHEL 8 / etc.) the prebuilt loads but dies at first
#| symbol use with "GLIBC_2.xx not found". Build detects this via
#| `ldd --version` and short-circuits to the cargo source build
#| before the download even happens.
#|
#| Binary artefacts are versioned independently of the Raku dist.
#| See BINARY_TAG file at repo root — bumped when the vendored
#| tokenizers-ffi version or build recipe changes.

class Build {

    # --- Constants ------------------------------------------------------

    constant $DEFAULT-BASE-URL =
        'https://github.com/m-doughty/Raku-Tokenizers/releases/download';

    # Minimum glibc the prebuilt Linux archives are compatible with.
    # The CI workflow builds on ubuntu-22.04 (glibc 2.35); the Rust
    # cdylib references GLIBC_2.3x versioned symbols so loading on
    # older systems fails at first symbol use with "GLIBC_2.xx not
    # found". Bump in lockstep with the CI runner OS.
    constant $MIN-GLIBC = v2.35;

    my %PLATFORM-SLUGS =
        'darwin-arm64'    => 'macos-universal',
        'darwin-x86_64'   => 'macos-universal',
        'linux-x86_64'    => 'linux-x86_64-glibc',
        'linux-aarch64'   => 'linux-aarch64-glibc',
        'win32-x86_64'    => 'windows-x86_64',
        'win32-aarch64'   => 'windows-arm64',
        'mswin32-x86_64'  => 'windows-x86_64',
        'mswin32-aarch64' => 'windows-arm64',
    ;

    # --- Entry point ----------------------------------------------------

    method build($dist-path) {
        my Bool $force-source = ?%*ENV<TOKENIZERS_BUILD_FROM_SOURCE>;
        my Bool $binary-only  = ?%*ENV<TOKENIZERS_BINARY_ONLY>;

        my Str $binary-tag = self!binary-tag($dist-path);
        my Str $plat = self!detect-platform;

        without $plat {
            note "⚠️  Unknown platform ({$*KERNEL.name}-{$*KERNEL.hardware}); "
                ~ "falling back to source build.";
            self!compile-from-source($dist-path);
            self!stage-header($dist-path);
            self!stage-stubs($dist-path);
            return True;
        }

        # Guard: prebuilt Linux archives are built on ubuntu-22.04
        # (glibc $MIN-GLIBC). On older glibc the downloaded .so loads
        # but dies at first symbol use with "GLIBC_2.xx not found".
        # Detect here and fall back to cargo source build before the
        # download even happens.
        if !$force-source && $plat.ends-with('-glibc') {
            my Version $have = self!detect-glibc-version;
            if $have.defined && $have cmp $MIN-GLIBC == Less {
                if $binary-only {
                    die "TOKENIZERS_BINARY_ONLY=1 set but system glibc "
                      ~ "$have is older than prebuilt target $MIN-GLIBC "
                      ~ "($plat / $binary-tag).";
                }
                note "⚠️  System glibc $have is older than prebuilt "
                   ~ "target $MIN-GLIBC — falling back to source build "
                   ~ "to avoid runtime loader errors (this can take ~5 min).";
                self!compile-from-source($dist-path);
                self!stage-header($dist-path);
                self!stage-stubs($dist-path);
                say "✅ Compiled Tokenizers from vendored source.";
                return True;
            }
        }

        unless $force-source {
            if self!try-prebuilt($dist-path, $plat, $binary-tag) {
                self!stage-header($dist-path);
                self!stage-stubs($dist-path);
                say "✅ Installed prebuilt Tokenizers binary ($plat) for $binary-tag.";
                return True;
            }
            if $binary-only {
                die "TOKENIZERS_BINARY_ONLY=1 set but prebuilt download "
                  ~ "failed for $plat ($binary-tag).";
            }
            note "⚠️  Prebuilt binary unavailable for $plat ($binary-tag) "
               ~ "— compiling from source (this can take ~5 min).";
        }

        self!compile-from-source($dist-path);
        self!stage-header($dist-path);
        self!stage-stubs($dist-path);
        say "✅ Compiled Tokenizers from vendored source.";
        True;
    }

    # --- Prebuilt binary path -------------------------------------------

    method !try-prebuilt($dist-path, Str $plat, Str $binary-tag --> Bool) {
        my Str $artifact = self!artifact-name($plat);
        my IO::Path $cache-dir = self!cache-dir($binary-tag);
        my IO::Path $cached = $cache-dir.add($artifact);
        my Str $base-url = %*ENV<TOKENIZERS_BINARY_URL> // $DEFAULT-BASE-URL;
        my Str $url = "$base-url/$binary-tag/$artifact";

        unless $cached.e {
            $cache-dir.mkdir;
            say "⬇️  Fetching $artifact from $url";
            # `run` with arg list avoids shell quoting entirely — in
            # particular Windows cmd.exe treating single quotes as
            # literal, which mangles the URL and the drive-lettered
            # output path.
            my $rc = run 'curl', '-fL', '--progress-bar',
                         '-o', $cached.Str, $url;
            unless $rc.exitcode == 0 {
                $cached.unlink if $cached.e;
                return False;
            }
        }

        my Str $expected = self!expected-sha($dist-path, $artifact);
        without $expected {
            note "No checksum recorded for $artifact in resources/checksums.txt "
                ~ "— refusing prebuilt (bundled checksums are a hard security boundary).";
            return False;
        }

        my Str $actual = self!sha256($cached);
        unless $actual.defined && $actual.lc eq $expected.lc {
            note "Checksum mismatch for $artifact "
                ~ "(expected $expected, got {$actual // 'unknown'}).";
            $cached.unlink;
            return False;
        }

        self!install-artefact($cached, $dist-path, $plat);
        True;
    }

    method !artifact-name(Str $plat --> Str) {
        my Str $ext = $plat.starts-with('windows') ?? 'dll'
                    !! $plat.starts-with('macos')  ?? 'dylib'
                    !! 'so';
        "libtokenizers_ffi-$plat.$ext";
    }

    method !install-artefact(IO::Path $src, $dist-path, Str $plat) {
        my IO::Path $dest-dir = "$dist-path/resources/lib".IO;
        $dest-dir.mkdir;

        my Str $ext = $plat.starts-with('windows') ?? 'dll'
                    !! $plat.starts-with('macos')  ?? 'dylib'
                    !! 'so';
        my IO::Path $dest = $dest-dir.add("libtokenizers_ffi.$ext");
        copy $src, $dest;
    }

    method !cache-dir(Str $binary-tag --> IO::Path) {
        my Str $base = %*ENV<TOKENIZERS_CACHE_DIR>
            // %*ENV<XDG_CACHE_HOME>
            // "{%*ENV<HOME> // '.'}/.cache";
        "$base/Tokenizers-binaries/$binary-tag".IO;
    }

    method !binary-tag($dist-path --> Str) {
        my IO::Path $file = "$dist-path/BINARY_TAG".IO;
        unless $file.e {
            die "❌ Missing BINARY_TAG file at { $file }. This file must "
              ~ "contain the pinned binary release tag "
              ~ "(e.g. 'binaries-tokenizers-0.1.0-r1').";
        }
        my Str $tag = $file.slurp.trim;
        die "❌ BINARY_TAG file is empty." unless $tag.chars;
        $tag;
    }

    method !expected-sha($dist-path, Str $artifact --> Str) {
        my IO::Path $file = "$dist-path/resources/checksums.txt".IO;
        return Str unless $file.e;
        for $file.slurp.lines -> Str $line {
            my Str $trimmed = $line.trim;
            next if $trimmed eq '' || $trimmed.starts-with('#');
            my @parts = $trimmed.words;
            next unless @parts.elems >= 2;
            return @parts[0] if @parts[1] eq $artifact;
        }
        Str;
    }

    method !sha256(IO::Path $file --> Str) {
        if $*DISTRO.is-win {
            my $proc = run 'certutil', '-hashfile', $file.Str, 'SHA256',
                           :out, :err;
            my $out = $proc.out.slurp(:close);
            $proc.err.slurp(:close);
            for $out.lines -> Str $line {
                my Str $t = $line.subst(/\s+/, '', :g).lc;
                return $t if $t.chars == 64 && $t ~~ /^ <[0..9a..f]>+ $/;
            }
            return Str;
        }
        my $proc = run 'shasum', '-a', '256', $file.Str, :out, :err;
        my $out = $proc.out.slurp(:close);
        $proc.err.slurp(:close);
        $out.words.head;
    }

    # --- Source compile path --------------------------------------------

    #| Invoke cargo directly for the source-compile fallback. We
    #| deliberately don't go through the vendored Makefile here:
    #| Rust/MSVC cdylibs on Windows are named `tokenizers_ffi.dll`
    #| without the `lib` prefix that Unix cdylibs get, and the
    #| Makefile's $(DYLIB) variable hard-codes the prefixed name.
    #| Calling cargo directly keeps the fallback behaviour
    #| consistent across platforms and insulates us from Makefile
    #| drift. Devs hacking on libtokenizers-ffi standalone still use
    #| `make` for tests + sanitizers; that path isn't affected.
    method !compile-from-source($dist-path) {
        self!check-toolchain;

        my Str $vendor = "$dist-path/vendor/tokenizers-ffi";
        my $rc = run 'cargo', 'build', '--release',
                     '--manifest-path', "$vendor/Cargo.toml";
        die "❌ Failed to build tokenizers-ffi via cargo."
            unless $rc.exitcode == 0;

        my Str $os = $*KERNEL.name.lc;
        my Str $ext = $os ~~ /darwin/ ?? 'dylib'
                   !! $*DISTRO.is-win ?? 'dll'
                   !! 'so';

        # On Windows MSVC, cargo produces `tokenizers_ffi.dll`
        # (no `lib` prefix — Windows DLL convention). Elsewhere the
        # prefix is present. We ship with the prefix uniformly
        # inside resources/lib/ because Tokenizers::Wrapper's FFI
        # lookup expects that name on every platform.
        my Str $src-name = $*DISTRO.is-win
            ?? "tokenizers_ffi.$ext"
            !! "libtokenizers_ffi.$ext";

        "$dist-path/resources/lib".IO.mkdir;
        copy "$vendor/target/release/$src-name",
             "$dist-path/resources/lib/libtokenizers_ffi.$ext";
    }

    method !check-toolchain() {
        # Just cargo — we drive cargo directly rather than via make,
        # so make isn't required for the fallback compile.
        my $rc = run 'cargo', '--version', :out, :err;
        $rc.out.slurp(:close);
        $rc.err.slurp(:close);
        unless $rc.exitcode == 0 {
            die qq:to/ERR/;
                ❌ cargo not found in PATH.
                Install a Rust toolchain:
                    macOS:         brew install rust
                    Debian/Ubuntu: sudo apt install cargo rustc
                    Fedora:        sudo dnf install cargo rust
                    Arch:          sudo pacman -S rust
                    openSUSE:      sudo zypper in cargo rust
                    Windows:       winget install Rustlang.Rustup
                Or use rustup: https://rustup.rs
                ERR
        }
    }

    # --- Shared helpers -------------------------------------------------

    method !detect-platform(--> Str) {
        my Str $key = "{$*KERNEL.name.lc}-{$*KERNEL.hardware.lc}";
        %PLATFORM-SLUGS{$key};
    }

    #| Parse `ldd --version` for the system's glibc version. Returns a
    #| Version on glibc systems, undefined Version on musl (ldd --version
    #| exits non-zero) or when ldd is absent / unparseable. Only
    #| meaningful on Linux — don't call on other OSes.
    method !detect-glibc-version(--> Version) {
        my $proc = try { run 'ldd', '--version', :out, :err };
        return Version without $proc;
        my $out = $proc.out.slurp(:close);
        $proc.err.slurp(:close);
        return Version unless $proc.exitcode == 0;
        my $first = $out.lines.head // '';
        if $first ~~ / (\d+ '.' \d+ [ '.' \d+ ]?) \s* $ / {
            return Version.new(~$0);
        }
        Version;
    }

    #| The C header is vendored in-tree and doesn't depend on platform.
    #| Always copy it into resources/include whether we downloaded or
    #| compiled — it's a small text file useful for C consumers that
    #| want to link against the same tokenizers-ffi contract.
    method !stage-header($dist-path) {
        "$dist-path/resources/include".IO.mkdir;
        copy "$dist-path/vendor/tokenizers-ffi/include/tokenizers_ffi.h",
             "$dist-path/resources/include/tokenizers_ffi.h";
    }

    #| Empty placeholders for non-target platforms so META6.json's
    #| resources list stays satisfiable regardless of which host we
    #| built on.
    method !stage-stubs($dist-path) {
        for <libtokenizers_ffi.dylib libtokenizers_ffi.so libtokenizers_ffi.dll> -> Str $name {
            my Str $path = "$dist-path/resources/lib/$name";
            $path.IO.spurt('') unless $path.IO.f;
        }
    }
}
