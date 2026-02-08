use std::cell::RefCell;
use std::collections::VecDeque;
use std::mem;

use anyhow::Result;
use raw_window_handle::{
    HasDisplayHandle, HasWindowHandle, RawDisplayHandle, RawWindowHandle,
    Win32WindowHandle, WindowsDisplayHandle,
};
use windows::core::*;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::event::AppEvent;

const WINDOW_CLASS: PCWSTR = w!("SuperViewerWindowClass");

thread_local! {
    static EVENT_QUEUE: RefCell<VecDeque<AppEvent>> = RefCell::new(VecDeque::new());
}

pub fn push_event(event: AppEvent) {
    EVENT_QUEUE.with(|q| q.borrow_mut().push_back(event));
}

pub fn drain_events() -> Vec<AppEvent> {
    EVENT_QUEUE.with(|q| q.borrow_mut().drain(..).collect())
}

pub struct Win32Window {
    hwnd: HWND,
    hinstance: HINSTANCE,
}

impl Win32Window {
    pub fn new(title: &str, width: u32, height: u32) -> Result<Self> {
        // Set DPI awareness before creating window
        unsafe {
            let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        }

        let hinstance: HINSTANCE = unsafe { GetModuleHandleW(None)?.into() };

        // Load embedded app icon (resource ID 1, set by winres in build.rs)
        let icon = unsafe { LoadIconW(Some(hinstance), PCWSTR(1 as *const u16)) }.unwrap_or_default();

        // Register window class
        let wc = WNDCLASSEXW {
            cbSize: mem::size_of::<WNDCLASSEXW>() as u32,
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(wnd_proc),
            hInstance: hinstance,
            hCursor: unsafe { LoadCursorW(None, IDC_ARROW)? },
            hIcon: icon,
            hIconSm: icon,
            lpszClassName: WINDOW_CLASS,
            hbrBackground: unsafe { CreateSolidBrush(COLORREF(0x001A1A1A)) }, // dark gray matching GPU clear color
            ..Default::default()
        };

        unsafe { RegisterClassExW(&wc) };

        // Convert title to wide string
        let title_wide: Vec<u16> = title.encode_utf16().chain(std::iter::once(0)).collect();

        // Adjust window rect for desired client area
        let mut rect = RECT {
            left: 0,
            top: 0,
            right: width as i32,
            bottom: height as i32,
        };
        unsafe {
            AdjustWindowRectEx(&mut rect, WS_OVERLAPPEDWINDOW, false, WINDOW_EX_STYLE(0))?;
        }

        // Center the window on the primary monitor
        let win_w = rect.right - rect.left;
        let win_h = rect.bottom - rect.top;
        let (cx, cy) = unsafe {
            let screen_w = GetSystemMetrics(SM_CXSCREEN);
            let screen_h = GetSystemMetrics(SM_CYSCREEN);
            ((screen_w - win_w) / 2, (screen_h - win_h) / 2)
        };

        let hwnd = unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE(0),
                WINDOW_CLASS,
                PCWSTR(title_wide.as_ptr()),
                WS_OVERLAPPEDWINDOW,
                cx,
                cy,
                win_w,
                win_h,
                None,
                None,
                Some(hinstance),
                None,
            )?
        };

        unsafe {
            use windows::Win32::Graphics::Dwm::*;

            // Dark title bar
            let dark: BOOL = true.into();
            let _ = DwmSetWindowAttribute(
                hwnd,
                DWMWA_USE_IMMERSIVE_DARK_MODE,
                &dark as *const _ as _,
                std::mem::size_of::<BOOL>() as u32,
            );

            // Cloak window — DWM won't composite it until we uncloak after first GPU frame.
            // This eliminates the white flash from DWM's redirection bitmap.
            let cloak: BOOL = true.into();
            let _ = DwmSetWindowAttribute(
                hwnd,
                DWMWA_CLOAK,
                &cloak as *const _ as _,
                std::mem::size_of::<BOOL>() as u32,
            );

            // Show the window while cloaked — sets correct window state for GPU init
            // without being visible to the user.
            let _ = ShowWindow(hwnd, SW_SHOW);

            // Enable drag and drop
            windows::Win32::UI::Shell::DragAcceptFiles(hwnd, true);
        }

        Ok(Self { hwnd, hinstance })
    }

    pub fn hwnd(&self) -> HWND {
        self.hwnd
    }

    pub fn client_size(&self) -> (u32, u32) {
        let mut rect = RECT::default();
        unsafe {
            let _ = GetClientRect(self.hwnd, &mut rect);
        }
        (
            (rect.right - rect.left).max(1) as u32,
            (rect.bottom - rect.top).max(1) as u32,
        )
    }

    /// Pump Win32 messages. Returns false if WM_QUIT received.
    pub fn pump_messages(&self) -> bool {
        unsafe {
            let mut msg = MSG::default();
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT {
                    return false;
                }
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        true
    }

    /// Wait for messages or timeout (avoids busy-waiting when idle).
    pub fn wait_for_events(&self, timeout_ms: u32) {
        unsafe {
            MsgWaitForMultipleObjects(None, false, timeout_ms, QS_ALLINPUT);
        }
    }

    /// Uncloak the window after the first GPU frame is presented.
    /// Reveals the window with dark content already composited — no white flash.
    pub fn uncloak(&self) {
        unsafe {
            use windows::Win32::Graphics::Dwm::*;
            let cloak: BOOL = false.into();
            let _ = DwmSetWindowAttribute(
                self.hwnd,
                DWMWA_CLOAK,
                &cloak as *const _ as _,
                std::mem::size_of::<BOOL>() as u32,
            );
        }
    }

    pub fn set_title(&self, title: &str) {
        let title_wide: Vec<u16> = title.encode_utf16().chain(std::iter::once(0)).collect();
        unsafe {
            let _ = SetWindowTextW(self.hwnd, PCWSTR(title_wide.as_ptr()));
        }
    }

    /// Toggle fullscreen mode. Returns true if now fullscreen.
    pub fn toggle_fullscreen(&self, placement: &mut Option<WINDOWPLACEMENT>) -> bool {
        let style = unsafe { GetWindowLongW(self.hwnd, GWL_STYLE) } as u32;
        let is_windowed = (style & WS_OVERLAPPEDWINDOW.0) != 0;

        if is_windowed {
            // Save placement and go fullscreen
            let mut wp = WINDOWPLACEMENT {
                length: mem::size_of::<WINDOWPLACEMENT>() as u32,
                ..Default::default()
            };
            unsafe {
                let _ = GetWindowPlacement(self.hwnd, &mut wp);
            }
            *placement = Some(wp);

            // Get monitor bounds
            let monitor = unsafe { MonitorFromWindow(self.hwnd, MONITOR_DEFAULTTONEAREST) };
            let mut mi = MONITORINFO {
                cbSize: mem::size_of::<MONITORINFO>() as u32,
                ..Default::default()
            };
            unsafe {
                let _ = GetMonitorInfoW(monitor, &mut mi);
            }

            unsafe {
                SetWindowLongW(self.hwnd, GWL_STYLE, (style & !WS_OVERLAPPEDWINDOW.0) as i32);
                let _ = SetWindowPos(
                    self.hwnd,
                    Some(HWND_TOP),
                    mi.rcMonitor.left,
                    mi.rcMonitor.top,
                    mi.rcMonitor.right - mi.rcMonitor.left,
                    mi.rcMonitor.bottom - mi.rcMonitor.top,
                    SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
                );
            }
            true
        } else {
            // Restore windowed mode
            unsafe {
                SetWindowLongW(
                    self.hwnd,
                    GWL_STYLE,
                    (style | WS_OVERLAPPEDWINDOW.0) as i32,
                );
                if let Some(wp) = placement.take() {
                    let _ = SetWindowPlacement(self.hwnd, &wp);
                }
                let _ = SetWindowPos(
                    self.hwnd,
                    None,
                    0,
                    0,
                    0,
                    0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
                );
            }
            false
        }
    }
}

impl Drop for Win32Window {
    fn drop(&mut self) {
        unsafe {
            let _ = DestroyWindow(self.hwnd);
            let _ = UnregisterClassW(WINDOW_CLASS, Some(self.hinstance));
        }
    }
}

impl HasWindowHandle for Win32Window {
    fn window_handle(
        &self,
    ) -> std::result::Result<raw_window_handle::WindowHandle<'_>, raw_window_handle::HandleError>
    {
        let mut handle = Win32WindowHandle::new(std::num::NonZero::new(self.hwnd.0 as isize).unwrap());
        handle.hinstance = std::num::NonZero::new(self.hinstance.0 as isize);
        let raw = RawWindowHandle::Win32(handle);
        Ok(unsafe { raw_window_handle::WindowHandle::borrow_raw(raw) })
    }
}

impl HasDisplayHandle for Win32Window {
    fn display_handle(
        &self,
    ) -> std::result::Result<raw_window_handle::DisplayHandle<'_>, raw_window_handle::HandleError>
    {
        let raw = RawDisplayHandle::Windows(WindowsDisplayHandle::new());
        Ok(unsafe { raw_window_handle::DisplayHandle::borrow_raw(raw) })
    }
}

unsafe extern "system" fn wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_SIZE => {
            let width = (lparam.0 & 0xFFFF) as u32;
            let height = ((lparam.0 >> 16) & 0xFFFF) as u32;
            if width > 0 && height > 0 {
                push_event(AppEvent::Resized { width, height });
            }
            LRESULT(0)
        }
        WM_KEYDOWN => {
            let vk = wparam.0 as u32;
            let repeat = (lparam.0 & 0x40000000) != 0;
            push_event(AppEvent::KeyDown { vk, repeat });
            LRESULT(0)
        }
        WM_MOUSEMOVE => {
            let x = (lparam.0 & 0xFFFF) as i16 as f64;
            let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as f64;
            push_event(AppEvent::MouseMove { x, y });
            LRESULT(0)
        }
        WM_LBUTTONDOWN => {
            let x = (lparam.0 & 0xFFFF) as i16 as f64;
            let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as f64;
            push_event(AppEvent::MouseButtonDown { button: 0, x, y });
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            let x = (lparam.0 & 0xFFFF) as i16 as f64;
            let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as f64;
            push_event(AppEvent::MouseButtonUp { button: 0, x, y });
            LRESULT(0)
        }
        WM_MOUSEWHEEL => {
            let delta = ((wparam.0 >> 16) as i16) as f64 / 120.0;
            let x = (lparam.0 & 0xFFFF) as i16 as f64;
            let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as f64;
            push_event(AppEvent::MouseWheel { delta, x, y });
            LRESULT(0)
        }
        WM_DROPFILES => {
            use windows::Win32::UI::Shell::*;
            let hdrop = HDROP(wparam.0 as *mut _);
            let count = DragQueryFileW(hdrop, 0xFFFFFFFF, None);
            if count > 0 {
                let mut buf = [0u16; 1024];
                let len = DragQueryFileW(hdrop, 0, Some(&mut buf));
                if len > 0 {
                    let path = String::from_utf16_lossy(&buf[..len as usize]);
                    push_event(AppEvent::FileDropped { path });
                }
            }
            DragFinish(hdrop);
            LRESULT(0)
        }
        WM_CLOSE => {
            push_event(AppEvent::CloseRequested);
            LRESULT(0)
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
