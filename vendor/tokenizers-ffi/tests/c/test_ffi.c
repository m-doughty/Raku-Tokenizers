#include "../../include/tokenizers_ffi.h"
#include <check.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

char *read_file(const char *path, size_t *out_len) {
  FILE *fp = fopen(path, "rb");
  if (!fp)
    return NULL;

  fseek(fp, 0, SEEK_END);
  size_t len = ftell(fp);
  rewind(fp);

  char *buf = malloc(len);
  fread(buf, 1, len, fp);
  fclose(fp);

  *out_len = len;
  return buf;
}

START_TEST(test_tokenizer_new_from_str) {
  size_t json_len;
  char *json = read_file("tests/fixtures/tokenizer.json", &json_len);
  ck_assert_ptr_nonnull(json);

  TokenizerHandle handle = tokenizers_new_from_str(json, json_len);
  ck_assert_ptr_nonnull(handle);

  tokenizers_free(handle);
  free(json);
}
END_TEST

START_TEST(test_encode_decode_flow) {
  size_t json_len;
  char *json = read_file("tests/fixtures/tokenizer.json", &json_len);
  TokenizerHandle handle = tokenizers_new_from_str(json, json_len);
  ck_assert_ptr_nonnull(handle);

  const char *text = "Hello, world!";
  uint32_t *ids = NULL;
  size_t id_len = 0;

  tokenizers_encode(handle, text, strlen(text), 1, &ids, &id_len);
  ck_assert_ptr_nonnull(ids);
  ck_assert_int_eq(id_len, 5);

  tokenizers_decode(handle, ids, id_len, 1);

  char *decoded = NULL;
  size_t decoded_len = 0;
  tokenizers_get_decode_str(handle, &decoded, &decoded_len);

  ck_assert_ptr_nonnull(decoded);
  ck_assert_int_eq(decoded_len, 13);

  tokenizers_free_ids(ids, id_len);
  tokenizers_free_cstring(decoded);
  tokenizers_free(handle);
  free(json);
}
END_TEST

START_TEST(test_decode_and_get) {
  size_t json_len;
  char *json = read_file("tests/fixtures/tokenizer.json", &json_len);
  TokenizerHandle handle = tokenizers_new_from_str(json, json_len);
  ck_assert_ptr_nonnull(handle);

  const char *text = "Test decode_and_get";
  uint32_t *ids = NULL;
  size_t id_len = 0;

  tokenizers_encode(handle, text, strlen(text), 1, &ids, &id_len);
  ck_assert_ptr_nonnull(ids);

  const char *decoded = NULL;
  size_t decoded_len = 0;

  tokenizers_decode_and_get(handle, ids, id_len, 1, &decoded, &decoded_len);
  ck_assert_ptr_nonnull(decoded);
  ck_assert_int_eq(decoded_len, 19);

  tokenizers_free_ids(ids, id_len);
  tokenizers_free_cstring((char *)decoded);
  tokenizers_free(handle);
  free(json);
}
END_TEST

Suite *ffi_suite(void) {
  Suite *s = suite_create("Tokenizer FFI");
  TCase *tc = tcase_create("Core");

  tcase_add_test(tc, test_tokenizer_new_from_str);
  tcase_add_test(tc, test_encode_decode_flow);
  tcase_add_test(tc, test_decode_and_get);

  suite_add_tcase(s, tc);
  return s;
}

int main(void) {
  Suite *s = ffi_suite();
  SRunner *sr = srunner_create(s);

  srunner_run_all(sr, CK_NORMAL);
  int failed = srunner_ntests_failed(sr);
  srunner_free(sr);
  return failed == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
