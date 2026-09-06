//
//  LiquidGlassOrb.metal
//  EscapeOS
//
//  v0.3.219：主页液态玻璃灵动球着色器（SwiftUI Shader API，iOS 17+）。
//  算法移植自 D:\Zcode\liquid-glass\index-v2.html 的 WebGL 样板：
//  fbm 极光背景 + SDF 液态微扰球体 + RGB 三路折射色散 + 菲涅尔边缘反射
//  + 虹彩薄膜 + 三光源高光（主光跟随手指）+ 底部焦散 + 卫星小球 + 安全分进度环。
//
//  ⚠️ 需要将本文件加入 App target（拖入 Xcode 工程导航即可）。
//

#include <metal_stdlib>
using namespace metal;

#define ORB_PI 3.14159265359f

// ---------- 噪声 ----------

static inline float hash21(float2 p){
    p = fract(p * float2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

static inline float vnoise(float2 p){
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static inline float fbm(float2 p){
    float v = 0.0, a = 0.5;
    for(int i = 0; i < 5; ++i){
        v += a * vnoise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        a *= 0.5;
    }
    return v;
}

// ---------- 背景（深空极光） ----------

static inline float3 bgGlow(float2 p, float2 c, float r, float3 col){
    float2 d = p - c;
    return col * exp(-dot(d, d) / (r * r));
}

static inline float3 background(float2 p, float t, float aspect){
    float3 col = mix(float3(0.010, 0.012, 0.028), float3(0.045, 0.052, 0.105),
                     clamp(p.y, 0.0, 1.0));
    float b1 = fbm(p * float2(1.4, 2.6) + float2(t * 0.020, -t * 0.015));
    col += float3(0.10, 0.16, 0.42) * smoothstep(0.45, 0.95, b1) * 0.55;
    float b2 = fbm(p * float2(2.2, 1.3) + float2(-t * 0.017, t * 0.010) + 7.3);
    col += float3(0.30, 0.10, 0.38) * smoothstep(0.55, 1.00, b2) * 0.35;

    // 四角极光光斑 + 球后环境光（x 锚点随宽高比缩放）
    col += bgGlow(p, float2((0.10 + 0.02 * sin(t * 0.13)) * aspect, 0.86), 0.30, float3(0.13, 0.20, 0.85));
    col += bgGlow(p, float2((0.95 + 0.03 * sin(t * 0.11 + 2.0)) * aspect, 0.92), 0.26, float3(0.00, 0.55, 0.85));
    col += bgGlow(p, float2((0.92 + 0.03 * sin(t * 0.09 + 4.0)) * aspect, 0.10), 0.28, float3(0.60, 0.08, 0.38));
    col += bgGlow(p, float2((0.08 + 0.02 * sin(t * 0.10 + 1.0)) * aspect, 0.08), 0.24, float3(0.85, 0.45, 0.12));
    col += bgGlow(p, float2(0.5 * aspect, 0.55), 0.42, float3(0.10, 0.12, 0.35));

    // 尘埃
    float dust = smoothstep(0.975, 1.0, vnoise(p * 150.0 + float2(t * 0.03, 0.0)));
    col += float3(0.9, 0.95, 1.0) * dust * 0.05;

    // 暗角
    col *= 1.0 - 0.30 * smoothstep(0.30, 1.05, length(p - float2(0.5 * aspect, 0.55)));
    return col;
}

// ---------- 液态 SDF 球体 ----------

static inline float sdOrb(float2 p, float2 c, float r, float t){
    float2 q = p - c;
    float a = atan2(q.y, q.x);
    // 轮廓随时间液态起伏
    float rr = r * (1.0
        + 0.018 * sin(a * 3.0 + t * 0.8)
        + 0.011 * sin(a * 5.0 - t * 0.6 + 2.1)
        + 0.007 * sin(a * 8.0 + t * 1.1));
    return length(q) - rr;
}

static inline float2 sdNormal(float2 p, float2 c, float r, float t){
    float e = 0.0012;
    return normalize(float2(
        sdOrb(p + float2(e, 0.0), c, r, t) - sdOrb(p - float2(e, 0.0), c, r, t),
        sdOrb(p + float2(0.0, e), c, r, t) - sdOrb(p - float2(0.0, e), c, r, t)));
}

// ---------- 球体着色（折射/色散/菲涅尔/高光/焦散） ----------

static inline float3 shadeOrb(float2 p, float2 c, float r, float3 tint,
                              float t, float2 moff, float aspect){
    float2 q = (p - c) / r;
    float ql = clamp(length(q), 0.0, 0.999);
    float z = sqrt(1.0 - ql * ql);

    // 法线 = 球面法线 + 液体流动扰动 + SDF 轮廓法线 + 手指视差
    float2 n2 = sdNormal(p, c, r, t);
    float3 N = normalize(float3(q, z));
    float2 fl = float2(fbm(p * 3.5 + float2(0.0, t * 0.25)) - 0.5,
                       fbm(p * 3.5 + float2(7.3, -t * 0.21)) - 0.5);
    N = normalize(N + float3(fl, 0.0) * 0.20 * (0.35 + 0.65 * (1.0 - z))
                    + float3(n2, 0.0) * 0.12
                    + float3(moff * 0.05, 0.0));

    // RGB 三路折射采样背景（色散）——球心直视、边缘透镜放大
    float3 V = float3(0.0, 0.0, 1.0);
    float3 Tr = refract(-V, N, 0.835);
    float3 Tg = refract(-V, N, 0.815);
    float3 Tb = refract(-V, N, 0.795);
    float depth = r * 1.1;
    float3 col;
    col.r = background(p + Tr.xy * depth, t, aspect).r;
    col.g = background(p + Tg.xy * depth, t, aspect).g;
    col.b = background(p + Tb.xy * depth, t, aspect).b;

    // 边缘全内反射式压暗 + 菲涅尔环境反射
    float rimF = pow(1.0 - N.z, 3.0);
    col *= 1.0 - 0.55 * smoothstep(0.86, 1.0, ql);
    float3 R = reflect(-V, N);
    float3 env = background(p + R.xy * 0.9, t, aspect) * 1.35 + 0.04;
    col = mix(col, env, clamp(rimF * 1.2, 0.0, 1.0) * 0.85);

    // 内部体色 + 虹彩薄膜
    col += tint * 0.10 * (0.3 + 0.7 * fbm(p * 2.0 + t * 0.1));
    float3 irid = 0.5 + 0.5 * cos(6.28318 * (rimF * 1.2 + float3(0.0, 0.33, 0.66)) + t * 0.25);
    col += irid * rimF * 0.16;

    // 三光源：主光（跟随手指）/ 右下冷色轮廓光 / 游走彩光
    float2 L1d = normalize(float2(-0.62, 0.72) + moff * 1.2);
    float3 L1 = normalize(float3(L1d, 0.75));
    float3 L2 = normalize(float3(0.75, -0.55, 0.35));
    float ph = t * 0.5;
    float3 L3 = normalize(float3(cos(ph) * 0.8, 0.25 + 0.35 * sin(ph * 0.7), 0.45));
    float s1 = pow(max(dot(N, normalize(L1 + V)), 0.0), 240.0) * 1.6;
    float s2 = pow(max(dot(N, normalize(L2 + V)), 0.0), 36.0) * 0.30;
    float s3 = pow(max(dot(N, normalize(L3 + V)), 0.0), 80.0) * 0.55;
    col += float3(1.0) * s1 + float3(0.55, 0.70, 1.0) * s2 + tint * s3;

    // 左上柔光 + 底部焦散
    col += float3(1.0) * 0.22 * exp(-dot(q - float2(-0.38, 0.42), q - float2(-0.38, 0.42)) * 5.5);
    float2 cq = q - float2(0.04, -0.58);
    cq.y *= 1.9;
    float caus = exp(-dot(cq, cq) * 7.0);
    col += (float3(0.9) + tint * 0.5) * caus * 0.35 * (0.6 + 0.8 * fbm(p * 5.0 - t * 0.4));

    col *= mix(float3(1.0), tint * 1.4 + 0.3, 0.22);
    return col;
}

// ---------- 入口（SwiftUI colorEffect） ----------

// pos：视图局部坐标（pt，y 向下）；size：视图尺寸（pt）；
// light：光源 uv 坐标（0…1，y 向上）；tint：分数主题色；progress：0…1 进度。
[[ stitchable ]] half4 liquidGlassOrb(float2 pos, half4 src,
                                      float2 size, float t,
                                      float2 light, float3 tint, float progress)
{
    float aspect = max(size.x / size.y, 0.1);
    float2 p = float2(pos.x / size.y, 1.0 - pos.y / size.y); // y 翻转为向上
    float2 c = float2(0.5 * aspect, 0.55);                    // 球心
    float  R = 0.30;                                          // 球半径
    float2 moff = float2(light.x * aspect, light.y) - c;      // 手指相对球心

    float3 col = background(p, t, aspect);

    // 球下接触阴影
    float2 srel = p - (c - float2(0.0, R * 1.45));
    float2 ss = float2(R * 1.6, R * 0.6);
    col *= 1.0 - 0.32 * exp(-dot(srel / ss, srel / ss));

    // 卫星小琥珀球（绕球漂移）
    {
        float2 sc = c + float2(cos(t * 0.45 + 1.2) * 0.34, 0.26 + 0.10 * sin(t * 0.45 + 1.2));
        float ds = sdOrb(p, sc, 0.026, t);
        float ms = 1.0 - smoothstep(-0.0015, 0.0015, ds);
        if(ms > 0.0){
            float3 oc = shadeOrb(p, sc, 0.026, float3(1.0, 0.75, 0.45), t, moff, aspect);
            col = mix(col, oc, ms);
        }
        col += float3(1.0, 0.75, 0.45) * 0.15 * exp(-max(ds, 0.0) * 40.0) * (1.0 - ms);
    }

    // 主球
    float d = sdOrb(p, c, R, t);
    float m = 1.0 - smoothstep(-0.0015, 0.0015, d);
    if(m > 0.0){
        float3 oc = shadeOrb(p, c, R, tint, t, moff, aspect);
        col = mix(col, oc, m);
    }
    col += tint * 0.16 * exp(-max(d, 0.0) * 26.0) * (1.0 - m);

    // 安全分进度环（顶部起点、顺时针；随 progress 平滑增长）
    float ringR = R * 1.16;
    float2 rq = p - c;
    float rd = length(rq);
    float band = 1.0 - smoothstep(0.008, 0.014, abs(rd - ringR));
    if(band > 0.0){
        float ang = atan2(rq.y, rq.x);
        float a01 = fract((ORB_PI * 0.5 - ang) / (2.0 * ORB_PI));
        float arcMask = (progress <= 0.0005) ? 0.0
                      : (progress >= 0.9995) ? 1.0
                      : 1.0 - smoothstep(progress - 0.003, progress + 0.003, a01);
        col += tint * (band * 0.12 + band * arcMask * 0.9);
        // 进度头部光点
        float ha = ORB_PI * 0.5 - 2.0 * ORB_PI * progress;
        float2 hrel = p - (c + ringR * float2(cos(ha), sin(ha)));
        col += tint * 0.9 * exp(-dot(hrel, hrel) * 900.0);
    }

    // 细颗粒
    col += (hash21(p * size + fract(t) * 61.7) - 0.5) * 0.02;

    return half4(float4(col, 1.0));
}
