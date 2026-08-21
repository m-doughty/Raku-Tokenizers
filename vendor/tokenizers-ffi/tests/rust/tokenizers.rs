use base64::{engine::general_purpose, Engine as _};
use std::ffi::c_char;
use std::fs;
use std::path::Path;
use std::ptr;
use std::thread;

use tokenizers_ffi::*;

fn load_tokenizer_json() -> String {
    fs::read_to_string(Path::new("tests/fixtures/tokenizer.json"))
        .expect("failed to read tokenizer.json")
}

fn byte_model() -> String {
    (0_u8..=u8::MAX)
        .map(|byte| format!("{} {}", general_purpose::STANDARD.encode([byte]), byte))
        .collect::<Vec<_>>()
        .join("\n")
}

unsafe fn encode(
    handle: *mut TokenizerWrapper,
    text: &str,
    add_special: bool,
    allow_special: bool,
) -> Vec<u32> {
    let mut pointer = ptr::null_mut();
    let mut length = 0;
    assert_eq!(
        tokenizers_encode(
            handle,
            text.as_ptr().cast(),
            text.len(),
            i32::from(add_special),
            i32::from(allow_special),
            &mut pointer,
            &mut length,
        ),
        0
    );
    let result = if length == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(pointer, length).to_vec() }
    };
    tokenizers_free_ids(pointer, length);
    result
}

unsafe fn decode(handle: *mut TokenizerWrapper, ids: &[u32], skip_special: bool) -> String {
    let mut pointer = ptr::null_mut();
    let mut length = 0;
    assert_eq!(
        tokenizers_decode_and_get(
            handle,
            ids.as_ptr(),
            ids.len(),
            i32::from(skip_special),
            &mut pointer,
            &mut length,
        ),
        0
    );
    let result = String::from_utf8(unsafe {
        std::slice::from_raw_parts(pointer.cast::<u8>(), length).to_vec()
    })
    .unwrap();
    tokenizers_free_cstring(pointer.cast::<c_char>());
    result
}

unsafe fn tiktoken(special: &[(&str, u32)]) -> *mut TokenizerWrapper {
    let model = byte_model();
    let pattern = r"(?s).";
    let token_pointers = special
        .iter()
        .map(|(token, _)| token.as_ptr())
        .collect::<Vec<_>>();
    let token_lengths = special
        .iter()
        .map(|(token, _)| token.len())
        .collect::<Vec<_>>();
    let token_ids = special.iter().map(|(_, id)| *id).collect::<Vec<_>>();
    tokenizers_new_from_tiktoken(
        model.as_ptr(),
        model.len(),
        pattern.as_ptr(),
        pattern.len(),
        token_pointers.as_ptr(),
        token_lengths.as_ptr(),
        token_ids.as_ptr(),
        special.len(),
    )
}

#[test]
fn huggingface_json_round_trip_remains_compatible() {
    let json = load_tokenizer_json();
    let handle = unsafe { tokenizers_new_from_str(json.as_ptr().cast(), json.len()) };
    assert!(!handle.is_null());
    let ids = unsafe { encode(handle, "Hello, world!", true, true) };
    assert_eq!(ids.len(), 5);
    assert_eq!(unsafe { decode(handle, &ids, true) }, "Hello, world!");
    unsafe { tokenizers_free(handle) };
}

#[test]
fn malformed_json_returns_error_instead_of_panicking() {
    let handle = unsafe { tokenizers_new_from_str(b"{".as_ptr().cast(), 1) };
    assert!(handle.is_null());
    let mut pointer = ptr::null_mut();
    let mut length = 0;
    assert_eq!(
        unsafe { tokenizers_get_last_error(&mut pointer, &mut length) },
        0
    );
    let error = String::from_utf8(unsafe {
        std::slice::from_raw_parts(pointer.cast::<u8>(), length).to_vec()
    })
    .unwrap();
    unsafe { tokenizers_free_cstring(pointer.cast()) };
    assert!(error.contains("could not parse tokenizer JSON"));
}

#[test]
fn tiktoken_handles_unicode_code_and_special_token_policy() {
    let handle = unsafe { tiktoken(&[("<|im_start|>", 300), ("<|im_end|>", 301)]) };
    assert!(!handle.is_null());
    let text = "<|im_start|>助手\n你好 👩🏽‍💻\n```raku\nsay 42;\n```<|im_end|>";

    let ordinary = unsafe { encode(handle, text, false, false) };
    assert!(!ordinary.contains(&300));
    assert!(!ordinary.contains(&301));
    assert_eq!(unsafe { decode(handle, &ordinary, false) }, text);

    let allowed = unsafe { encode(handle, text, true, true) };
    assert_eq!(allowed.iter().filter(|id| **id == 300).count(), 1);
    assert_eq!(allowed.iter().filter(|id| **id == 301).count(), 1);
    assert_eq!(unsafe { decode(handle, &allowed, false) }, text);
    assert!(!unsafe { decode(handle, &allowed, true) }.contains("<|im_"));
    unsafe { tokenizers_free(handle) };
}

#[test]
fn tiktoken_handle_supports_concurrent_encoding() {
    let handle = unsafe { tiktoken(&[("<|special|>", 300)]) };
    assert!(!handle.is_null());
    let address = handle as usize;
    let threads = (0..16)
        .map(|index| {
            thread::spawn(move || {
                let handle = address as *mut TokenizerWrapper;
                let text = format!("并发 {index} 🦀 <|special|>");
                let ids = unsafe { encode(handle, &text, false, true) };
                assert!(ids.contains(&300));
                assert_eq!(unsafe { decode(handle, &ids, false) }, text);
            })
        })
        .collect::<Vec<_>>();
    for thread in threads {
        thread.join().unwrap();
    }
    unsafe { tokenizers_free(handle) };
}
