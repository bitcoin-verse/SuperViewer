use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::image_data::DecodedImage;

/// Pre-resized image data ready for GPU upload at a specific viewport size.
pub struct DisplayReady {
    pub rgba: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub viewport_w: u32,
    pub viewport_h: u32,
}

struct CacheEntry {
    image: DecodedImage,
    display: Option<DisplayReady>,
    byte_size: usize,
    last_access: u64,
}

impl CacheEntry {
    fn total_bytes(&self) -> usize {
        self.byte_size
            + self
                .display
                .as_ref()
                .map(|d| d.rgba.len())
                .unwrap_or(0)
    }
}

pub struct ImageCache {
    entries: HashMap<PathBuf, CacheEntry>,
    max_bytes: usize,
    current_bytes: usize,
    access_counter: u64,
}

impl ImageCache {
    pub fn new(max_bytes: usize) -> Self {
        Self {
            entries: HashMap::new(),
            max_bytes,
            current_bytes: 0,
            access_counter: 0,
        }
    }

    /// Get a cached image and its display-ready version. Returns None if not cached.
    pub fn get(&mut self, path: &Path) -> Option<(&DecodedImage, Option<&DisplayReady>)> {
        self.access_counter += 1;
        let counter = self.access_counter;
        self.entries.get_mut(path).map(|entry| {
            entry.last_access = counter;
            (&entry.image, entry.display.as_ref())
        })
    }

    /// Store a display-ready version for an already-cached image.
    pub fn set_display(&mut self, path: &Path, display: DisplayReady) {
        if let Some(entry) = self.entries.get_mut(path) {
            // Remove old display bytes from total
            if let Some(old) = &entry.display {
                self.current_bytes -= old.rgba.len();
            }
            self.current_bytes += display.rgba.len();
            entry.display = Some(display);
        }
    }

    /// Insert a decoded image into the cache. Evicts LRU entries if over capacity.
    pub fn insert(&mut self, path: PathBuf, image: DecodedImage) {
        let byte_size = image.rgba.len();

        // Remove existing entry for this path if present
        if let Some(old) = self.entries.remove(&path) {
            self.current_bytes -= old.total_bytes();
        }

        // Evict LRU entries until we have room
        while self.current_bytes + byte_size > self.max_bytes && !self.entries.is_empty() {
            self.evict_lru();
        }

        // If a single image exceeds max, don't cache it
        if byte_size > self.max_bytes {
            return;
        }

        self.access_counter += 1;
        self.current_bytes += byte_size;
        self.entries.insert(
            path,
            CacheEntry {
                image,
                display: None,
                byte_size,
                last_access: self.access_counter,
            },
        );
    }

    /// Insert a decoded image along with its display-ready version.
    pub fn insert_with_display(
        &mut self,
        path: PathBuf,
        image: DecodedImage,
        display: DisplayReady,
    ) {
        let byte_size = image.rgba.len();
        let display_size = display.rgba.len();
        let total = byte_size + display_size;

        // Remove existing entry for this path if present
        if let Some(old) = self.entries.remove(&path) {
            self.current_bytes -= old.total_bytes();
        }

        // Evict LRU entries until we have room
        while self.current_bytes + total > self.max_bytes && !self.entries.is_empty() {
            self.evict_lru();
        }

        if total > self.max_bytes {
            return;
        }

        self.access_counter += 1;
        self.current_bytes += total;
        self.entries.insert(
            path,
            CacheEntry {
                image,
                display: Some(display),
                byte_size,
                last_access: self.access_counter,
            },
        );
    }

    /// Check if a path is in the cache.
    pub fn contains(&self, path: &Path) -> bool {
        self.entries.contains_key(path)
    }

    fn evict_lru(&mut self) {
        let lru_key = self
            .entries
            .iter()
            .min_by_key(|(_, entry)| entry.last_access)
            .map(|(k, _)| k.clone());

        if let Some(key) = lru_key {
            if let Some(entry) = self.entries.remove(&key) {
                self.current_bytes -= entry.total_bytes();
            }
        }
    }
}
