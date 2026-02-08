use std::path::Path;
use anyhow::Result;
use crate::image_data::{DecodedImage, ImageFormat};

/// Decode PNG using the `image` crate.
pub fn decode(path: &Path) -> Result<DecodedImage> {
    let img = image::open(path)?;
    let rgba = img.to_rgba8();
    let (width, height) = rgba.dimensions();

    Ok(DecodedImage {
        rgba: rgba.into_raw(),
        width,
        height,
        format: ImageFormat::Png,
    })
}
