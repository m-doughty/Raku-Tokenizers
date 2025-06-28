use std::fs;
use std::path::Path;

use tokenizers_ffi::TokenizerWrapper;

fn load_tokenizer_json() -> String {
    let path = Path::new("tests/fixtures/tokenizer.json");
    fs::read_to_string(path).expect("Failed to read tokenizer.json")
}

#[test]
fn test_tokenizer_from_str() {
    let json = load_tokenizer_json();
    let wrapper = TokenizerWrapper::from_str(&json);

    assert_eq!(wrapper.decode_str.to_str().unwrap(), "");
}

#[test]
fn test_encode() {
    let json = load_tokenizer_json();
    let mut wrapper = TokenizerWrapper::from_str(&json);

    let text = "Hello, world!";
    let ids = wrapper.encode(text, true);

    assert!(!ids.is_empty());
    assert_eq!(ids.len(), 5);
}

#[test]
fn test_decode_updates_decode_str() {
    let json = load_tokenizer_json();
    let mut wrapper = TokenizerWrapper::from_str(&json);

    let text = "Hello, world!";
    let ids = wrapper.encode(text, true);

    wrapper.decode(&ids, true);
    let decoded = wrapper.decode_str.to_str().unwrap();

    assert!(!decoded.is_empty());
    assert!(decoded.contains("Hello") || decoded.contains("hello"));
}

#[test]
fn test_decode_and_get_equivalent_to_decode_str() {
    let json = load_tokenizer_json();
    let mut wrapper = TokenizerWrapper::from_str(&json);

    let text = "Another test string!";
    let ids = wrapper.encode(text, true);

    wrapper.decode(&ids, true);
    let internal_str = wrapper.decode_str.to_str().unwrap().to_string();

    let decoded = wrapper.tokenizer.decode(&ids, true).unwrap();

    assert_eq!(decoded, internal_str);
}

