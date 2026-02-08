use clap::Parser;
use std::path::PathBuf;

#[derive(Parser, Debug)]
#[command(name = "superviewer", about = "Fast image viewer for Windows")]
pub struct Args {
    /// Image file to open
    pub file: Option<PathBuf>,
}

impl Args {
    pub fn parse_args() -> Self {
        Self::parse()
    }
}
