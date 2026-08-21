#![allow(clippy::missing_safety_doc)]

use base64::{engine::general_purpose, Engine as _};
use rustc_hash::FxHashMap;
use std::cell::RefCell;
use std::ffi::c_char;
use std::os::raw::c_int;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;
use std::str::FromStr;
use std::sync::Mutex;
use tiktoken_rs::CoreBPE;
use tokenizers::Tokenizer;

const STATUS_OK: c_int = 0;
const STATUS_ERROR: c_int = -1;

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

enum Backend {
    HuggingFace(Box<Tokenizer>),
    Tiktoken {
        bpe: Box<CoreBPE>,
        special_ids: Vec<u32>,
    },
}

pub struct TokenizerWrapper {
    backend: Backend,
    // Retains the legacy two-call decode API without making the whole handle
    // mutable. Each operation remains safe when a handle is shared by threads.
    decode_bytes: Mutex<Vec<u8>>,
}

impl TokenizerWrapper {
    fn encode(
        &self,
        text: &str,
        add_special_tokens: bool,
        allow_special_tokens: bool,
    ) -> Result<Vec<u32>, String> {
        match &self.backend {
            Backend::HuggingFace(tokenizer) => tokenizer
                .encode(text, add_special_tokens)
                .map(|encoding| encoding.get_ids().to_vec())
                .map_err(|error| format!("could not encode text: {error}")),
            Backend::Tiktoken { bpe, .. } => {
                if allow_special_tokens {
                    let allowed = bpe.special_tokens();
                    bpe.encode(text, &allowed)
                        .map(|(tokens, _)| tokens)
                        .map_err(|error| format!("could not encode text: {error}"))
                } else {
                    Ok(bpe.encode_ordinary(text))
                }
            }
        }
    }

    fn decode(&self, ids: &[u32], skip_special_tokens: bool) -> Result<Vec<u8>, String> {
        match &self.backend {
            Backend::HuggingFace(tokenizer) => tokenizer
                .decode(ids, skip_special_tokens)
                .map(String::into_bytes)
                .map_err(|error| format!("could not decode token IDs: {error}")),
            Backend::Tiktoken { bpe, special_ids } => {
                let filtered;
                let ids = if skip_special_tokens {
                    filtered = ids
                        .iter()
                        .copied()
                        .filter(|id| !special_ids.contains(id))
                        .collect::<Vec<_>>();
                    filtered.as_slice()
                } else {
                    ids
                };
                bpe.decode(ids)
                    .map(String::into_bytes)
                    .map_err(|error| format!("could not decode token IDs: {error}"))
            }
        }
    }
}

fn clear_error() {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = None);
}

fn set_error(message: impl Into<String>) {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = Some(message.into()));
}

fn panic_message(payload: Box<dyn std::any::Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_owned()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "unknown Rust panic".to_owned()
    }
}

fn run_status<F>(operation: F) -> c_int
where
    F: FnOnce() -> Result<(), String>,
{
    clear_error();
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(message)) => {
            set_error(message);
            STATUS_ERROR
        }
        Err(payload) => {
            set_error(format!(
                "native tokenizer panicked: {}",
                panic_message(payload)
            ));
            STATUS_ERROR
        }
    }
}

fn run_constructor<F>(operation: F) -> *mut TokenizerWrapper
where
    F: FnOnce() -> Result<TokenizerWrapper, String>,
{
    clear_error();
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(wrapper)) => Box::into_raw(Box::new(wrapper)),
        Ok(Err(message)) => {
            set_error(message);
            ptr::null_mut()
        }
        Err(payload) => {
            set_error(format!(
                "native tokenizer panicked: {}",
                panic_message(payload)
            ));
            ptr::null_mut()
        }
    }
}

unsafe fn input_bytes<'a>(
    pointer: *const u8,
    length: usize,
    name: &str,
) -> Result<&'a [u8], String> {
    if pointer.is_null() {
        return if length == 0 {
            Ok(&[])
        } else {
            Err(format!("{name} pointer is null but length is {length}"))
        };
    }
    Ok(unsafe { slice::from_raw_parts(pointer, length) })
}

unsafe fn input_utf8<'a>(pointer: *const u8, length: usize, name: &str) -> Result<&'a str, String> {
    let bytes = unsafe { input_bytes(pointer, length, name)? };
    std::str::from_utf8(bytes).map_err(|error| format!("{name} is not valid UTF-8: {error}"))
}

unsafe fn wrapper_ref<'a>(handle: *mut TokenizerWrapper) -> Result<&'a TokenizerWrapper, String> {
    if handle.is_null() {
        Err("tokenizer handle is null".to_owned())
    } else {
        Ok(unsafe { &*handle })
    }
}

unsafe fn write_bytes(
    bytes: &[u8],
    out_pointer: *mut *mut u8,
    out_length: *mut usize,
) -> Result<(), String> {
    if out_pointer.is_null() || out_length.is_null() {
        return Err("output pointer or output length is null".to_owned());
    }

    unsafe {
        *out_pointer = ptr::null_mut();
        *out_length = 0;
    }
    let allocation_length = bytes
        .len()
        .checked_add(1)
        .ok_or_else(|| "decoded output is too large".to_owned())?;
    let allocation = unsafe { libc::malloc(allocation_length) as *mut u8 };
    if allocation.is_null() {
        return Err(format!(
            "could not allocate {allocation_length} bytes for decoded output"
        ));
    }
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), allocation, bytes.len());
        *allocation.add(bytes.len()) = 0;
        *out_pointer = allocation;
        *out_length = bytes.len();
    }
    Ok(())
}

unsafe fn write_ids(
    ids: &[u32],
    out_pointer: *mut *mut u32,
    out_length: *mut usize,
) -> Result<(), String> {
    if out_pointer.is_null() || out_length.is_null() {
        return Err("output pointer or output length is null".to_owned());
    }
    unsafe {
        *out_pointer = ptr::null_mut();
        *out_length = 0;
    }
    if ids.is_empty() {
        return Ok(());
    }
    let allocation_length = ids
        .len()
        .checked_mul(std::mem::size_of::<u32>())
        .ok_or_else(|| "encoded output is too large".to_owned())?;
    let allocation = unsafe { libc::malloc(allocation_length) as *mut u32 };
    if allocation.is_null() {
        return Err(format!(
            "could not allocate {allocation_length} bytes for encoded output"
        ));
    }
    unsafe {
        ptr::copy_nonoverlapping(ids.as_ptr(), allocation, ids.len());
        *out_pointer = allocation;
        *out_length = ids.len();
    }
    Ok(())
}

fn parse_tiktoken_model(model: &[u8]) -> Result<FxHashMap<Vec<u8>, u32>, String> {
    let text = std::str::from_utf8(model)
        .map_err(|error| format!("tiktoken model is not valid UTF-8: {error}"))?;
    if text.trim().is_empty() {
        return Err("tiktoken model is empty".to_owned());
    }

    let mut encoder = FxHashMap::default();
    let mut ranks = FxHashMap::default();
    for (index, line) in text.lines().enumerate() {
        let line_number = index + 1;
        let mut fields = line.split_ascii_whitespace();
        let encoded = fields
            .next()
            .ok_or_else(|| format!("tiktoken model line {line_number} is empty"))?;
        let rank_text = fields
            .next()
            .ok_or_else(|| format!("tiktoken model line {line_number} has no rank"))?;
        if fields.next().is_some() {
            return Err(format!(
                "tiktoken model line {line_number} has unexpected extra fields"
            ));
        }
        let token = general_purpose::STANDARD.decode(encoded).map_err(|error| {
            format!("invalid base64 on tiktoken model line {line_number}: {error}")
        })?;
        if token.is_empty() {
            return Err(format!(
                "tiktoken model line {line_number} contains an empty token"
            ));
        }
        let rank = rank_text.parse::<u32>().map_err(|error| {
            format!("invalid rank on tiktoken model line {line_number}: {error}")
        })?;
        if encoder.insert(token, rank).is_some() {
            return Err(format!(
                "tiktoken model line {line_number} duplicates a token"
            ));
        }
        if ranks.insert(rank, line_number).is_some() {
            return Err(format!(
                "tiktoken model line {line_number} duplicates rank {rank}"
            ));
        }
    }

    for byte in 0_u8..=u8::MAX {
        if !encoder.contains_key(&vec![byte]) {
            return Err(format!(
                "tiktoken model does not contain the required single-byte token {byte}"
            ));
        }
    }
    Ok(encoder)
}

#[no_mangle]
pub unsafe extern "C" fn tokenizers_new_from_str(
    json: *const c_char,
    length: usize,
) -> *mut TokenizerWrapper {
    run_constructor(|| {
        let json = unsafe { input_utf8(json.cast(), length, "tokenizer JSON")? };
        let tokenizer = Tokenizer::from_str(json)
            .map_err(|error| format!("could not parse tokenizer JSON: {error}"))?;
        Ok(TokenizerWrapper {
            backend: Backend::HuggingFace(Box::new(tokenizer)),
            decode_bytes: Mutex::new(Vec::new()),
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn tokenizers_new_from_tiktoken(
    model: *const u8,
    model_length: usize,
    pattern: *const u8,
    pattern_length: usize,
    special_token_pointers: *const *const u8,
    special_token_lengths: *const usize,
    special_token_ids: *const u32,
    special_token_count: usize,
) -> *mut TokenizerWrapper {
    run_constructor(|| {
        let model = unsafe { input_bytes(model, model_length, "tiktoken model")? };
        let pattern = unsafe { input_utf8(pattern, pattern_length, "tiktoken pattern")? };
        if pattern.is_empty() {
            return Err("tiktoken pattern is empty".to_owned());
        }
        let encoder = parse_tiktoken_model(model)?;

        if special_token_count > 0
            && (special_token_pointers.is_null()
                || special_token_lengths.is_null()
                || special_token_ids.is_null())
        {
            return Err("special-token arrays are null".to_owned());
        }
        let pointers = if special_token_count == 0 {
            &[][..]
        } else {
            unsafe { slice::from_raw_parts(special_token_pointers, special_token_count) }
        };
        let lengths = if special_token_count == 0 {
            &[][..]
        } else {
            unsafe { slice::from_raw_parts(special_token_lengths, special_token_count) }
        };
        let ids = if special_token_count == 0 {
            &[][..]
        } else {
            unsafe { slice::from_raw_parts(special_token_ids, special_token_count) }
        };

        let ordinary_ids = encoder
            .values()
            .copied()
            .collect::<std::collections::HashSet<_>>();
        let mut special_tokens = FxHashMap::default();
        let mut special_ids = Vec::with_capacity(special_token_count);
        for index in 0..special_token_count {
            let token =
                unsafe { input_utf8(pointers[index], lengths[index], "special-token text")? };
            if token.is_empty() {
                return Err(format!("special token at index {index} is empty"));
            }
            let id = ids[index];
            if ordinary_ids.contains(&id) {
                return Err(format!(
                    "special token {token:?} reuses ordinary token ID {id}"
                ));
            }
            if special_ids.contains(&id) {
                return Err(format!("special token {token:?} duplicates token ID {id}"));
            }
            if special_tokens.insert(token.to_owned(), id).is_some() {
                return Err(format!("duplicate special token {token:?}"));
            }
            special_ids.push(id);
        }

        let bpe = CoreBPE::new(encoder, special_tokens, pattern)
            .map_err(|error| format!("could not create tiktoken tokenizer: {error}"))?;
        Ok(TokenizerWrapper {
            backend: Backend::Tiktoken {
                bpe: Box::new(bpe),
                special_ids,
            },
            decode_bytes: Mutex::new(Vec::new()),
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn tokenizers_encode(
    handle: *mut TokenizerWrapper,
    text: *const c_char,
    length: usize,
    add_special_tokens: c_int,
    allow_special_tokens: c_int,
    out_ids: *mut *mut u32,
    out_length: *mut usize,
) -> c_int {
    if !out_ids.is_null() && !out_length.is_null() {
        unsafe {
            *out_ids = ptr::null_mut();
            *out_length = 0;
        }
    }
    run_status(|| {
        let wrapper = unsafe { wrapper_ref(handle)? };
        let text = unsafe { input_utf8(text.cast(), length, "text")? };
        let ids = wrapper.encode(text, add_special_tokens != 0, allow_special_tokens != 0)?;
        unsafe { write_ids(&ids, out_ids, out_length) }
    })
}

#[no_mangle]
pub unsafe extern "C" fn tokenizers_decode(
    handle: *mut TokenizerWrapper,
    ids: *const u32,
    length: usize,
    skip_special_tokens: c_int,
) -> c_int {
    run_status(|| {
        let wrapper = unsafe { wrapper_ref(handle)? };
        let ids = unsafe {
            if ids.is_null() && length == 0 {
                &[][..]
            } else if ids.is_null() {
                return Err(format!("token ID pointer is null but length is {length}"));
            } else {
                slice::from_raw_parts(ids, length)
            }
        };
        let decoded = wrapper.decode(ids, skip_special_tokens != 0)?;
        let mut stored = wrapper
            .decode_bytes
            .lock()
            .map_err(|_| "decoded-output lock is poisoned".to_owned())?;
        *stored = decoded;
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn tokenizers_get_decode_str(
    handle: *mut TokenizerWrapper,
    out_pointer: *mut *mut u8,
    out_length: *mut usize,
) -> c_int {
    run_status(|| {
        let wrapper = unsafe { wrapper_ref(handle)? };
        let stored = wrapper
            .decode_bytes
            .lock()
            .map_err(|_| "decoded-output lock is poisoned".to_owned())?;
        unsafe { write_bytes(&stored, out_pointer, out_length) }
    })
}

#[no_mangle]
pub unsafe extern "C" fn tokenizers_decode_and_get(
    handle: *mut TokenizerWrapper,
    ids: *const u32,
    length: usize,
    skip_special_tokens: c_int,
    out_pointer: *mut *mut u8,
    out_length: *mut usize,
) -> c_int {
    if !out_pointer.is_null() && !out_length.is_null() {
        unsafe {
            *out_pointer = ptr::null_mut();
            *out_length = 0;
        }
    }
    run_status(|| {
        let wrapper = unsafe { wrapper_ref(handle)? };
        let ids = unsafe {
            if ids.is_null() && length == 0 {
                &[][..]
            } else if ids.is_null() {
                return Err(format!("token ID pointer is null but length is {length}"));
            } else {
                slice::from_raw_parts(ids, length)
            }
        };
        let decoded = wrapper.decode(ids, skip_special_tokens != 0)?;
        unsafe { write_bytes(&decoded, out_pointer, out_length) }
    })
}

#[no_mangle]
pub unsafe extern "C" fn tokenizers_get_last_error(
    out_pointer: *mut *mut u8,
    out_length: *mut usize,
) -> c_int {
    let message = LAST_ERROR.with(|slot| slot.borrow().clone().unwrap_or_default());
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        write_bytes(message.as_bytes(), out_pointer, out_length)
    })) {
        Ok(Ok(())) => STATUS_OK,
        _ => STATUS_ERROR,
    }
}

#[no_mangle]
pub unsafe extern "C" fn tokenizers_free(handle: *mut TokenizerWrapper) {
    if !handle.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
            drop(Box::from_raw(handle));
        }));
    }
}

#[no_mangle]
pub unsafe extern "C" fn tokenizers_free_cstring(pointer: *mut c_char) {
    if !pointer.is_null() {
        unsafe { libc::free(pointer.cast()) };
    }
}

#[no_mangle]
pub unsafe extern "C" fn tokenizers_free_ids(pointer: *mut u32, _length: usize) {
    if !pointer.is_null() {
        unsafe { libc::free(pointer.cast()) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn byte_model() -> String {
        (0_u8..=u8::MAX)
            .map(|byte| format!("{} {}", general_purpose::STANDARD.encode([byte]), byte))
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn parses_complete_byte_model() {
        let encoder = parse_tiktoken_model(byte_model().as_bytes()).unwrap();
        assert_eq!(encoder.len(), 256);
        assert_eq!(encoder.get(&vec![0]), Some(&0));
        assert_eq!(encoder.get(&vec![255]), Some(&255));
    }

    #[test]
    fn rejects_incomplete_model() {
        let error = parse_tiktoken_model(b"YQ== 0").unwrap_err();
        assert!(error.contains("required single-byte token"));
    }

    #[test]
    fn rejects_duplicate_rank() {
        let mut model = byte_model();
        model.push_str("\nYWI= 0");
        let error = parse_tiktoken_model(model.as_bytes()).unwrap_err();
        assert!(error.contains("duplicates rank 0"));
    }
}
