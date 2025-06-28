#ifndef TOKENIZERS_FFI_H
#define TOKENIZERS_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Handle to the tokenizer object
typedef void *TokenizerHandle;

// Create a tokenizer from serialized JSON config
TokenizerHandle tokenizers_new_from_str(const char *json, size_t len);

// Encode text into token IDs
void tokenizers_encode(TokenizerHandle handle, const char *text, size_t len,
                       int add_special_tokens, uint32_t **out_ids,
                       size_t *out_len);

// Decode token IDs and store internally
void tokenizers_decode(TokenizerHandle handle, const uint32_t *ids, size_t len,
                       int skip_special_tokens);

// Retrieve decoded string from internal buffer (must free with
// tokenizers_free_cstring)
void tokenizers_get_decode_str(TokenizerHandle handle, char **out_ptr,
                               size_t *out_len);

// Decode token IDs and return string directly (must free with
// tokenizers_free_cstring)
void tokenizers_decode_and_get(TokenizerHandle handle, const uint32_t *ids,
                               size_t len, int skip_special_tokens,
                               const char **out_ptr, size_t *out_len);

// Free a tokenizer instance
void tokenizers_free(TokenizerHandle handle);

// Free string returned by tokenizers_get_decode_str or
// tokenizers_decode_and_get
void tokenizers_free_cstring(char *ptr);

// Free array of token IDs returned by tokenizers_encode
void tokenizers_free_ids(uint32_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif // TOKENIZERS_FFI_H
