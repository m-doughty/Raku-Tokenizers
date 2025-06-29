# Tokenizers

## DESCRIPTIONS

**Note: This module has some build issues before 0.1.3 due to my poor understanding of zef & Build.rakumod. It should work post 0.1.3 without issues.**

Tokenizers provides a high-level interface for interacting with Huggingface Tokenizers, based on my C ABI wrapper for it, [tokenizers-ffi](https://github.com/m-doughty/tokenizers-ffi).

You must have a C compiler, the Rust compiler, and GNU Make installed to use this module.

## SYNOPSIS

```raku
my $json-path = "t/fixtures/tokenizer.json";

my $json = slurp($json-path);
my $tokenizer = Tokenizers.new-from-json($json);

my $text = "Hello, world!";
my @tokens = $tokenizer.encode($text);
## [1, 22177, 1044, 4304, 1033]
my @tokens2 = $tokenizer.encode($text, :add-special-tokens(False));
## [22177, 1044, 4304, 1033] 

my $count = $tokenizer.count($text);
## 5
my $count2 = $tokenizer.count($text, :add-special-tokens(False));
## 4

my $decoded = $tokenizer.decode(@tokens);
## "<s>Hello, world!"
my $decoded2 = $tokenizer.decode(@tokens, :skip-special-tokens(True));
## "Hello, world!"
```

## LICENSE

Artistic License 2.0
(C) 2025 Matt Doughty `<matt@apogee.guru>`

The file at `t/fixtures/tokenizer.json` is (C) 2025 Mistral AI.

It is extracted from Mistral Nemo, which is an Apache 2.0 licensed model.
