use std::path::{Path, PathBuf};
use std::sync::Arc;

use crossbeam_channel::{Receiver, Sender, bounded};
use rayon::ThreadPool;

use crate::decode;
use crate::image_data::DecodedImage;

/// Request to decode an image.
#[derive(Debug, Clone)]
pub struct DecodeRequest {
    pub path: PathBuf,
    pub priority: DecodePriority,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecodePriority {
    /// Current image — user is waiting
    High,
    /// Prefetch — adjacent images
    Low,
}

/// Result of a decode operation.
pub struct DecodeResult {
    pub path: PathBuf,
    pub result: Result<DecodedImage, String>,
    pub priority: DecodePriority,
}

pub struct DecodePipeline {
    request_tx: Sender<DecodeRequest>,
    result_rx: Receiver<DecodeResult>,
    _pool: Arc<ThreadPool>,
}

impl DecodePipeline {
    pub fn new() -> Self {
        let pool = Arc::new(
            rayon::ThreadPoolBuilder::new()
                .num_threads(2)
                .thread_name(|i| format!("decode-{}", i))
                .build()
                .expect("Failed to build decode thread pool"),
        );

        let (request_tx, request_rx) = bounded::<DecodeRequest>(8);
        let (result_tx, result_rx) = bounded::<DecodeResult>(8);

        // Spawn a dispatcher thread that pulls requests and spawns decode tasks
        let pool_clone = pool.clone();
        std::thread::Builder::new()
            .name("decode-dispatch".into())
            .spawn(move || {
                while let Ok(req) = request_rx.recv() {
                    let tx = result_tx.clone();
                    pool_clone.spawn(move || {
                        let result = std::panic::catch_unwind(|| {
                            decode::decode_file(&req.path)
                        });
                        let result = match result {
                            Ok(Ok(img)) => Ok(img),
                            Ok(Err(e)) => Err(e.to_string()),
                            Err(_) => Err("Decode panicked".to_string()),
                        };
                        let _ = tx.send(DecodeResult {
                            path: req.path,
                            result,
                            priority: req.priority,
                        });
                    });
                }
            })
            .expect("Failed to spawn decode dispatcher");

        Self {
            request_tx,
            result_rx,
            _pool: pool,
        }
    }

    /// Submit a decode request. Non-blocking, drops if channel full.
    pub fn request(&self, path: &Path, priority: DecodePriority) {
        let _ = self.request_tx.try_send(DecodeRequest {
            path: path.to_path_buf(),
            priority,
        });
    }

    /// Poll for completed decode results. Non-blocking.
    pub fn try_recv(&self) -> Option<DecodeResult> {
        self.result_rx.try_recv().ok()
    }
}
