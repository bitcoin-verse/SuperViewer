use std::path::Path;
use anyhow::Result;
use crate::image_data::{DecodedImage, ImageFormat};

/// Decode WebP using the `webp` crate for native libwebp performance.
pub fn decode(path: &Path) -> Result<DecodedImage> {
    let data = std::fs::read(path)?;
    let decoder = webp::Decoder::new(&data);
    let image = decoder
        .decode()
        .ok_or_else(|| anyhow::anyhow!("Failed to decode WebP: {}", path.display()))?;

    let rgba = image.to_image().to_rgba8();
    let (width, height) = rgba.dimensions();

    Ok(DecodedImage {
        rgba: rgba.into_raw(),
        width,
        height,
        format: ImageFormat::Webp,
    })
}
