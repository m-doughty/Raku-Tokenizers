unit module Tokenizers::Wrapper;

use NativeCall;

constant $os = $*KERNEL.name.lc;
constant $libname = $os ~~ /darwin/ ?? 'libtokenizers_ffi.dylib' !!
		    $os ~~ /win/    ?? 'libtokenizers_ffi.dll'   !!
				       'libtokenizers_ffi.so';

#| Resolve the tokenizers-ffi native library path. Precedence:
#|
#|     1. $TOKENIZERS_LIB — explicit override; full path to a
#|        .dylib / .so / .dll. Undocumented escape hatch for custom
#|        tokenizers-ffi builds; you take responsibility for ABI.
#|     2. %?RESOURCES — staged at install time by Build.rakumod,
#|        either from a prebuilt GitHub release or a local cargo
#|        compile. This is the normal path.
sub _libpath {
	with %*ENV<TOKENIZERS_LIB> -> $override {
		return $override if $override.chars && $override.IO.e;
	}
	%?RESOURCES{"lib/$libname"}.IO.Str;
}

class TokenizerHandle is repr('CPointer') is export {}

sub tokenizers_new_from_str(
	Pointer[uint8], 
	size_t --> TokenizerHandle
) is native(&_libpath) is export {}

sub tokenizers_new_from_tiktoken(
	Pointer[uint8],
	size_t,
	Pointer[uint8],
	size_t,
	CArray[Pointer[uint8]],
	CArray[size_t],
	CArray[uint32],
	size_t --> TokenizerHandle
) is native(&_libpath) is export {}

sub tokenizers_encode(
	TokenizerHandle, 
	Pointer[uint8], 
	size_t, 
	int32,
	int32,
	CArray[Pointer[uint32]], 
	CArray[size_t] --> int32
) is native(&_libpath) is export {}

sub tokenizers_decode(TokenizerHandle, Pointer[uint32], size_t, int32 --> int32)
	is native(&_libpath) is export {}

sub tokenizers_get_decode_str(
	TokenizerHandle,
	CArray[Pointer[uint8]],
	CArray[size_t] --> int32
) is native(&_libpath) is export {}

sub tokenizers_decode_and_get(
	TokenizerHandle,
	Pointer[uint32], 
	size_t, 
	int32,
	CArray[Pointer[uint8]],
	CArray[size_t] --> int32
) is native(&_libpath) is export {}

sub tokenizers_get_last_error(
	CArray[Pointer[uint8]],
	CArray[size_t] --> int32
) is native(&_libpath) is export {}

sub tokenizers_free(TokenizerHandle) is native(&_libpath) is export {}

sub tokenizers_free_cstring(Pointer[uint8]) is native(&_libpath) is export {}

sub tokenizers_free_ids(Pointer[uint32], size_t) is native(&_libpath) is export {}
