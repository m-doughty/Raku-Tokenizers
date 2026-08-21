#ifndef TOKENIZERS_FFI_H
#define TOKENIZERS_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *TokenizerHandle;

/* Constructors return NULL on failure. Retrieve details with
 * tokenizers_get_last_error on the same thread. */
TokenizerHandle tokenizers_new_from_str(const char *json, size_t len);

TokenizerHandle tokenizers_new_from_tiktoken(
    const uint8_t *model, size_t model_len, const uint8_t *pattern,
    size_t pattern_len, const uint8_t *const *special_token_ptrs,
    const size_t *special_token_lens, const uint32_t *special_token_ids,
    size_t special_token_count);

/* Operations return 0 on success and -1 on failure. No output allocation is
 * retained on failure. add_special_tokens applies only to tokenizer.json
 * backends; allow_special_tokens applies only to tiktoken backends. */
int tokenizers_encode(TokenizerHandle handle, const char *text, size_t len,
                      int add_special_tokens, int allow_special_tokens,
                      uint32_t **out_ids, size_t *out_len);

int tokenizers_decode(TokenizerHandle handle, const uint32_t *ids, size_t len,
                      int skip_special_tokens);

int tokenizers_get_decode_str(TokenizerHandle handle, uint8_t **out_ptr,
                              size_t *out_len);

int tokenizers_decode_and_get(TokenizerHandle handle, const uint32_t *ids,
                              size_t len, int skip_special_tokens,
                              uint8_t **out_ptr, size_t *out_len);

/* Returns a newly allocated UTF-8 copy of the calling thread's last error.
 * Free it with tokenizers_free_cstring. */
int tokenizers_get_last_error(uint8_t **out_ptr, size_t *out_len);

void tokenizers_free(TokenizerHandle handle);
void tokenizers_free_cstring(char *ptr);
void tokenizers_free_ids(uint32_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* TOKENIZERS_FFI_H */
