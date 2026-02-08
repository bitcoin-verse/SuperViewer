#![windows_subsystem = "windows"]

mod app;
mod keybindings;
mod state;

use anyhow::Result;
use viewer_cli::args::Args;

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive(tracing::Level::INFO.into()),
        )
        .init();

    let args = Args::parse_args();
    let app = app::App::new(args.file.as_deref())?;
    app.run()
}
