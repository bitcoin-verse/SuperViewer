use viewer_render::renderer::Transform;

pub struct ViewerState {
    // Image dimensions
    pub image_width: u32,
    pub image_height: u32,

    // Viewport dimensions
    pub viewport_width: u32,
    pub viewport_height: u32,

    // View transform
    pub zoom: f64,
    pub pan_x: f64,
    pub pan_y: f64,
    pub rotation: f32,   // Radians (0, PI/2, PI, 3PI/2)
    pub flip_h: bool,
    pub flip_v: bool,

    // Interaction state
    pub dragging: bool,
    pub last_mouse_x: f64,
    pub last_mouse_y: f64,

    // Redraw flag
    pub needs_redraw: bool,
}

impl ViewerState {
    pub fn new() -> Self {
        Self {
            image_width: 0,
            image_height: 0,
            viewport_width: 800,
            viewport_height: 600,
            zoom: 1.0,
            pan_x: 0.0,
            pan_y: 0.0,
            rotation: 0.0,
            flip_h: false,
            flip_v: false,
            dragging: false,
            last_mouse_x: 0.0,
            last_mouse_y: 0.0,
            needs_redraw: true,
        }
    }

    /// Calculate the scale to fit the image in the viewport, preserving aspect ratio.
    pub fn fit_to_screen(&mut self) {
        if self.image_width == 0 || self.image_height == 0 {
            return;
        }
        let (iw, ih) = self.effective_image_size();
        let scale_x = self.viewport_width as f64 / iw as f64;
        let scale_y = self.viewport_height as f64 / ih as f64;
        self.zoom = scale_x.min(scale_y).min(1.0); // Don't upscale
        self.pan_x = 0.0;
        self.pan_y = 0.0;
        self.needs_redraw = true;
    }

    /// Get image dimensions accounting for rotation.
    fn effective_image_size(&self) -> (u32, u32) {
        let steps = ((self.rotation / std::f32::consts::FRAC_PI_2).round() as i32).abs() % 4;
        if steps == 1 || steps == 3 {
            (self.image_height, self.image_width)
        } else {
            (self.image_width, self.image_height)
        }
    }

    /// Zoom by a multiplicative factor, keeping the point under the cursor fixed.
    pub fn zoom_at(&mut self, factor: f64, cursor_x: f64, cursor_y: f64) {
        let old_zoom = self.zoom;
        self.zoom = (self.zoom * factor).clamp(0.01, 100.0);
        let actual_factor = self.zoom / old_zoom;

        // Convert cursor to NDC
        let ndc_x = (cursor_x / self.viewport_width as f64) * 2.0 - 1.0;
        let ndc_y = 1.0 - (cursor_y / self.viewport_height as f64) * 2.0;

        // Adjust pan to keep cursor point fixed
        self.pan_x = ndc_x - (ndc_x - self.pan_x) * actual_factor;
        self.pan_y = ndc_y - (ndc_y - self.pan_y) * actual_factor;
        self.needs_redraw = true;
    }

    /// Set zoom to 100% (1 image pixel = 1 screen pixel).
    pub fn zoom_100(&mut self) {
        let (iw, ih) = self.effective_image_size();
        if iw == 0 || ih == 0 {
            return;
        }
        let img_aspect = iw as f64 / ih as f64;
        let vp_aspect = self.viewport_width as f64 / self.viewport_height as f64;
        // to_transform maps zoom=1.0 to "fill viewport in constrained dimension",
        // so for 1:1 pixels we need zoom = image_size / viewport_size.
        self.zoom = if img_aspect > vp_aspect {
            iw as f64 / self.viewport_width as f64
        } else {
            ih as f64 / self.viewport_height as f64
        };
        self.pan_x = 0.0;
        self.pan_y = 0.0;
        self.needs_redraw = true;
    }

    /// Rotate 90 degrees clockwise.
    pub fn rotate_cw(&mut self) {
        self.rotation += std::f32::consts::FRAC_PI_2;
        if self.rotation >= std::f32::consts::TAU {
            self.rotation -= std::f32::consts::TAU;
        }
        self.fit_to_screen();
    }

    /// Generate the GPU transform from current state.
    pub fn to_transform(&self) -> Transform {
        let (iw, ih) = self.effective_image_size();
        if iw == 0 || ih == 0 {
            return Transform::default();
        }

        let img_aspect = iw as f64 / ih as f64;
        let vp_aspect = self.viewport_width as f64 / self.viewport_height as f64;

        // Scale to fit image aspect ratio in viewport, then apply zoom
        let (sx, sy) = if img_aspect > vp_aspect {
            (self.zoom as f32, (self.zoom * vp_aspect / img_aspect) as f32)
        } else {
            ((self.zoom * img_aspect / vp_aspect) as f32, self.zoom as f32)
        };

        Transform {
            offset: [self.pan_x as f32, self.pan_y as f32],
            scale: [sx, sy],
            rotation: self.rotation,
            flip_h: if self.flip_h { -1.0 } else { 1.0 },
            flip_v: if self.flip_v { -1.0 } else { 1.0 },
            _pad: 0.0,
        }
    }
}
