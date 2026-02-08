struct Transform {
    offset: vec2<f32>,   // Pan offset in NDC
    scale: vec2<f32>,    // Scale factor (aspect-corrected)
    rotation: f32,       // Rotation in radians (0, PI/2, PI, 3PI/2)
    flip_h: f32,         // 1.0 = normal, -1.0 = flipped
    flip_v: f32,         // 1.0 = normal, -1.0 = flipped
    _pad: f32,
};

@group(0) @binding(0) var t_image: texture_2d<f32>;
@group(0) @binding(1) var s_image: sampler;
@group(0) @binding(2) var<uniform> transform: Transform;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VertexOutput {
    // Fullscreen quad from vertex index (triangle strip: 0,1,2 + 2,1,3)
    var positions = array<vec2<f32>, 4>(
        vec2(-1.0, -1.0),
        vec2( 1.0, -1.0),
        vec2(-1.0,  1.0),
        vec2( 1.0,  1.0),
    );
    let indices = array<u32, 6>(0u, 1u, 2u, 2u, 1u, 3u);
    let idx = indices[vi];
    let pos = positions[idx];

    // Apply scale and offset
    let scaled = pos * transform.scale + transform.offset;

    // UV from position: map [-1,1] to [0,1], with flip
    var uv = (pos + 1.0) * 0.5;
    uv.x = uv.x * transform.flip_h;
    if transform.flip_h < 0.0 {
        uv.x = uv.x + 1.0;
    }
    uv.y = 1.0 - uv.y; // Flip Y for texture coordinates
    uv.y = uv.y * transform.flip_v;
    if transform.flip_v < 0.0 {
        uv.y = uv.y + 1.0;
    }

    // Apply rotation around center of UV space
    let center = vec2(0.5, 0.5);
    let rotated_uv = uv - center;
    let cos_r = cos(transform.rotation);
    let sin_r = sin(transform.rotation);
    let final_uv = vec2(
        rotated_uv.x * cos_r - rotated_uv.y * sin_r,
        rotated_uv.x * sin_r + rotated_uv.y * cos_r,
    ) + center;

    var out: VertexOutput;
    out.position = vec4(scaled, 0.0, 1.0);
    out.uv = final_uv;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return textureSample(t_image, s_image, in.uv);
}
