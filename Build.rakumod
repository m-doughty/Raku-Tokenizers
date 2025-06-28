class Build {
    method build($dist-path) {
        self!check-dependencies;

        say "🏗️  Building tokenizers-ffi C/Rust library via make";

        my $status = shell "cd vendor/tokenizers-ffi && make";
        die "❌ Failed to build tokenizers-ffi via make" if $status != 0;

        my $os = $*KERNEL.name.lc;

        my $lib-ext = $os ~~ /darwin/ ?? 'dylib'
            !! $os ~~ /win/           ?? 'dll'
            !! 'so';

        "$dist-path/resources/lib".IO.mkdir;
        "$dist-path/resources/include".IO.mkdir;

        copy "vendor/tokenizers-ffi/target/release/libtokenizers_ffi.$lib-ext",
             "$dist-path/resources/lib/libtokenizers_ffi.$lib-ext";

        copy "vendor/tokenizers-ffi/include/tokenizers_ffi.h",
             "$dist-path/resources/include/tokenizers_ffi.h";
    }

    method !check-dependencies {
        for <make cc cargo> -> $bin {
            shell "$bin --version > /dev/null 2>&1"
                or die "❌ Required tool '$bin' not found in PATH. Please install it.";
        }
    }
}

