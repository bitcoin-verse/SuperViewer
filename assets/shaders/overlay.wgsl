struct OverlayRect {
    rect: vec4<f32>,  // left, bottom, right, top in NDC
};

@group(0) @binding(0) var t_overlay: texture_2d<f32>;
@group(0) @binding(1) var s_overlay: sampler;
@group(0) @binding(2) var<uniform> overlay_rect: OverlayRect;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VertexOutput {
    // Quad corners: BL, BR, TL, TL, BR, TR
    var uv_pos = array<vec2<f32>, 4>(
        vec2(0.0, 0.0),  // BL in NDC → top of texture (v=0)
        vec2(1.0, 0.0),  // BR in NDC → top of texture
        vec2(0.0, 1.0),  // TL in NDC → bottom of texture (v=1)
        vec2(1.0, 1.0),  // TR in NDC → bottom of texture
    );
    let indices = array<u32, 6>(0u, 1u, 2u, 2u, 1u, 3u);
    let idx = indices[vi];
    let uv = uv_pos[idx];

    let r = overlay_rect.rect;
    let x = mix(r.x, r.z, uv.x);
    let y = mix(r.y, r.w, uv.y);

    var out: VertexOutput;
    out.position = vec4(x, y, 0.0, 1.0);
    out.uv = vec2(uv.x, 1.0 - uv.y); // Flip V: NDC y-up vs texture v-down
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return textureSample(t_overlay, s_overlay, in.uv);
}
