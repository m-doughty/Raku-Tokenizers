use std::ffi::{CString, c_char};
use std::os::raw::c_int;
use std::slice;
use std::str::FromStr;
use tokenizers::Tokenizer;

pub struct TokenizerWrapper {
    pub tokenizer: Tokenizer,
    pub decode_str: CString,
}

impl TokenizerWrapper {
    pub fn from_str(json: &str) -> Self {
        Self {
            tokenizer: Tokenizer::from_str(json).unwrap(),
            decode_str: CString::new("").unwrap(),
        }
    }

    pub fn encode(&mut self, text: &str, add_special_tokens: bool) -> Vec<u32> {
        let encoded = self.tokenizer.encode(text, add_special_tokens).unwrap();
        encoded.get_ids().to_vec()
    }

    pub fn decode(&mut self, ids: &[u32], skip_special_tokens: bool) {
        let decoded = self.tokenizer.decode(ids, skip_special_tokens).unwrap();
        self.decode_str = CString::new(decoded).unwrap();
    }
}

#[no_mangle]
pub extern "C" fn tokenizers_new_from_str(json: *const c_char, len: usize) -> *mut TokenizerWrapper {
    let slice = unsafe { std::slice::from_raw_parts(json as *const u8, len) };
    let json_str = std::str::from_utf8(slice).unwrap();
    let wrapper = TokenizerWrapper::from_str(json_str);
    Box::into_raw(Box::new(wrapper))
}

#[no_mangle]
pub extern "C" fn tokenizers_encode(
    handle: *mut TokenizerWrapper,
    text: *const c_char,
    len: usize,
    add_special: c_int,
    out_ids: *mut *mut u32,
    out_len: *mut usize,
) {
    let text = unsafe {
        let slice = std::slice::from_raw_parts(text as *const u8, len);
        std::str::from_utf8(slice).unwrap()
    };
    let wrapper = unsafe { &mut *handle };
    let mut ids = wrapper.encode(text, add_special != 0);

    let ptr = ids.as_mut_ptr();
    let len = ids.len();
    std::mem::forget(ids);

    unsafe {
        *out_ids = ptr;
        *out_len = len;
    }
}

#[no_mangle]
pub extern "C" fn tokenizers_decode(
    handle: *mut TokenizerWrapper,
    ids: *const u32,
    len: usize,
    skip_special: c_int,
) {
    let wrapper = unsafe { &mut *handle };
    let slice = unsafe { std::slice::from_raw_parts(ids, len) };
    wrapper.decode(slice, skip_special != 0);
}

#[no_mangle]
pub extern "C" fn tokenizers_get_decode_str(
    handle: *mut TokenizerWrapper,
    out_ptr: *mut *mut c_char,
    out_len: *mut usize,
) {
    let wrapper = unsafe { &mut *handle };
    let bytes = wrapper.decode_str.as_bytes();
    let len = bytes.len();

    unsafe {
        let buf = libc::malloc(len + 1) as *mut c_char;
        if buf.is_null() {
            *out_ptr = std::ptr::null_mut();
            *out_len = 0;
            return;
        }

        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, len);
        *buf.add(len) = 0;
        *out_ptr = buf;
        *out_len = len;
    }
}

#[no_mangle]
pub extern "C" fn tokenizers_decode_and_get(
    handle: *mut TokenizerWrapper,
    ids: *const u32,
    len: usize,
    skip_special: c_int,
    out_ptr: *mut *const c_char,
    out_len: *mut usize,
) {
    if handle.is_null() || ids.is_null() || out_ptr.is_null() || out_len.is_null() {
        return;
    }

    let wrapper = unsafe { &mut *handle };
    let input = unsafe { slice::from_raw_parts(ids, len) };

    let decoded = wrapper.tokenizer.decode(input, skip_special != 0).unwrap();
    let cstr = CString::new(decoded).unwrap();
    let bytes = cstr.as_bytes().len();

    unsafe {
        *out_ptr = cstr.into_raw();
        *out_len = bytes;
    }
}

#[no_mangle]
pub extern "C" fn tokenizers_free(handle: *mut TokenizerWrapper) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)) };
    }
}

#[no_mangle]
pub extern "C" fn tokenizers_free_cstring(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}

#[no_mangle]
pub extern "C" fn tokenizers_free_ids(ptr: *mut u32, len: usize) {
    if !ptr.is_null() && len > 0 {
        unsafe {
            let _ = Vec::from_raw_parts(ptr, len, len);
        }
    }
}

