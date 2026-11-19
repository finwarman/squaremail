use std::borrow::Cow;

mod names;

const INPUT_LIMIT: usize = 8192;
const ENTITY_LIMIT: usize = 34;
const C1: [u32; 32] = [
    0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021, 0x2c6, 0x2030, 0x160, 0x2039,
    0x152, 0x8d, 0x17d, 0x8f, 0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x2dc,
    0x2122, 0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178,
];

// Match the bounded, single-pass display decoder. Never decode stored mail in place.
pub(crate) fn decode(source: &str) -> Cow<'_, str> {
    if source.len() <= INPUT_LIMIT && !source.as_bytes().contains(&b'&') {
        return Cow::Borrowed(source);
    }
    let bytes = &source.as_bytes()[..source.len().min(INPUT_LIMIT)];
    let mut result = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'&' {
            result.push(bytes[index]);
            index += 1;
            continue;
        }
        let mut end = index + 1;
        while end < bytes.len()
            && end - index <= ENTITY_LIMIT
            && (bytes[end].is_ascii_alphanumeric() || bytes[end] == b'#')
        {
            end += 1;
        }
        let name = std::str::from_utf8(&bytes[index + 1..end]).expect("ASCII entity");
        if bytes.get(end) == Some(&b';')
            && let Some(value) = value(name)
        {
            result.extend_from_slice(value.as_bytes());
            index = end + 1;
            continue;
        }
        result.push(bytes[index]);
        index += 1;
    }
    Cow::Owned(String::from_utf8_lossy(&result).into_owned())
}

fn value(name: &str) -> Option<Cow<'static, str>> {
    let Some(digits) = name.strip_prefix('#') else {
        let index = names::ENTRIES
            .binary_search_by_key(&name, |(name, _)| name)
            .ok()?;
        return Some(Cow::Borrowed(names::ENTRIES[index].1));
    };
    let (number, radix) = match digits.strip_prefix(['x', 'X']) {
        Some(hex) => (hex, 16),
        None => (digits, 10),
    };
    if number.is_empty()
        || !number.bytes().all(|byte| match radix {
            16 => byte.is_ascii_hexdigit(),
            _ => byte.is_ascii_digit(),
        })
    {
        return None;
    }
    let mut code = u32::from_str_radix(number, radix).ok()?;
    if (0x80..=0x9f).contains(&code) {
        code = C1[(code - 0x80) as usize];
    }
    if code == 0 || (0x80..=0x9f).contains(&code) {
        return None;
    }
    Some(Cow::Owned(char::from_u32(code)?.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_search_parity() {
        let cases: serde_json::Value =
            serde_json::from_str(include_str!("../../../shared/header-cases.json")).unwrap();
        for case in cases.as_array().unwrap() {
            let source = case["source"].as_str().unwrap();
            assert_eq!(
                decode(source),
                case["decoded"].as_str().unwrap(),
                "{source}"
            );
        }
        let source: serde_json::Value =
            serde_json::from_str(include_str!("../../../shared/header-entities.json")).unwrap();
        for (name, expected) in source["entries"].as_object().unwrap() {
            assert_eq!(
                decode(&format!("&{name};")),
                expected.as_str().unwrap(),
                "{name}"
            );
        }
        assert!(matches!(decode("Plain text"), Cow::Borrowed(_)));
        assert_eq!(decode(&"&amp;".repeat(10000)).len(), 1640);
        assert_eq!(decode(&"a".repeat(100000)).len(), INPUT_LIMIT);
        assert!(decode(&format!("{}é", "a".repeat(INPUT_LIMIT - 1))).ends_with('\u{fffd}'));
    }
}
