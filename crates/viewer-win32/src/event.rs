#[derive(Debug, Clone)]
pub enum AppEvent {
    Resized { width: u32, height: u32 },
    KeyDown { vk: u32, repeat: bool },
    MouseMove { x: f64, y: f64 },
    MouseButtonDown { button: u8, x: f64, y: f64 },
    MouseButtonUp { button: u8, x: f64, y: f64 },
    MouseWheel { delta: f64, x: f64, y: f64 },
    FileDropped { path: String },
    CloseRequested,
}
