unit module Tokenizers::Wrapper;

use NativeCall;

constant $os = $*KERNEL.name.lc;
constant $libname = $os ~~ /darwin/ ?? 'libtokenizers_ffi.dylib' !!
		    $os ~~ /win/    ?? 'libtokenizers_ffi.dll'   !!
				       'libtokenizers_ffi.so';

sub _libpath {
	%?RESOURCES{"lib/$libname"}.IO.Str;
}

class TokenizerHandle is repr('CPointer') is export {}

sub tokenizers_new_from_str(
	Pointer[uint8], 
	size_t --> TokenizerHandle
) is native(&_libpath) is export {}

sub tokenizers_encode(
	TokenizerHandle, 
	Pointer[uint8], 
	size_t, 
	int32,
	CArray[Pointer[uint32]], 
	CArray[size_t]
) is native(&_libpath) is export {}

sub tokenizers_decode(TokenizerHandle, Pointer[uint32], size_t, int32)
	is native(&_libpath) is export {}

sub tokenizers_get_decode_str(
	TokenizerHandle,
	CArray[Pointer[uint8]],
	CArray[size_t]
) is native(&_libpath) is export {}

sub tokenizers_decode_and_get(
	TokenizerHandle,
	Pointer[uint32], 
	size_t, 
	int32,
	CArray[Pointer[uint8]],
	CArray[size_t]
) is native(&_libpath) is export {}

sub tokenizers_free(TokenizerHandle) is native(&_libpath) is export {}

sub tokenizers_free_cstring(Pointer[uint8]) is native(&_libpath) is export {}

sub tokenizers_free_ids(Pointer[uint32], size_t) is native(&_libpath) is export {}

