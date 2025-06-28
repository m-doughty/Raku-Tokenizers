unit class Tokenizers;

use Tokenizers::Wrapper;
use NativeCall;

has Tokenizers::Wrapper::TokenizerHandle $.handle is required;

method new-from-json($json) {
	my $buf = Buf.new($json.encode('utf8'));
	my $ptr = nativecast(Pointer[uint8], $buf);
	my $handle = tokenizers_new_from_str($ptr, $buf.bytes);
	die "❌ Failed to create tokenizer" unless $handle.defined;

	self.new(:$handle);
}

method encode($text, :$add-special-tokens = True --> List) {
	my $buf = $text.encode('utf8');
	my $ptr = nativecast(Pointer[uint8], $buf);

	my $out-ids = CArray[Pointer[uint32]].new;
	$out-ids[0] = Pointer[uint32];
	my $out-len = CArray[size_t].new;
	$out-len[0] = 0;

	tokenizers_encode(
		$!handle,
		$ptr,
		$buf.bytes,
		$add-special-tokens ?? 1 !! 0,
		$out-ids,
		$out-len,
	);

	my Pointer[uint32] $ids-raw = $out-ids[0];
	my size_t $count            = $out-len[0];

	my @ids = $ids-raw[^$count];

	tokenizers_free_ids($ids-raw, $count) if $ids-raw.defined;

	return @ids;
}

method decode($ids, :$skip-special-tokens = False --> Str) {
	my @ints = $ids.List.map(*.Int);  # accepts anything List-ish

	my $len = @ints.elems;
	my $buf = CArray[uint32].new;
	$buf[@ints.keys] = @ints;

	my $out-str = CArray[Pointer[uint8]].new;
	$out-str[0] = Pointer[uint8];
	my $out-len = CArray[size_t].new;
	$out-len[0] = 0;

	tokenizers_decode_and_get(
		$!handle,
		nativecast(Pointer[uint32], $buf),
		$len,
		$skip-special-tokens ?? 1 !! 0,
		$out-str,
		$out-len,
	);

	my $raw    = $out-str[0];
	my $strlen = $out-len[0];

	my $str = Buf.new($raw[^$strlen]).decode('utf8');

	tokenizers_free_cstring($raw) if $raw.defined;

	return $str;
}

method count(Str $text, :$add-special-tokens = True --> Int) {
	self.encode($text, :$add-special-tokens).elems;
}

method DESTROY {
	tokenizers_free($!handle) if $!handle.defined;
}

