/// Decoded image in RGBA8 format ready for GPU upload.
#[derive(Debug, Clone)]
pub struct DecodedImage {
    pub rgba: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub format: ImageFormat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageFormat {
    Jpeg,
    Png,
    Webp,
    Avif,
    Bmp,
    Tiff,
    Gif,
    Unknown,
}

impl ImageFormat {
    pub fn from_extension(ext: &str) -> Self {
        match ext.to_ascii_lowercase().as_str() {
            "jpg" | "jpeg" => Self::Jpeg,
            "png" => Self::Png,
            "webp" => Self::Webp,
            "avif" => Self::Avif,
            "bmp" => Self::Bmp,
            "tiff" | "tif" => Self::Tiff,
            "gif" => Self::Gif,
            _ => Self::Unknown,
        }
    }

    pub fn supported_extensions() -> &'static [&'static str] {
        &["jpg", "jpeg", "png", "webp", "avif", "bmp", "tiff", "tif", "gif"]
    }
}
