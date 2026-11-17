/// Metal shaders, compiled at runtime so the app builds with the Command Line Tools alone.
enum Shaders {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewSize;
        float2 perspCenter;
        float2 shadowBase;
        float2 shadowSlope;
        float2 knotGrid;
        float perspDist;
        float fringe;
        float shadowAlpha;
        float aspect;
        float quadAlpha;
        float pad;
    };

    struct ClothVertex { packed_float3 position; packed_float3 normal; packed_float2 uv; };
    struct QuadVertex { packed_float2 position; packed_float2 uv; };

    struct ClothOut {
        float4 position [[position]];
        float3 normal;
        float2 uv;
        float height;
    };

    struct QuadOut {
        float4 position [[position]];
        float2 uv;
    };

    // Points in view space to clip space, with a mild perspective so lifted cloth grows a little.
    static float4 toClip(float3 p, constant Uniforms& U) {
        float z = min(p.z, U.perspDist * 0.5);
        float s = U.perspDist / (U.perspDist - z);
        float2 xy = U.perspCenter + (p.xy - U.perspCenter) * s;
        float2 ndc = xy / U.viewSize * 2.0 - 1.0;
        return float4(ndc, clamp(0.5 - p.z * 0.001, 0.0, 1.0), 1.0);
    }

    static float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    vertex ClothOut clothVertex(uint vid [[vertex_id]],
                                device const ClothVertex* v [[buffer(0)]],
                                constant Uniforms& U [[buffer(1)]]) {
        ClothVertex cv = v[vid];
        float3 p = float3(cv.position);
        ClothOut o;
        o.position = toClip(p, U);
        o.normal = float3(cv.normal);
        o.uv = float2(cv.uv);
        o.height = p.z;
        return o;
    }

    fragment float4 clothFragment(ClothOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  sampler smp [[sampler(0)]],
                                  constant Uniforms& U [[buffer(0)]]) {
        float4 c = tex.sample(smp, in.uv);
        if (c.a < 0.5) discard_fragment();
        float3 col = c.rgb / max(c.a, 0.001);

        float3 n = normalize(in.normal);
        bool back = n.z < 0.0;
        if (back) n = -n;

        bool fringe = in.uv.x < U.fringe || in.uv.x > 1.0 - U.fringe;
        float2 kc = in.uv * U.knotGrid;
        float2 f = fract(kc) - 0.5;
        float h = hash21(floor(kc));
        if (!fringe) {
            if (back) {
                // The back of a hand-knotted rug: the pattern shows, flatter, every knot visible.
                float lum = dot(col, float3(0.299, 0.587, 0.114));
                col = mix(col, float3(lum), 0.3);
                float dome = saturate(1.0 - dot(f, f) * 2.6);
                col *= 0.6 + 0.3 * dome + 0.08 * h;
            } else {
                // Wool pile: every knot a slightly different shade.
                col *= 0.93 + 0.09 * h;
                col *= 0.97 + 0.03 * cos(f.y * 6.2831);
            }
        }

        const float3 L = normalize(float3(-0.35, 0.45, 0.82));
        // Exaggerated relief, so lumps and wrinkles read on a busy pattern.
        float relief = (dot(n, L) - L.z) * 1.6;
        float shade = clamp(1.0 + relief, 0.35, 1.3);
        float3 r = reflect(-L, n);
        float sheen = pow(saturate(r.z), 18.0) * (back ? 0.03 : 0.07);
        return float4(col * shade + sheen, 1.0);
    }

    vertex ClothOut shadowVertex(uint vid [[vertex_id]],
                                 device const ClothVertex* v [[buffer(0)]],
                                 constant Uniforms& U [[buffer(1)]]) {
        ClothVertex cv = v[vid];
        float3 p = float3(cv.position);
        float2 xy = p.xy + U.shadowBase + U.shadowSlope * p.z;
        ClothOut o;
        o.position = toClip(float3(xy, 0.0), U);
        o.normal = float3(0.0);
        o.uv = float2(cv.uv);
        o.height = p.z;
        return o;
    }

    fragment float4 shadowFragment(ClothOut in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler smp [[sampler(0)]],
                                   constant Uniforms& U [[buffer(0)]]) {
        float a = tex.sample(smp, in.uv).a;
        float ex = min(in.uv.x, 1.0 - in.uv.x) * U.aspect;
        float ey = min(in.uv.y, 1.0 - in.uv.y);
        float edge = smoothstep(0.0, 0.01, min(ex, ey));
        float fade = mix(1.0, 0.45, saturate(in.height / 220.0));
        float alpha = U.shadowAlpha * a * edge * fade;
        if (alpha < 0.002) discard_fragment();
        return float4(0.0, 0.0, 0.0, alpha);
    }

    vertex QuadOut quadVertex(uint vid [[vertex_id]],
                              constant QuadVertex* v [[buffer(0)]],
                              constant Uniforms& U [[buffer(1)]]) {
        QuadOut o;
        o.position = toClip(float3(float2(v[vid].position), 0.0), U);
        o.uv = float2(v[vid].uv);
        return o;
    }

    fragment float4 quadFragment(QuadOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler smp [[sampler(0)]],
                                 constant Uniforms& U [[buffer(0)]]) {
        return tex.sample(smp, in.uv) * U.quadAlpha;
    }
    """#
}
