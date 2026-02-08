use std::path::Path;
use anyhow::Result;
use crate::image_data::{DecodedImage, ImageFormat};

/// Decode JPEG using turbojpeg for maximum speed.
pub fn decode(path: &Path) -> Result<DecodedImage> {
    let data = std::fs::read(path)?;
    let mut decompressor = turbojpeg::Decompressor::new()?;
    let header = decompressor.read_header(&data)?;
    let mut rgba_buf = vec![0u8; header.width * header.height * 4];
    let image = turbojpeg::Image {
        pixels: rgba_buf.as_mut_slice(),
        width: header.width,
        pitch: header.width * 4,
        height: header.height,
        format: turbojpeg::PixelFormat::RGBA,
    };
    decompressor.decompress(&data, image)?;

    Ok(DecodedImage {
        rgba: rgba_buf,
        width: header.width as u32,
        height: header.height as u32,
        format: ImageFormat::Jpeg,
    })
}
