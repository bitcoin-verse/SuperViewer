use std::path::{Path, PathBuf};
use crate::image_data::ImageFormat;

pub struct DirectoryNavigator {
    files: Vec<PathBuf>,
    index: usize,
}

impl DirectoryNavigator {
    /// Create a navigator from a file path. Scans the parent directory for supported images.
    pub fn from_file(path: &Path) -> Option<Self> {
        let canonical = std::fs::canonicalize(path).ok()?;
        let dir = canonical.parent()?;

        let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
            .ok()?
            .filter_map(|entry| entry.ok())
            .map(|e| e.path())
            .filter(|p| {
                p.extension()
                    .and_then(|ext| ext.to_str())
                    .map(|ext| ImageFormat::from_extension(ext) != ImageFormat::Unknown)
                    .unwrap_or(false)
            })
            .collect();

        files.sort_by(|a, b| {
            natord_compare(
                a.file_name().and_then(|n| n.to_str()).unwrap_or(""),
                b.file_name().and_then(|n| n.to_str()).unwrap_or(""),
            )
        });

        let index = files.iter().position(|f| f == &canonical).unwrap_or(0);

        if files.is_empty() {
            return None;
        }

        Some(Self { files, index })
    }

    pub fn current(&self) -> &Path {
        &self.files[self.index]
    }

    pub fn current_index(&self) -> usize {
        self.index
    }

    pub fn total(&self) -> usize {
        self.files.len()
    }

    pub fn next(&mut self) -> &Path {
        if self.index + 1 < self.files.len() {
            self.index += 1;
        } else {
            self.index = 0; // Wrap around
        }
        &self.files[self.index]
    }

    pub fn prev(&mut self) -> &Path {
        if self.index > 0 {
            self.index -= 1;
        } else {
            self.index = self.files.len() - 1; // Wrap around
        }
        &self.files[self.index]
    }

    /// Get the path at offset from current (for prefetching).
    pub fn peek(&self, offset: i32) -> Option<&Path> {
        let len = self.files.len() as i32;
        if len == 0 {
            return None;
        }
        let idx = ((self.index as i32 + offset) % len + len) % len;
        Some(&self.files[idx as usize])
    }
}

/// Natural sort comparison: "img2" < "img10"
fn natord_compare(a: &str, b: &str) -> std::cmp::Ordering {
    let mut ai = a.chars().peekable();
    let mut bi = b.chars().peekable();

    loop {
        match (ai.peek(), bi.peek()) {
            (None, None) => return std::cmp::Ordering::Equal,
            (None, Some(_)) => return std::cmp::Ordering::Less,
            (Some(_), None) => return std::cmp::Ordering::Greater,
            (Some(&ac), Some(&bc)) => {
                if ac.is_ascii_digit() && bc.is_ascii_digit() {
                    // Compare numeric segments
                    let an = collect_digits(&mut ai);
                    let bn = collect_digits(&mut bi);
                    // Compare by length first (longer = bigger), then lexicographic
                    let an_trimmed = an.trim_start_matches('0');
                    let bn_trimmed = bn.trim_start_matches('0');
                    match an_trimmed.len().cmp(&bn_trimmed.len()) {
                        std::cmp::Ordering::Equal => match an_trimmed.cmp(bn_trimmed) {
                            std::cmp::Ordering::Equal => {}
                            ord => return ord,
                        },
                        ord => return ord,
                    }
                } else {
                    let ac_lower = ac.to_ascii_lowercase();
                    let bc_lower = bc.to_ascii_lowercase();
                    match ac_lower.cmp(&bc_lower) {
                        std::cmp::Ordering::Equal => {
                            ai.next();
                            bi.next();
                        }
                        ord => return ord,
                    }
                }
            }
        }
    }
}

fn collect_digits(iter: &mut std::iter::Peekable<std::str::Chars>) -> String {
    let mut s = String::new();
    while let Some(&c) = iter.peek() {
        if c.is_ascii_digit() {
            s.push(c);
            iter.next();
        } else {
            break;
        }
    }
    s
}
