use std::path::Path;
use anyhow::Result;
use crate::image_data::{DecodedImage, ImageFormat};
use crate::formats;

/// Decode an image file, dispatching to the best decoder for the format.
pub fn decode_file(path: &Path) -> Result<DecodedImage> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("");
    let format = ImageFormat::from_extension(ext);

    match format {
        ImageFormat::Jpeg => formats::jpeg::decode(path),
        ImageFormat::Png => formats::png::decode(path),
        ImageFormat::Webp => formats::webp::decode(path),
        ImageFormat::Avif | ImageFormat::Bmp | ImageFormat::Tiff | ImageFormat::Gif => {
            formats::generic::decode(path, format)
        }
        ImageFormat::Unknown => anyhow::bail!("Unsupported image format: {}", ext),
    }
}
