use wgpu;

use crate::font;
use crate::gpu::GpuContext;

/// GPU state for a single textured overlay quad.
struct OverlayQuad {
    rect_buffer: wgpu::Buffer,
    texture: Option<wgpu::Texture>,
    texture_view: Option<wgpu::TextureView>,
    bind_group: Option<wgpu::BindGroup>,
}

impl OverlayQuad {
    fn new(gpu: &GpuContext, label: &str) -> Self {
        Self {
            rect_buffer: gpu.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some(label),
                size: 16, // vec4<f32>
                usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }),
            texture: None,
            texture_view: None,
            bind_group: None,
        }
    }

    /// Upload RGBA data, create texture + bind group, and set NDC rect.
    fn upload(
        &mut self,
        gpu: &GpuContext,
        sampler: &wgpu::Sampler,
        bind_group_layout: &wgpu::BindGroupLayout,
        rgba: &[u8],
        tex_w: u32,
        tex_h: u32,
        ndc_rect: [f32; 4],
    ) {
        let texture = gpu.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("Overlay Texture"),
            size: wgpu::Extent3d {
                width: tex_w,
                height: tex_h,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });

        gpu.queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            rgba,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(tex_w * 4),
                rows_per_image: Some(tex_h),
            },
            wgpu::Extent3d {
                width: tex_w,
                height: tex_h,
                depth_or_array_layers: 1,
            },
        );

        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());

        let bind_group = gpu.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Overlay Bind Group"),
            layout: bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(sampler),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: self.rect_buffer.as_entire_binding(),
                },
            ],
        });

        gpu.queue
            .write_buffer(&self.rect_buffer, 0, bytemuck::bytes_of(&ndc_rect));

        self.texture = Some(texture);
        self.texture_view = Some(view);
        self.bind_group = Some(bind_group);
    }

    /// Draw this quad if it has a bind group.
    fn draw<'a>(&'a self, render_pass: &mut wgpu::RenderPass<'a>) {
        if let Some(bg) = &self.bind_group {
            render_pass.set_bind_group(0, Some(bg), &[]);
            render_pass.draw(0..6, 0..1);
        }
    }
}

/// Overlay renderer with status bar and optional drop hint quads.
pub struct OverlayRenderer {
    pipeline: wgpu::RenderPipeline,
    sampler: wgpu::Sampler,
    bind_group_layout: wgpu::BindGroupLayout,
    status: OverlayQuad,
    hint: OverlayQuad,
    current_left_text: String,
    current_right_text: String,
    current_right_y: i32,
    current_viewport_width: u32,
    hint_viewport: (u32, u32),
}

// Status bar visual constants
const BAR_PADDING_X: u32 = 8;
const BAR_PADDING_Y: u32 = 4;
const FG: [u8; 4] = [210, 210, 210, 255];
const BG: [u8; 4] = [20, 20, 20, 210];
const TICKER_PREFIXES: [&str; 6] = [
    "Join the community: ",
    "Latest crypto news: ",
    "Buy, sell, trade: ",
    "Listen: ",
    "Any device, any browser: ",
    "Be seen: ",
];
const LINK_COLOR: [u8; 4] = [255, 153, 0, 255]; // Bitcoin Orange #FF9900

fn ticker_colors(text: &str) -> Vec<[u8; 4]> {
    for prefix in TICKER_PREFIXES {
        if text.starts_with(prefix) {
            let label_color = font::cga_color(15); // CGA White
            let mut colors = vec![label_color; prefix.len()];
            let accent = font::premultiply_color(LINK_COLOR);
            colors.extend(std::iter::repeat(accent).take(text.len() - prefix.len()));
            return colors;
        }
    }
    vec![font::premultiply_color(FG); text.len()]
}

impl OverlayRenderer {
    pub fn new(gpu: &GpuContext) -> Self {
        let shader_src = include_str!("../../../assets/shaders/overlay.wgsl");
        let shader = gpu
            .device
            .create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some("Overlay Shader"),
                source: wgpu::ShaderSource::Wgsl(shader_src.into()),
            });

        let bind_group_layout =
            gpu.device
                .create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                    label: Some("Overlay Bind Group Layout"),
                    entries: &[
                        wgpu::BindGroupLayoutEntry {
                            binding: 0,
                            visibility: wgpu::ShaderStages::FRAGMENT,
                            ty: wgpu::BindingType::Texture {
                                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                                view_dimension: wgpu::TextureViewDimension::D2,
                                multisampled: false,
                            },
                            count: None,
                        },
                        wgpu::BindGroupLayoutEntry {
                            binding: 1,
                            visibility: wgpu::ShaderStages::FRAGMENT,
                            ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                            count: None,
                        },
                        wgpu::BindGroupLayoutEntry {
                            binding: 2,
                            visibility: wgpu::ShaderStages::VERTEX,
                            ty: wgpu::BindingType::Buffer {
                                ty: wgpu::BufferBindingType::Uniform,
                                has_dynamic_offset: false,
                                min_binding_size: None,
                            },
                            count: None,
                        },
                    ],
                });

        let pipeline_layout =
            gpu.device
                .create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                    label: Some("Overlay Pipeline Layout"),
                    bind_group_layouts: &[&bind_group_layout],
                    immediate_size: 0,
                });

        let pipeline = gpu
            .device
            .create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("Overlay Pipeline"),
                layout: Some(&pipeline_layout),
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: Some("vs_main"),
                    buffers: &[],
                    compilation_options: Default::default(),
                },
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: Some("fs_main"),
                    targets: &[Some(wgpu::ColorTargetState {
                        format: gpu.surface_format,
                        blend: Some(wgpu::BlendState::PREMULTIPLIED_ALPHA_BLENDING),
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                    compilation_options: Default::default(),
                }),
                primitive: wgpu::PrimitiveState {
                    topology: wgpu::PrimitiveTopology::TriangleList,
                    ..Default::default()
                },
                depth_stencil: None,
                multisample: wgpu::MultisampleState::default(),
                multiview_mask: None,
                cache: None,
            });

        let sampler = gpu.device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("Overlay Sampler"),
            mag_filter: wgpu::FilterMode::Nearest,
            min_filter: wgpu::FilterMode::Nearest,
            ..Default::default()
        });

        let status = OverlayQuad::new(gpu, "Status Rect Buffer");
        let hint = OverlayQuad::new(gpu, "Hint Rect Buffer");

        Self {
            pipeline,
            sampler,
            bind_group_layout,
            status,
            hint,
            current_left_text: String::new(),
            current_right_text: String::new(),
            current_right_y: i32::MIN,
            current_viewport_width: 0,
            hint_viewport: (0, 0),
        }
    }

    /// Update the status bar texture if text, ticker offset, or viewport changed. Returns true if updated.
    pub fn update(
        &mut self,
        gpu: &GpuContext,
        left_text: &str,
        right_text: &str,
        right_y_offset: i32,
        viewport_width: u32,
        viewport_height: u32,
    ) -> bool {
        if left_text == self.current_left_text
            && right_text == self.current_right_text
            && right_y_offset == self.current_right_y
            && viewport_width == self.current_viewport_width
        {
            return false;
        }

        self.current_left_text = left_text.to_string();
        self.current_right_text = right_text.to_string();
        self.current_right_y = right_y_offset;
        self.current_viewport_width = viewport_width;

        let right_colors = ticker_colors(right_text);
        let (rgba, tex_w, tex_h) = font::render_status_bar(
            left_text,
            right_text,
            right_y_offset,
            FG,
            BG,
            &right_colors,
            BAR_PADDING_X,
            BAR_PADDING_Y,
            viewport_width,
        );

        // NDC rect for bar at the bottom of the viewport
        let bar_ndc_height = 2.0 * tex_h as f32 / viewport_height as f32;
        let rect: [f32; 4] = [-1.0, -1.0, 1.0, -1.0 + bar_ndc_height];

        self.status.upload(
            gpu,
            &self.sampler,
            &self.bind_group_layout,
            &rgba,
            tex_w,
            tex_h,
            rect,
        );
        true
    }

    /// Update the centered drop hint texture. Only re-uploads when viewport size changes.
    pub fn update_drop_hint(
        &mut self,
        gpu: &GpuContext,
        viewport_width: u32,
        viewport_height: u32,
    ) {
        if self.hint_viewport == (viewport_width, viewport_height)
            && self.hint.bind_group.is_some()
        {
            return;
        }
        self.hint_viewport = (viewport_width, viewport_height);

        let (rgba, tex_w, tex_h) = font::render_drop_hint();

        // Center the hint in NDC
        let half_w = tex_w as f32 / viewport_width as f32;
        let half_h = tex_h as f32 / viewport_height as f32;
        let rect: [f32; 4] = [-half_w, -half_h, half_w, half_h];

        self.hint.upload(
            gpu,
            &self.sampler,
            &self.bind_group_layout,
            &rgba,
            tex_w,
            tex_h,
            rect,
        );
    }

    /// Draw overlay quads. Call within an active render pass.
    /// When `show_hint` is true, the drop hint is drawn (centered on screen).
    pub fn draw<'a>(&'a self, render_pass: &mut wgpu::RenderPass<'a>, show_hint: bool) {
        render_pass.set_pipeline(&self.pipeline);
        if show_hint {
            self.hint.draw(render_pass);
        }
        self.status.draw(render_pass);
    }
}
