use viewer_win32::input::vk;

pub enum Action {
    Quit,
    ToggleFullscreen,
    FitToScreen,
    Zoom100,
    RotateCW,
    FlipH,
    FlipV,
    NextImage,
    PrevImage,
}

pub fn key_to_action(vk_code: u32) -> Option<Action> {
    match vk_code {
        vk::ESCAPE => Some(Action::Quit),
        vk::KEY_F | vk::F11 => Some(Action::ToggleFullscreen),
        vk::KEY_0 | vk::NUMPAD0 => Some(Action::FitToScreen),
        vk::KEY_1 | vk::NUMPAD1 => Some(Action::Zoom100),
        vk::KEY_R => Some(Action::RotateCW),
        vk::KEY_H => Some(Action::FlipH),
        vk::KEY_V => Some(Action::FlipV),
        vk::RIGHT | vk::SPACE => Some(Action::NextImage),
        vk::LEFT => Some(Action::PrevImage),
        _ => None,
    }
}
