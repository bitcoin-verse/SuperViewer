use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::Result;
use windows::Win32::UI::WindowsAndMessaging::WINDOWPLACEMENT;

use viewer_core::cache::{DisplayReady, ImageCache};
use viewer_core::decode;
use viewer_core::directory::DirectoryNavigator;
use viewer_core::image_data::DecodedImage;
use viewer_core::pipeline::{DecodePipeline, DecodePriority};
use viewer_core::transform;
use viewer_render::gpu::GpuContext;
use viewer_render::overlay::OverlayRenderer;
use viewer_render::renderer::ImageRenderer;
use viewer_render::texture::GpuTexture;
use viewer_win32::event::AppEvent;
use viewer_win32::window::{self, Win32Window};

use crate::keybindings::{self, Action};
use crate::state::ViewerState;

const CACHE_MAX_BYTES: usize = 512 * 1024 * 1024; // 512 MB
const STATUS_BAR_HEIGHT: u32 = 24; // 16px glyph + 2*4px padding

const TICKER_MESSAGES: [&str; 6] = [
    "Latest crypto news: news.bitcoin.com",
    "Buy, sell, trade: wallet.bitcoin.com",
    "Join the community: t.me/getverse",
    "Listen: podcast.bitcoin.com",
    "Any device, any browser: accounts.bitcoin.com",
    "Be seen: bitcoin.com/advertise",
];
const TICKER_SCROLL_MS: u64 = 200;
const TICKER_HOLD_MS: u64 = 4000;

#[derive(Clone, Copy, PartialEq, Eq)]
enum TickerPhase {
    ScrollIn,
    Hold,
    ScrollOut,
}

pub struct App {
    window: Win32Window,
    gpu: GpuContext,
    renderer: ImageRenderer,
    overlay: OverlayRenderer,
    state: ViewerState,
    texture: Option<GpuTexture>,
    window_placement: Option<WINDOWPLACEMENT>,
    is_fullscreen: bool,
    navigator: Option<DirectoryNavigator>,
    cache: ImageCache,
    pipeline: DecodePipeline,
    pending_load: Option<PathBuf>,
    current_filename: String,
    ticker_index: usize,
    ticker_phase: TickerPhase,
    ticker_phase_start: Instant,
}

impl App {
    pub fn new(file_path: Option<&Path>) -> Result<Self> {
        // Kick off decode + dir scan immediately — runs in parallel with GPU init
        let decode_handle = file_path.map(|p| {
            let path = p.to_path_buf();
            std::thread::spawn(move || {
                let decoded = decode::decode_file(&path);
                let navigator = DirectoryNavigator::from_file(&path);
                (decoded, navigator, path)
            })
        });

        let window = Win32Window::new("SuperViewer by Bitcoin.com", 1280, 720)?;
        let (w, h) = window.client_size();
        let gpu = GpuContext::new(&window, w, h)?;
        let renderer = ImageRenderer::new(&gpu);

        // Present a dark clear frame then uncloak — overlay shader deferred until after window visible
        let _ = renderer.render_clear_only(&gpu);
        window.uncloak();

        // Compile overlay shader behind the already-visible dark window
        let overlay = OverlayRenderer::new(&gpu);

        let mut state = ViewerState::new();
        state.viewport_width = w;
        state.viewport_height = h.saturating_sub(STATUS_BAR_HEIGHT);

        let cache = ImageCache::new(CACHE_MAX_BYTES);
        let pipeline = DecodePipeline::new();

        // Join decode thread — likely already finished during GPU init
        let (navigator, decoded_result) = if let Some(handle) = decode_handle {
            let (decoded, nav, path) = handle.join().expect("decode thread panicked");
            (nav, Some((decoded, path)))
        } else {
            (None, None)
        };

        let mut app = Self {
            window,
            gpu,
            renderer,
            overlay,
            state,
            texture: None,
            window_placement: None,
            is_fullscreen: false,
            navigator,
            cache,
            pipeline,
            pending_load: None,
            current_filename: String::new(),
            ticker_index: 0,
            ticker_phase: TickerPhase::ScrollIn,
            ticker_phase_start: Instant::now(),
        };

        // Display the pre-decoded image
        if let Some((decoded, path)) = decoded_result {
            match decoded {
                Ok(image) => {
                    app.display_image(&path, image);
                    app.prefetch_adjacent();
                }
                Err(e) => {
                    tracing::error!("Failed to load {}: {}", path.display(), e);
                }
            }
        }

        Ok(app)
    }

    /// Load image synchronously (for initial load).
    fn load_image_sync(&mut self, path: &Path) {
        match decode::decode_file(path) {
            Ok(decoded) => {
                self.display_image(path, decoded);
                self.prefetch_adjacent();
            }
            Err(e) => {
                tracing::error!("Failed to load {}: {}", path.display(), e);
            }
        }
    }

    /// Display a decoded image on screen. Used for initial load and async decode results.
    /// Computes display-ready version, uploads to GPU, and caches both.
    fn display_image(&mut self, path: &Path, decoded: DecodedImage) {
        let vw = self.state.viewport_width;
        let vh = self.state.viewport_height;

        // Compute display-ready version
        let display = Self::compute_display(&decoded, vw, vh);

        // Upload to GPU
        self.upload_to_gpu(&display.rgba, display.width, display.height);

        // Update viewer state
        self.state.image_width = decoded.width;
        self.state.image_height = decoded.height;
        self.state.rotation = 0.0;
        self.state.flip_h = false;
        self.state.flip_v = false;
        self.state.fit_to_screen();

        // Cache full image + display-ready version
        self.cache.insert_with_display(path.to_path_buf(), decoded, display);

        self.current_filename = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("image")
            .to_string();
        self.update_title();
        self.pending_load = None;
    }

    /// Compute a display-ready (resized) version of a decoded image for the given viewport.
    fn compute_display(decoded: &DecodedImage, vw: u32, vh: u32) -> DisplayReady {
        if let Some(resized) = transform::resize_to_fit(decoded, vw, vh) {
            DisplayReady {
                rgba: resized.rgba,
                width: resized.width,
                height: resized.height,
                viewport_w: vw,
                viewport_h: vh,
            }
        } else {
            // Image already fits — use original data without cloning for display
            DisplayReady {
                rgba: decoded.rgba.clone(),
                width: decoded.width,
                height: decoded.height,
                viewport_w: vw,
                viewport_h: vh,
            }
        }
    }

    /// Upload RGBA data to GPU, reusing the existing texture if dimensions match.
    fn upload_to_gpu(&mut self, rgba: &[u8], width: u32, height: u32) {
        if let Some(tex) = &self.texture {
            if tex.matches_size(width, height) {
                // Fast path: reuse existing texture, just update pixel data
                tex.update_rgba(&self.gpu.queue, rgba);
                self.state.needs_redraw = true;
                return;
            }
        }
        // Slow path: create new texture
        let tex = GpuTexture::from_rgba(
            &self.gpu.device,
            &self.gpu.queue,
            rgba,
            width,
            height,
            Some("Current Image"),
        );
        self.renderer.set_texture(&self.gpu, &tex);
        self.texture = Some(tex);
        self.state.needs_redraw = true;
    }

    fn update_title(&self) {
        if self.current_filename.is_empty() {
            self.window.set_title("SuperViewer by Bitcoin.com");
        } else {
            self.window
                .set_title(&format!("{} - SuperViewer by Bitcoin.com", self.current_filename));
        }
    }

    fn status_text(&self) -> String {
        if self.state.image_width == 0 {
            return String::new();
        }
        let mut parts = Vec::new();
        parts.push(self.current_filename.clone());
        parts.push(format!("{}x{}", self.state.image_width, self.state.image_height));

        // Compute display zoom percentage
        // zoom=1.0 means "fill viewport in constrained dim", so we need to convert
        let (iw, ih) = (self.state.image_width as f64, self.state.image_height as f64);
        let (vw, vh) = (self.state.viewport_width as f64, self.state.viewport_height as f64);
        let img_aspect = iw / ih;
        let vp_aspect = vw / vh;
        let base_scale = if img_aspect > vp_aspect { vw / iw } else { vh / ih };
        let pct = (self.state.zoom * base_scale * 100.0).round() as u32;
        parts.push(format!("{}%", pct));

        if let Some(nav) = &self.navigator {
            parts.push(format!("[{}/{}]", nav.current_index() + 1, nav.total()));
        }

        parts.join("  |  ")
    }

    fn ticker_y_offset(&self) -> i32 {
        let elapsed = self.ticker_phase_start.elapsed().as_millis() as u64;
        match self.ticker_phase {
            TickerPhase::ScrollIn => {
                let t = (elapsed as f32 / TICKER_SCROLL_MS as f32).min(1.0);
                let e = t * (2.0 - t); // ease-out: fast start, gentle stop
                (-16.0 + 20.0 * e) as i32 // -16 → 4 (from top)
            }
            TickerPhase::Hold => 4,
            TickerPhase::ScrollOut => {
                let t = (elapsed as f32 / TICKER_SCROLL_MS as f32).min(1.0);
                let e = t * t; // ease-in: gentle start, fast exit
                (4.0 + 20.0 * e) as i32 // 4 → 24 (toward bottom)
            }
        }
    }

    fn advance_ticker(&mut self) {
        let elapsed = self.ticker_phase_start.elapsed().as_millis() as u64;
        match self.ticker_phase {
            TickerPhase::ScrollIn => {
                if elapsed >= TICKER_SCROLL_MS {
                    self.ticker_phase = TickerPhase::Hold;
                    self.ticker_phase_start = Instant::now();
                    self.state.needs_redraw = true; // final static frame
                }
            }
            TickerPhase::Hold => {
                if elapsed >= TICKER_HOLD_MS {
                    self.ticker_phase = TickerPhase::ScrollOut;
                    self.ticker_phase_start = Instant::now();
                }
            }
            TickerPhase::ScrollOut => {
                if elapsed >= TICKER_SCROLL_MS {
                    self.ticker_index = (self.ticker_index + 1) % TICKER_MESSAGES.len();
                    self.ticker_phase = TickerPhase::ScrollIn;
                    self.ticker_phase_start = Instant::now();
                }
            }
        }
    }

    fn navigate(&mut self, forward: bool) {
        // Drain any pending decode results so prefetched images are cached
        self.drain_decode_results();

        let path = {
            let nav = match &mut self.navigator {
                Some(nav) => nav,
                None => return,
            };
            let path = if forward { nav.next() } else { nav.prev() };
            path.to_path_buf()
        };

        let vw = self.state.viewport_width;
        let vh = self.state.viewport_height;

        // Check cache
        if let Some((image, display_opt)) = self.cache.get(&path) {
            let full_w = image.width;
            let full_h = image.height;

            if let Some(display) = display_opt {
                if display.viewport_w == vw && display.viewport_h == vh {
                    // Fast path: display cache hit — inline GPU upload using split borrows
                    // (can't call self.upload_to_gpu() because &mut self conflicts with cache refs)
                    let (dw, dh) = (display.width, display.height);
                    let reuse = match &self.texture {
                        Some(tex) => tex.matches_size(dw, dh),
                        None => false,
                    };
                    if reuse {
                        self.texture
                            .as_ref()
                            .unwrap()
                            .update_rgba(&self.gpu.queue, &display.rgba);
                    } else {
                        let tex = GpuTexture::from_rgba(
                            &self.gpu.device,
                            &self.gpu.queue,
                            &display.rgba,
                            dw,
                            dh,
                            Some("Current Image"),
                        );
                        self.renderer.set_texture(&self.gpu, &tex);
                        self.texture = Some(tex);
                    }
                    self.state.needs_redraw = true;
                } else {
                    // Viewport changed — re-resize from full image
                    let new_display = Self::compute_display(image, vw, vh);
                    self.upload_to_gpu(&new_display.rgba, new_display.width, new_display.height);
                    self.cache.set_display(&path, new_display);
                }
            } else {
                // No display cached — compute from full image
                let new_display = Self::compute_display(image, vw, vh);
                self.upload_to_gpu(&new_display.rgba, new_display.width, new_display.height);
                self.cache.set_display(&path, new_display);
            }

            self.state.image_width = full_w;
            self.state.image_height = full_h;
            self.state.rotation = 0.0;
            self.state.flip_h = false;
            self.state.flip_v = false;
            self.state.fit_to_screen();

            self.current_filename = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("image")
                .to_string();
            self.update_title();
            self.pending_load = None;

            // Prefetch in the direction of travel (skip opposite to avoid
            // wasting main-thread compute_display time on images we won't visit)
            self.prefetch_direction(if forward { 1 } else { -1 });
        } else {
            // Cache miss — request async decode
            self.pipeline.request(&path, DecodePriority::High);
            self.pending_load = Some(path);
        }
    }

    /// Drain all pending decode results from the pipeline, caching them.
    fn drain_decode_results(&mut self) {
        while let Some(result) = self.pipeline.try_recv() {
            match result.result {
                Ok(decoded) => {
                    let is_pending = self
                        .pending_load
                        .as_ref()
                        .map(|p| p == &result.path)
                        .unwrap_or(false);
                    if is_pending {
                        let path = result.path.clone();
                        self.display_image(&path, decoded);
                        self.prefetch_adjacent();
                    } else {
                        // Prefetch result — compute display-ready and cache
                        let vw = self.state.viewport_width;
                        let vh = self.state.viewport_height;
                        let display = Self::compute_display(&decoded, vw, vh);
                        self.cache
                            .insert_with_display(result.path, decoded, display);
                    }
                }
                Err(e) => {
                    tracing::warn!("Failed to decode {}: {}", result.path.display(), e);
                    if self.pending_load.as_ref() == Some(&result.path) {
                        self.pending_load = None;
                    }
                }
            }
        }
    }

    fn prefetch_adjacent(&self) {
        self.prefetch_direction(1);
        self.prefetch_direction(-1);
    }

    fn prefetch_direction(&self, offset: i32) {
        if let Some(nav) = &self.navigator {
            if let Some(path) = nav.peek(offset) {
                if !self.cache.contains(path) {
                    self.pipeline.request(path, DecodePriority::Low);
                }
            }
        }
    }

    pub fn run(mut self) -> Result<()> {
        loop {
            if !self.window.pump_messages() {
                break;
            }

            let events = window::drain_events();
            for event in events {
                self.handle_event(event);
            }

            // Advance ticker animation
            self.advance_ticker();
            let ticker_is_animating =
                self.ticker_phase == TickerPhase::ScrollIn || self.ticker_phase == TickerPhase::ScrollOut;
            if ticker_is_animating {
                self.state.needs_redraw = true;
            }

            // Poll async decode results
            self.drain_decode_results();

            if self.state.needs_redraw {
                let transform = self.state.to_transform();
                self.renderer.update_transform(&self.gpu.queue, &transform);

                let status = self.status_text();
                let ticker_msg = TICKER_MESSAGES[self.ticker_index];
                let ticker_y = self.ticker_y_offset();
                let (_, full_h) = self.gpu.surface_size();
                let has_image = self.texture.is_some();

                // Always update status bar overlay (ticker runs even with no image)
                self.overlay.update(
                    &self.gpu,
                    &status,
                    ticker_msg,
                    ticker_y,
                    self.state.viewport_width,
                    full_h,
                );

                // Update drop hint when no image loaded
                if !has_image {
                    self.overlay.update_drop_hint(
                        &self.gpu,
                        self.state.viewport_width,
                        full_h,
                    );
                }

                match self.renderer.render(&self.gpu, &self.overlay, has_image, self.state.viewport_height) {
                    Ok(()) => {}
                    Err(wgpu::SurfaceError::Lost) => {
                        let (w, h) = self.gpu.surface_size();
                        self.gpu.resize(w, h);
                    }
                    Err(wgpu::SurfaceError::OutOfMemory) => {
                        tracing::error!("GPU out of memory");
                        break;
                    }
                    Err(e) => {
                        tracing::warn!("Surface error: {:?}", e);
                    }
                }
                self.state.needs_redraw = false;
            }

            if ticker_is_animating || self.pending_load.is_some() {
                // Smooth ~60fps during ticker scroll or pending decode
                self.window.wait_for_events(1);
            } else if !self.state.dragging {
                self.window.wait_for_events(16);
            }
        }

        Ok(())
    }

    fn handle_event(&mut self, event: AppEvent) {
        match event {
            AppEvent::Resized { width, height } => {
                self.gpu.resize(width, height);
                self.state.viewport_width = width;
                self.state.viewport_height = height.saturating_sub(STATUS_BAR_HEIGHT);
                self.state.needs_redraw = true;
            }
            AppEvent::KeyDown { vk, repeat } => {
                if !repeat {
                    if let Some(action) = keybindings::key_to_action(vk) {
                        self.handle_action(action);
                    }
                }
            }
            AppEvent::MouseWheel { delta, x, y } => {
                let factor = if delta > 0.0 { 1.15 } else { 1.0 / 1.15 };
                self.state.zoom_at(factor, x, y);
            }
            AppEvent::MouseButtonDown { button: 0, x, y } => {
                self.state.dragging = true;
                self.state.last_mouse_x = x;
                self.state.last_mouse_y = y;
            }
            AppEvent::MouseButtonUp { button: 0, .. } => {
                self.state.dragging = false;
            }
            AppEvent::MouseMove { x, y } => {
                if self.state.dragging {
                    let dx =
                        (x - self.state.last_mouse_x) / self.state.viewport_width as f64 * 2.0;
                    let dy =
                        -(y - self.state.last_mouse_y) / self.state.viewport_height as f64 * 2.0;
                    self.state.pan_x += dx;
                    self.state.pan_y += dy;
                    self.state.last_mouse_x = x;
                    self.state.last_mouse_y = y;
                    self.state.needs_redraw = true;
                }
            }
            AppEvent::FileDropped { path } => {
                let path_buf = PathBuf::from(&path);
                self.navigator = DirectoryNavigator::from_file(&path_buf);
                self.load_image_sync(&path_buf);
            }
            AppEvent::CloseRequested => unsafe {
                windows::Win32::UI::WindowsAndMessaging::PostQuitMessage(0);
            },
            _ => {}
        }
    }

    fn handle_action(&mut self, action: Action) {
        match action {
            Action::Quit => unsafe {
                windows::Win32::UI::WindowsAndMessaging::PostQuitMessage(0);
            },
            Action::ToggleFullscreen => {
                self.is_fullscreen = self.window.toggle_fullscreen(&mut self.window_placement);
                self.state.needs_redraw = true;
            }
            Action::FitToScreen => {
                self.state.fit_to_screen();
            }
            Action::Zoom100 => {
                self.state.zoom_100();
            }
            Action::RotateCW => {
                self.state.rotate_cw();
            }
            Action::FlipH => {
                self.state.flip_h = !self.state.flip_h;
                self.state.needs_redraw = true;
            }
            Action::FlipV => {
                self.state.flip_v = !self.state.flip_v;
                self.state.needs_redraw = true;
            }
            Action::NextImage => self.navigate(true),
            Action::PrevImage => self.navigate(false),
        }
    }
}

