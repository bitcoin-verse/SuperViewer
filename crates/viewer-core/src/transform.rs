use crate::image_data::DecodedImage;

/// Resize a decoded image to fit within max dimensions, preserving aspect ratio.
/// Returns the original image if it already fits.
pub fn resize_to_fit(image: &DecodedImage, max_width: u32, max_height: u32) -> Option<DecodedImage> {
    if image.width <= max_width && image.height <= max_height {
        return None; // No resize needed
    }

    let scale_x = max_width as f64 / image.width as f64;
    let scale_y = max_height as f64 / image.height as f64;
    let scale = scale_x.min(scale_y);

    let new_width = ((image.width as f64 * scale) as u32).max(1);
    let new_height = ((image.height as f64 * scale) as u32).max(1);

    let mut src_data = image.rgba.clone();
    let src_image = fast_image_resize::images::Image::from_slice_u8(
        image.width,
        image.height,
        &mut src_data,
        fast_image_resize::PixelType::U8x4,
    )
    .ok()?;

    let mut dst_image = fast_image_resize::images::Image::new(
        new_width,
        new_height,
        fast_image_resize::PixelType::U8x4,
    );

    let mut resizer = fast_image_resize::Resizer::new();
    resizer.resize(&src_image, &mut dst_image, None).ok()?;

    Some(DecodedImage {
        rgba: dst_image.into_vec(),
        width: new_width,
        height: new_height,
        format: image.format,
    })
}
