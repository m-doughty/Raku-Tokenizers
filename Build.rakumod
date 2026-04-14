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
#| Binary artefacts are versioned independently of the Raku dist.
#| See BINARY_TAG file at repo root — bumped when the vendored
#| tokenizers-ffi version or build recipe changes.

class Build {

    # --- Constants ------------------------------------------------------

    constant $DEFAULT-BASE-URL =
        'https://github.com/m-doughty/Tokenizers-Raku/releases/download';

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

    #| Delegate to the vendored Makefile. `make` invokes
    #| `cargo build --release`; the Makefile picks the right file
    #| extension per platform. Kept as a make invocation (rather than
    #| inlining cargo here) so devs running `make` in libtokenizers-ffi
    #| standalone get byte-identical behaviour.
    method !compile-from-source($dist-path) {
        self!check-toolchain;

        my Str $vendor = "$dist-path/vendor/tokenizers-ffi";
        my $rc = run 'make', '-C', $vendor;
        die "❌ Failed to build tokenizers-ffi via make." unless $rc.exitcode == 0;

        my Str $os = $*KERNEL.name.lc;
        my Str $ext = $os ~~ /darwin/ ?? 'dylib'
                   !! $*DISTRO.is-win ?? 'dll'
                   !! 'so';

        "$dist-path/resources/lib".IO.mkdir;
        copy "$vendor/target/release/libtokenizers_ffi.$ext",
             "$dist-path/resources/lib/libtokenizers_ffi.$ext";
    }

    method !check-toolchain() {
        # Need cargo + make. `run` with no shell keeps error output
        # clean across platforms.
        for <cargo make> -> Str $bin {
            my $rc = run $bin, '--version', :out, :err;
            $rc.out.slurp(:close);
            $rc.err.slurp(:close);
            unless $rc.exitcode == 0 {
                die qq:to/ERR/;
                    ❌ Required tool '$bin' not found in PATH.
                    Install a Rust toolchain (cargo, rustc) and GNU make:
                        macOS:         brew install rust make
                        Debian/Ubuntu: sudo apt install cargo rustc make build-essential
                        Fedora:        sudo dnf install cargo rust make gcc
                        Arch:          sudo pacman -S rust make base-devel
                        openSUSE:      sudo zypper in cargo rust make gcc
                        Windows:       winget install Rustlang.Rustup + MSVC Build Tools
                    Or use rustup: https://rustup.rs
                    ERR
            }
        }
    }

    # --- Shared helpers -------------------------------------------------

    method !detect-platform(--> Str) {
        my Str $key = "{$*KERNEL.name.lc}-{$*KERNEL.hardware.lc}";
        %PLATFORM-SLUGS{$key};
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
