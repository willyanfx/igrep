/// String utility functions for the search engine.
///
/// These helpers handle common string operations needed during
/// search result formatting and index construction.

/// Normalize line endings to Unix-style LF.
/// TODO: handle mixed line endings within a single file
pub fn normalize_endings(input: &str) -> String {
    input.replace("\r\n", "\n").replace("\r", "\n")
}

/// Count the number of lines in a byte slice without allocating.
pub fn count_lines(data: &[u8]) -> usize {
    data.iter().filter(|&&b| b == b'\n').count() + 1
}

/// Find the byte offset of the Nth line in a buffer.
/// Returns None if there are fewer than N lines.
pub fn line_offset(data: &[u8], line_num: usize) -> Option<usize> {
    if line_num == 0 {
        return Some(0);
    }

    let mut current_line = 0;
    for (i, &byte) in data.iter().enumerate() {
        if byte == b'\n' {
            current_line += 1;
            if current_line == line_num {
                return Some(i + 1);
            }
        }
    }
    None
}

/// Extract a single line from a buffer by line number (0-indexed).
/// FIXME: this allocates — we should return a slice instead
pub fn get_line(data: &[u8], line_num: usize) -> Option<Vec<u8>> {
    let start = if line_num == 0 {
        0
    } else {
        line_offset(data, line_num)?
    };

    let end = data[start..]
        .iter()
        .position(|&b| b == b'\n')
        .map(|pos| start + pos)
        .unwrap_or(data.len());

    Some(data[start..end].to_vec())
}

/// Check if a byte slice looks like binary content.
/// We use a simple heuristic: if more than 10% of bytes in the
/// first 512 bytes are non-printable, treat it as binary.
pub fn is_binary(data: &[u8]) -> bool {
    let check_len = data.len().min(512);
    let non_printable = data[..check_len]
        .iter()
        .filter(|&&b| b < 0x20 && b != b'\n' && b != b'\r' && b != b'\t')
        .count();
    non_printable > check_len / 10
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_count_lines() {
        assert_eq!(count_lines(b"hello\nworld\n"), 3);
        assert_eq!(count_lines(b"single line"), 1);
        assert_eq!(count_lines(b""), 1);
    }

    #[test]
    fn test_line_offset() {
        let data = b"line0\nline1\nline2\n";
        assert_eq!(line_offset(data, 0), Some(0));
        assert_eq!(line_offset(data, 1), Some(6));
        assert_eq!(line_offset(data, 2), Some(12));
    }

    #[test]
    fn test_is_binary() {
        assert!(!is_binary(b"normal text content\nwith lines\n"));
        assert!(is_binary(&[0u8; 100])); // all null bytes
    }

    #[test]
    fn test_normalize_endings() {
        assert_eq!(normalize_endings("a\r\nb\rc\n"), "a\nb\nc\n");
    }
}
