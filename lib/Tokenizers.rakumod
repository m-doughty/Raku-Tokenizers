unit class Tokenizers;

use NativeCall;
use Tokenizers::Wrapper;

class X::Tokenizers is Exception {
	has Str $.operation is required;
	has Str $.detail is required;

	method message(--> Str) {
		"Tokenizers {$!operation} failed: {$!detail}";
	}
}

class X::Tokenizers::Create is X::Tokenizers { }
class X::Tokenizers::Encode is X::Tokenizers { }
class X::Tokenizers::Decode is X::Tokenizers { }

has Tokenizers::Wrapper::TokenizerHandle $.handle is required;

sub native-error(Str $fallback --> Str) {
	my $out-str = CArray[Pointer[uint8]].new;
	$out-str[0] = Pointer[uint8];
	my $out-len = CArray[size_t].new;
	$out-len[0] = 0;

	return $fallback unless tokenizers_get_last_error($out-str, $out-len) == 0;
	my Pointer[uint8] $raw = $out-str[0];
	my size_t $length = $out-len[0];
	return $fallback unless $raw.defined;

	LEAVE tokenizers_free_cstring($raw);
	my $message = Buf.new($raw[^$length]).decode("utf8");
	$message.chars ?? $message !! $fallback;
}

sub as-utf8-bytes($value, Str $name --> Blob) {
	given $value {
		when Str { .encode("utf8") }
		when Blob { $_ }
		default {
			die X::Tokenizers::Create.new(
				operation => "construction",
				detail => "$name must be a Str or Blob, got {$value.^name}",
			);
		}
	}
}

method new-from-json($json --> Tokenizers) {
	my Blob $buf = as-utf8-bytes($json, "tokenizer JSON");
	my $handle = tokenizers_new_from_str(
		nativecast(Pointer[uint8], $buf),
		$buf.bytes,
	);
	unless $handle.defined {
		die X::Tokenizers::Create.new(
			operation => "JSON construction",
			detail => native-error("native tokenizer returned a null handle"),
		);
	}

	self.new(:$handle);
}

#| Build a tokenizer from the raw contents of a tiktoken.model file.
#| `pattern` is the model's split regex and `special-tokens` maps each exact
#| special-token string to its uint32 token ID.
method new-from-tiktoken(
	$model,
	Str:D :$pattern!,
	:%special-tokens! --> Tokenizers
) {
	my Blob $model-buf = as-utf8-bytes($model, "tiktoken model");
	my Blob $pattern-buf = $pattern.encode("utf8");
	my @entries = %special-tokens.pairs.sort(*.key.Str);
	my @token-bufs;
	my $token-pointers = CArray[Pointer[uint8]].new;
	my $token-lengths = CArray[size_t].new;
	my $token-ids = CArray[uint32].new;

	for @entries.kv -> $index, $entry {
		my Str $token = $entry.key.Str;
		my $id = $entry.value;
		unless $id ~~ Int:D && 0 <= $id <= 0xffff_ffff {
			die X::Tokenizers::Create.new(
				operation => "tiktoken construction",
				detail => "special token {$token.raku} has an ID outside uint32: {$id.raku}",
			);
		}
		my Blob $token-buf = $token.encode("utf8");
		@token-bufs.push($token-buf); # keep backing storage alive through the call
		$token-pointers[$index] = nativecast(Pointer[uint8], $token-buf);
		$token-lengths[$index] = $token-buf.bytes;
		$token-ids[$index] = $id;
	}

	my $handle = tokenizers_new_from_tiktoken(
		nativecast(Pointer[uint8], $model-buf),
		$model-buf.bytes,
		nativecast(Pointer[uint8], $pattern-buf),
		$pattern-buf.bytes,
		$token-pointers,
		$token-lengths,
		$token-ids,
		@entries.elems,
	);
	unless $handle.defined {
		die X::Tokenizers::Create.new(
			operation => "tiktoken construction",
			detail => native-error("native tokenizer returned a null handle"),
		);
	}

	self.new(:$handle);
}

method encode(
	Str:D $text,
	Bool:D :$add-special-tokens = True,
	Bool:D :$allow-special-tokens = False --> List
) {
	my Blob $buf = $text.encode("utf8");
	my $out-ids = CArray[Pointer[uint32]].new;
	$out-ids[0] = Pointer[uint32];
	my $out-len = CArray[size_t].new;
	$out-len[0] = 0;

	my $status = tokenizers_encode(
		$!handle,
		nativecast(Pointer[uint8], $buf),
		$buf.bytes,
		$add-special-tokens ?? 1 !! 0,
		$allow-special-tokens ?? 1 !! 0,
		$out-ids,
		$out-len,
	);
	if $status != 0 {
		die X::Tokenizers::Encode.new(
			operation => "encode",
			detail => native-error("native encode returned status $status"),
		);
	}

	my Pointer[uint32] $ids-raw = $out-ids[0];
	my size_t $count = $out-len[0];
	LEAVE tokenizers_free_ids($ids-raw, $count) if $ids-raw.defined;
	return () unless $count;
	$ids-raw[^$count].List;
}

method decode($ids, Bool:D :$skip-special-tokens = False --> Str) {
	my @ints = $ids.List.map({
		my $id = $_;
		unless $id ~~ Int:D && 0 <= $id <= 0xffff_ffff {
			die X::Tokenizers::Decode.new(
				operation => "decode",
				detail => "token ID is outside uint32: {$id.raku}",
			);
		}
		$id.Int;
	});

	my $buf = CArray[uint32].new;
	$buf[@ints.keys] = @ints if @ints;
	my $out-str = CArray[Pointer[uint8]].new;
	$out-str[0] = Pointer[uint8];
	my $out-len = CArray[size_t].new;
	$out-len[0] = 0;

	my $status = tokenizers_decode_and_get(
		$!handle,
		@ints ?? nativecast(Pointer[uint32], $buf) !! Pointer[uint32],
		@ints.elems,
		$skip-special-tokens ?? 1 !! 0,
		$out-str,
		$out-len,
	);
	if $status != 0 {
		die X::Tokenizers::Decode.new(
			operation => "decode",
			detail => native-error("native decode returned status $status"),
		);
	}

	my Pointer[uint8] $raw = $out-str[0];
	my size_t $length = $out-len[0];
	LEAVE tokenizers_free_cstring($raw) if $raw.defined;
	return "" unless $length;
	Buf.new($raw[^$length]).decode("utf8");
}

method count(
	Str:D $text,
	Bool:D :$add-special-tokens = True,
	Bool:D :$allow-special-tokens = False --> Int
) {
	self.encode(
		$text,
		:$add-special-tokens,
		:$allow-special-tokens,
	).elems;
}

method DESTROY {
	tokenizers_free($!handle) if $!handle.defined;
}
