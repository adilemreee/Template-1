#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

// ---------------------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------------------

constant float2 kQuad[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * valueNoise(p);
        p = p * 2.03 + float2(17.1, 9.2);
        a *= 0.5;
    }
    return v;
}

static float3 tangentEast(float3 n) {
    float3 e = cross(float3(0, 1, 0), n);
    float len = length(e);
    return len < 1e-4 ? float3(1, 0, 0) : e / len;
}

static float2 sphereUV(float3 p) {
    return float2(atan2(p.x, p.z) / (2.0 * M_PI_F) + 0.5, 0.5 - asin(clamp(p.y, -1.0, 1.0)) / M_PI_F);
}

// The cloud layer floats on its own shell (GlobeRenderer.cloudShellRadius), well above real cloud
// tops so that close up it casts visible shadows and stays sunlit after the ground has gone dark.
constant float kCloudShell = 1.006;

/// How much of the regional 500 m imagery covers this texture coordinate (0 outside it), and where.
static float detailCoverage(float2 uv, constant FrameUniforms& u, texture2d<float> detailMask, sampler cs, thread float2& duv) {
    duv = float2(-1.0);
    if (u.detailBlend <= 0.001) return 0.0;
    float lonDeg = uv.x * 360.0 - 180.0;
    float latDeg = 90.0 - uv.y * 180.0;
    float dLon = lonDeg - u.detailBounds.x;
    dLon -= 360.0 * floor(dLon / 360.0);
    duv = float2(dLon / u.detailBounds.z, (u.detailBounds.y - latDeg) / u.detailBounds.w);
    if (duv.x < 0.0 || duv.x > 1.0 || duv.y < 0.0 || duv.y > 1.0) return 0.0;
    float2 edge = min(duv, 1.0 - duv);
    return detailMask.sample(cs, duv).r * smoothstep(0.0, 0.025, min(edge.x, edge.y)) * u.detailBlend;
}

/// The limb's blue in-scatter, shared by the ground and the cloud tops.
static float3 limbHaze(float3 color, float NdotV, float NdotL) {
    float rim = pow(1.0 - NdotV, 2.4);
    float3 haze = float3(0.30, 0.56, 1.0) * saturate(NdotL + 0.25) * 1.35;
    return mix(color, haze, rim * 0.75 * smoothstep(-0.35, 0.25, NdotL));
}

/// True inside the orange-slice wedge removed from the planet for the Inside the Earth view:
/// every point whose longitude lies within the half-angle of the wedge's centre.
static bool inCutaway(float3 p, float4 cut) {
    if (cut.w <= 0.0) return false;
    float len = length(p.xz);
    return len > 1e-5 && dot(p.xz, cut.xz) > cos(cut.w) * len;
}

// ---------------------------------------------------------------------------------------
// Live weather (NOAA GFS) — frames packed by the Kármán API as RGBA8: eastward and northward
// 10 m wind in 0.5 m/s steps around 128, 2 m temperature in 0.5 °C steps from −80 °C, and
// precipitation as sqrt(mm/h ÷ 50). Rows run from 90° N, columns from 0° E.
// ---------------------------------------------------------------------------------------

static float2 weatherUV(float latDeg, float lonDeg) {
    float lonE = lonDeg < 0.0 ? lonDeg + 360.0 : lonDeg;
    return float2((lonE + 0.5) / 360.0, (90.5 - latDeg) / 181.0);
}

static float2 weatherUVAt(float3 P) {
    return weatherUV(asin(clamp(P.y, -1.0, 1.0)) * 57.2957795, atan2(P.x, P.z) * 57.2957795);
}

/// Samples the frames at a fractional time index, blending the two that bracket it.
static float4 sampleWeather(texture2d_array<float> wx, sampler s, float2 wuv, float slice, float slices) {
    float last = max(slices - 1.0, 0.0);
    float t = clamp(slice, 0.0, last);
    float i0 = floor(t);
    float i1 = min(i0 + 1.0, last);
    float4 a = wx.sample(s, wuv, uint(i0), level(0.0));
    float4 b = wx.sample(s, wuv, uint(i1), level(0.0));
    return mix(a, b, t - i0);
}

static float2 decodeWind(float4 c) { return (c.rg * 255.0 - 128.0) * 0.5; }

static float3 temperatureRamp(float c) {
    // Violet (−40 °C), blue (−20), cyan (0), green (10), yellow (20), orange (30), crimson (42+).
    const float stops[7] = { -40.0, -20.0, 0.0, 10.0, 20.0, 30.0, 42.0 };
    const float3 cols[7] = { float3(0.22, 0.07, 0.48), float3(0.05, 0.18, 0.78), float3(0.06, 0.60, 0.82),
                             float3(0.12, 0.62, 0.20), float3(0.92, 0.80, 0.12), float3(0.96, 0.38, 0.05),
                             float3(0.78, 0.04, 0.12) };
    if (c <= stops[0]) return cols[0];
    for (int i = 1; i < 7; i++) {
        if (c < stops[i]) return mix(cols[i - 1], cols[i], (c - stops[i - 1]) / (stops[i] - stops[i - 1]));
    }
    return cols[6];
}

static float3 rainRamp(float mmh) {
    // Radar-style: drizzle teal → light green → yellow (4 mm/h) → orange (10) → magenta (25+).
    float3 c = mix(float3(0.06, 0.48, 0.58), float3(0.12, 0.78, 0.28), smoothstep(0.1, 1.0, mmh));
    c = mix(c, float3(0.96, 0.86, 0.12), smoothstep(1.0, 4.0, mmh));
    c = mix(c, float3(1.0, 0.42, 0.06), smoothstep(4.0, 10.0, mmh));
    return mix(c, float3(0.88, 0.12, 0.68), smoothstep(10.0, 25.0, mmh));
}

// ---------------------------------------------------------------------------------------
// Sphere (Earth, atmosphere, aurora shells)
// ---------------------------------------------------------------------------------------

struct SphereVertex {
    packed_float3 position;
    packed_float2 uv;
};

struct SphereOut {
    float4 position [[position]];
    float3 world;
    float2 uv;
};

vertex SphereOut sphere_vertex(uint vid [[vertex_id]],
                               const device SphereVertex* verts [[buffer(0)]],
                               constant FrameUniforms& u [[buffer(1)]],
                               constant float& radius [[buffer(2)]]) {
    SphereVertex v = verts[vid];
    float3 world = float3(v.position) * radius;
    SphereOut o;
    o.position = u.viewProj * float4(world, 1.0);
    o.world = world;
    o.uv = float2(v.uv);
    return o;
}

static float4 shadeEarth(SphereOut in, constant FrameUniforms& u,
                         texture2d<float> dayTex, texture2d<float> lightsTex, texture2d<float> cloudTex,
                         texture2d<float> waterTex, texture2d<float> normalTex, texture2d<float> liveTex,
                         texture2d<float> detailTex, texture2d<float> detailMask, texture2d_array<float> weatherTex,
                         sampler s, sampler cs, sampler ws) {
    float3 N = normalize(in.world);
    float3 V = normalize(u.cameraPos - in.world);
    float3 L = normalize(u.sunDir);
    float2 uv = in.uv;
    // Taken here, in uniform control flow, for the samples made inside branches below.
    float2 uvDx = dfdx(uv), uvDy = dfdy(uv);

    // Regional 500 m imagery streamed for the area under the camera (NASA GIBS). It carries
    // its own shaded relief, so the coarse relief map and static clouds step back where it shows.
    float2 duv;
    float detailW = detailCoverage(uv, u, detailMask, cs, duv);
    float4 detail = detailW > 0.0 ? detailTex.sample(cs, duv) : float4(0.0);

    // Relief from the GEBCO-derived normal map (tangent space: x east, y north, z up).
    float3 east = tangentEast(N);
    float3 north = cross(N, east);
    float3 tn = normalTex.sample(s, uv).xyz * 2.0 - 1.0;
    tn.xy *= u.reliefStrength * (1.0 - detailW);
    float3 Nr = normalize(east * tn.x + north * tn.y + N * max(tn.z, 0.25));

    float NdotL = dot(N, L);
    float day = smoothstep(-0.10, 0.22, NdotL);
    float relief = saturate(dot(Nr, L));

    float3 albedo = dayTex.sample(s, uv).rgb;
    albedo = mix(albedo, detail.rgb, detailW * (1.0 - u.liveImagery));

    if (u.liveImagery > 0.001) {
        float3 live = liveTex.sample(s, uv).rgb;
        float valid = smoothstep(0.010, 0.045, dot(live, float3(0.333)));
        albedo = mix(albedo, live, valid * u.liveImagery);
    }
    albedo = pow(max(albedo, 0.0), float3(1.06)) * 1.04;

    // Cloud shadows: follow the sunbeam through this point up to the cloud shell (cloud_fragment
    // draws the clouds themselves), so a low Sun throws long shadows across the ground.
    float cloudAmount = u.cloudOpacity * (1.0 - u.liveImagery * 0.9) * (1.0 - 0.75 * detailW);
    float shadow = 0.0;
    if (cloudAmount > 0.001 && NdotL > -0.05) {
        float reach = -NdotL + sqrt(max(NdotL * NdotL - 1.0 + kCloudShell * kCloudShell, 0.0));
        float2 suv = sphereUV(normalize(N + L * reach));
        // The ground's own derivatives pick the mip level (suv jumps at the antimeridian).
        float cover = cloudTex.sample(s, float2(suv.x + u.cloudDrift, suv.y), gradient2d(uvDx, uvDy)).r;
        shadow = smoothstep(0.2, 0.9, cover) * cloudAmount * smoothstep(-0.05, 0.1, NdotL);
    }

    float water = waterTex.sample(s, uv).r;

    float3 sunColor = mix(float3(1.0, 0.62, 0.38), float3(1.0, 0.97, 0.93), smoothstep(-0.02, 0.22, NdotL));
    float3 surface = albedo * (1.0 - 0.6 * shadow);
    float3 lit = surface * sunColor * relief * 2.3 * day;

    // Ocean glint and sheen.
    float3 H = normalize(L + V);
    float NdotH = saturate(dot(N, H));
    float glint = pow(NdotH, 1400.0) * 3.2 + pow(NdotH, 160.0) * 0.16 + pow(NdotH, 16.0) * 0.035;
    lit += sunColor * glint * water * day;
    float3 color = lit;

    // City lights with a slow shimmer (the cloud shell dims them where it is thick).
    float lights = lightsTex.sample(s, uv).r;
    lights = mix(lights, detail.a, detailW * u.detailNight);
    float night = 1.0 - smoothstep(-0.20, 0.05, NdotL);
    float shimmer = 0.93 + 0.07 * sin(u.time * 2.7 + uv.x * 1300.0 + uv.y * 900.0);
    float3 sodium = mix(float3(1.0, 0.52, 0.20), float3(1.0, 0.86, 0.64), smoothstep(0.35, 1.0, lights));
    // Sharp 500 m lights saturate whole metro areas, so they get a gentler gain than the soft base.
    float lightsGain = mix(2.4, 1.05, detailW * u.detailNight);
    color += sodium * lights * lights * lightsGain * night * u.cityLights * shimmer;
    // Faint moonlit ambient so continents stay readable on the night side.
    color += albedo * float3(0.30, 0.42, 0.65) * 0.045 * night;

    // Live weather maps over the surface (the cloud shell thins out above them): 2 m temperature with isotherms every
    // 10 °C (the freezing line brighter), and precipitation in radar colours.
    if (u.weatherSlices > 0.5 && (u.temperatureOverlay > 0.001 || u.rainOverlay > 0.001)) {
        float4 wx = sampleWeather(weatherTex, ws, weatherUV(90.0 - uv.y * 180.0, uv.x * 360.0 - 180.0), u.weatherSlice, u.weatherSlices);
        float lightFactor = mix(0.16, 1.0, smoothstep(-0.25, 0.2, NdotL));
        if (u.temperatureOverlay > 0.001) {
            float tempC = wx.b * 127.5 - 80.0;
            color = mix(color, temperatureRamp(tempC) * lightFactor * 1.15, 0.62 * u.temperatureOverlay);
            float t10 = tempC / 10.0;
            float fw = max(fwidth(t10), 1e-4);
            float iso = 1.0 - smoothstep(0.0, fw * 1.3, abs(fract(t10 + 0.5) - 0.5));
            float freezing = 1.0 - smoothstep(0.0, fw * 1.8, abs(t10));
            color += (float3(0.10) * iso + float3(0.20, 0.32, 0.36) * freezing) * mix(0.5, 1.0, lightFactor) * u.temperatureOverlay;
        }
        if (u.rainOverlay > 0.001) {
            float rate = wx.a * wx.a * 50.0;
            float streaks = fbm(float2(uv.x * 300.0, uv.y * 150.0) + float2(u.time * 0.04, -u.time * 0.07));
            float a = smoothstep(0.06, 0.9, rate) * (0.62 + 0.38 * streaks) * 0.82 * u.rainOverlay;
            color = mix(color, rainRamp(rate) * mix(0.28, 1.0, lightFactor) * 1.2, a);
        }
    }

    // Seismic waves racing out from an earthquake: the P front (blue-white), the slower S front
    // (orange, stopped by the liquid outer core beyond ~104°) and the broad surface waves.
    if (u.seismicCenter.w > 0.001) {
        float d = acos(clamp(dot(N, normalize(u.seismicCenter.xyz)), -1.0, 1.0));
        float strength = u.seismicCenter.w;
        float shadowP = mix(1.0, 0.35, smoothstep(1.78, 1.86, u.seismicFronts.x));
        float pRing = exp(-pow((d - u.seismicFronts.x) / 0.011, 2.0)) * shadowP * step(0.001, u.seismicFronts.x);
        float sRing = exp(-pow((d - u.seismicFronts.y) / 0.014, 2.0)) * (1.0 - smoothstep(1.76, 1.90, d)) * step(0.001, u.seismicFronts.y);
        float wake = smoothstep(u.seismicFronts.z + 0.002, u.seismicFronts.z - 0.10, d) * step(0.001, u.seismicFronts.z);
        float ripples = (0.55 + 0.45 * sin((d - u.seismicFronts.z) * 160.0)) * exp(-max(u.seismicFronts.z - d, 0.0) * 9.0);
        float rRing = exp(-pow((d - u.seismicFronts.z) / 0.035, 2.0)) * (0.5 + 0.5 * ripples) + wake * ripples * 0.25;
        float glow = mix(0.55, 1.0, smoothstep(-0.2, 0.2, NdotL));
        color += (float3(0.55, 0.85, 1.0) * pRing * 1.5 + float3(1.0, 0.48, 0.18) * sRing * 1.7
                  + float3(1.0, 0.82, 0.42) * rRing * 0.55) * strength * glow;
    }

    // Warm twilight band along the terminator.
    float twilight = exp(-pow((NdotL - 0.03) / 0.085, 2.0));
    color += float3(1.0, 0.40, 0.14) * twilight * 0.03;

    // Atmospheric in-scatter toward the limb.
    color = limbHaze(color, saturate(dot(N, V)), NdotL);
    color += float3(0.008, 0.022, 0.055) * day;

    return float4(color * u.sceneFade, 1.0);
}

fragment float4 earth_fragment(SphereOut in [[stage_in]],
                               constant FrameUniforms& u [[buffer(0)]],
                               texture2d<float> dayTex [[texture(0)]],
                               texture2d<float> lightsTex [[texture(1)]],
                               texture2d<float> cloudTex [[texture(2)]],
                               texture2d<float> waterTex [[texture(3)]],
                               texture2d<float> normalTex [[texture(4)]],
                               texture2d<float> liveTex [[texture(5)]],
                               texture2d<float> detailTex [[texture(6)]],
                               texture2d<float> detailMask [[texture(7)]],
                               texture2d_array<float> weatherTex [[texture(8)]],
                               sampler s [[sampler(0)]],
                               sampler cs [[sampler(1)]],
                               sampler ws [[sampler(2)]]) {
    return shadeEarth(in, u, dayTex, lightsTex, cloudTex, waterTex, normalTex, liveTex, detailTex, detailMask, weatherTex, s, cs, ws);
}

/// The same surface with the Inside the Earth wedge removed (a separate pipeline, so the everyday
/// globe never pays for the discard).
fragment float4 earth_cutaway_fragment(SphereOut in [[stage_in]],
                                       constant FrameUniforms& u [[buffer(0)]],
                                       texture2d<float> dayTex [[texture(0)]],
                                       texture2d<float> lightsTex [[texture(1)]],
                                       texture2d<float> cloudTex [[texture(2)]],
                                       texture2d<float> waterTex [[texture(3)]],
                                       texture2d<float> normalTex [[texture(4)]],
                                       texture2d<float> liveTex [[texture(5)]],
                                       texture2d<float> detailTex [[texture(6)]],
                                       texture2d<float> detailMask [[texture(7)]],
                                       texture2d_array<float> weatherTex [[texture(8)]],
                                       sampler s [[sampler(0)]],
                                       sampler cs [[sampler(1)]],
                                       sampler ws [[sampler(2)]]) {
    float4 color = shadeEarth(in, u, dayTex, lightsTex, cloudTex, waterTex, normalTex, liveTex, detailTex, detailMask, weatherTex, s, cs, ws);
    if (inCutaway(in.world, u.cutaway)) discard_fragment();
    return color;
}

// ---------------------------------------------------------------------------------------
// Inside the Earth: the two faces of the cut, a half-disc each, with the layers by radius
// (PREM: inner core 1,221 km, outer core 3,480 km, the 660 km discontinuity; the crust drawn
// thicker than life so it reads at globe scale).
// ---------------------------------------------------------------------------------------

struct CutOut {
    float4 position [[position]];
    float2 local;    // x: out from the axis, y: along it (north up); 1 = the surface
    float face;
};

vertex CutOut cutface_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             constant FrameUniforms& u [[buffer(0)]]) {
    // A fan of thin triangles, so the rim is real geometry and gets multisampled edges.
    const float segments = 96.0;
    uint tri = vid / 3, corner = vid % 3;
    float2 local = float2(0.0);
    if (corner > 0) {
        float a = M_PI_F * (float(tri + corner - 1) / segments - 0.5);
        local = float2(cos(a), sin(a));
    }
    float lonC = atan2(u.cutaway.x, u.cutaway.z);
    float lonF = lonC + (iid == 0 ? -u.cutaway.w : u.cutaway.w);
    float3 world = float3(sin(lonF), 0.0, cos(lonF)) * local.x + float3(0.0, 1.0, 0.0) * local.y;
    CutOut o;
    o.position = u.viewProj * float4(world, 1.0);
    o.local = local;
    o.face = float(iid);
    return o;
}

static float3 earthInterior(float r, float theta, float time, float face) {
    const float rIC = 0.1917, rOC = 0.5462, rLM = 0.8948, rCrust = 0.985;
    float3 col;
    if (r < rIC) {
        // Inner core: solid iron, white-hot, faintly crystalline.
        float xtal = valueNoise(float2(r * 90.0 + face * 7.0, theta * 30.0));
        col = float3(1.0, 0.86, 0.62) * (1.45 + 0.6 * (1.0 - r / rIC)) * (0.92 + 0.08 * xtal);
    } else if (r < rOC) {
        // Outer core: liquid iron churning round the axis (the geodynamo).
        float swirl = fbm(float2(theta * 4.0 + time * 0.10 + sin(r * 16.0 + time * 0.2) * 0.6, r * 18.0 - time * 0.05));
        float swirl2 = fbm(float2(theta * 9.0 - time * 0.16, r * 30.0 + swirl * 3.0));
        float heat = saturate(0.35 + 0.9 * swirl + 0.25 * swirl2 - 0.5 * (r - rIC) / (rOC - rIC));
        col = mix(float3(0.80, 0.18, 0.02), float3(1.0, 0.60, 0.16), heat) * (0.42 + 0.55 * heat);
    } else if (r < rLM) {
        // Lower mantle: slow convection, hot plumes rising off the core, cool slabs sinking.
        float depth = (rLM - r) / (rLM - rOC);
        float cells = 0.5 + 0.5 * sin(theta * 6.0 + 1.8 * sin(r * 7.0 - time * 0.15) + 0.4);
        float plume = fbm(float2(theta * 10.0, r * 9.0 - time * 0.06)) * cells;
        float heat = saturate(0.25 + 0.55 * depth + 0.9 * (plume - 0.3));
        col = mix(float3(0.30, 0.04, 0.02), float3(0.95, 0.36, 0.07), heat) * (0.18 + 0.42 * heat);
    } else if (r < rCrust) {
        // Upper mantle: cooler rock that still creeps.
        float grain = fbm(float2(theta * 22.0, r * 60.0));
        col = float3(0.55, 0.12, 0.04) * (0.12 + 0.12 * grain + 0.12 * (rCrust - r) / (rCrust - rLM));
    } else {
        // Crust: cold rock in strata.
        float grain = fbm(float2(theta * 22.0, r * 60.0));
        col = float3(0.10, 0.08, 0.065) * (0.75 + 0.25 * sin(r * 2400.0 + grain * 4.0));
    }
    // Fine dark seams between layers; the core-mantle boundary glows.
    col *= 1.0 - 0.5 * exp(-pow((r - rIC) / 0.003, 2.0));
    col *= 1.0 - 0.5 * exp(-pow((r - rLM) / 0.003, 2.0));
    col *= 1.0 - 0.6 * exp(-pow((r - rCrust) / 0.002, 2.0));
    col += float3(1.0, 0.5, 0.15) * exp(-pow((r - rOC) / 0.005, 2.0)) * 0.5;
    return col;
}

fragment float4 cutface_fragment(CutOut in [[stage_in]], constant FrameUniforms& u [[buffer(0)]]) {
    float r = min(length(in.local), 1.0);
    float theta = atan2(in.local.y, max(in.local.x, 1e-5));
    return float4(earthInterior(r, theta, u.time, in.face) * u.sceneFade, 1.0);
}

// Analytic atmosphere halo, drawn on the back faces of a slightly larger sphere.
fragment float4 atmosphere_fragment(SphereOut in [[stage_in]],
                                    constant FrameUniforms& u [[buffer(0)]],
                                    constant float& outerRadius [[buffer(1)]]) {
    float3 C = u.cameraPos;
    float3 D = normalize(in.world - C);
    float t = -dot(C, D);
    float3 Q = C + D * t;
    float b = length(Q);
    // Rays through the planet itself only get here through the Inside the Earth cut.
    if (b < 1.0) discard_fragment();
    float h = saturate((b - 1.0) / (outerRadius - 1.0));
    float density = exp(-h * 5.0) * (1.0 - h) * (1.0 - h);

    float3 L = normalize(u.sunDir);
    float3 Qn = Q / max(b, 1e-4);
    float mu = dot(Qn, L);
    float sunlit = smoothstep(-0.32, 0.30, mu);
    float sunsetBand = exp(-pow((mu + 0.02) / 0.16, 2.0));

    float3 rayleigh = float3(0.24, 0.50, 1.0);
    float3 sunset = float3(1.0, 0.40, 0.14);
    float3 col = rayleigh * sunlit * 2.0 + sunset * sunsetBand * 1.4;

    float cosTheta = saturate(dot(D, L));
    float mie = pow(cosTheta, 10.0) * 2.0 + pow(cosTheta, 180.0) * 16.0;
    col += float3(1.0, 0.80, 0.58) * mie * (0.25 + sunsetBand + sunlit * 0.2);

    // Night airglow: the thin green (557.7 nm oxygen) layer ~95 km up that crews photograph
    // hugging the night limb. Seen edge-on, it shows where the ray grazes that altitude.
    float nightSide = 1.0 - smoothstep(-0.22, 0.04, mu);
    float airglow = exp(-pow((b - 1.0150) / 0.0010, 2.0)) * nightSide;
    float3 glow = float3(0.30, 1.0, 0.50) * airglow * 0.16;

    return float4((col * density + glow) * u.atmosphereIntensity * u.sceneFade, 0.0);
}

// Aurora shells driven by NOAA's OVATION probability grid.
fragment float4 aurora_fragment(SphereOut in [[stage_in]],
                                constant FrameUniforms& u [[buffer(0)]],
                                constant float& layer [[buffer(1)]],
                                texture2d<float> grid [[texture(0)]],
                                sampler gs [[sampler(0)]]) {
    float3 P = normalize(in.world);
    float lat = asin(clamp(P.y, -1.0, 1.0)) * 57.2957795;
    if (abs(lat) < 38.0 || inCutaway(P, u.cutaway)) discard_fragment();
    float lon = atan2(P.x, P.z) * 57.2957795;
    float lonE = lon < 0.0 ? lon + 360.0 : lon;
    float2 guv = float2((lonE + 0.5) / 360.0, (lat + 90.5) / 181.0);
    float prob = saturate(grid.sample(gs, guv).r * 2.55);
    float visible = smoothstep(0.01, 0.45, prob);
    if (visible < 0.002) discard_fragment();

    float tm = u.time;
    float n = fbm(float2(lonE * 0.32 + tm * 0.045, lat * 0.55 - tm * 0.018));
    float folds = sin(lonE * 1.9 + n * 7.0 + tm * 0.35) * 0.5 + 0.5;
    float rays = pow(folds, 2.5);
    float fine = valueNoise(float2(lonE * 6.0 + tm * 0.6, lat * 2.0));
    float curtain = mix(0.35, 1.0, n) * (0.55 + 0.45 * rays) * (0.8 + 0.2 * fine);

    float3 V = normalize(u.cameraPos - in.world);
    float grazing = 1.0 / max(dot(P, V), 0.16);
    float3 L = normalize(u.sunDir);
    float darkness = 1.0 - 0.8 * smoothstep(-0.12, 0.30, dot(P, L));

    float3 col = layer < 0.5 ? float3(0.10, 1.0, 0.42) : float3(0.75, 0.12, 0.62);
    float strength = layer < 0.5 ? 0.34 : 0.12;
    float intensity = visible * curtain * grazing * strength * darkness * u.auroraIntensity;
    return float4(col * intensity * u.sceneFade, 0.0);
}

// Clouds on their own shell: lit by the Sun with relief from the cloud map's slopes, turning gold
// and then rose as the Sun sets beneath them, still glowing after the ground below has gone dark.
fragment float4 cloud_fragment(SphereOut in [[stage_in]],
                               constant FrameUniforms& u [[buffer(0)]],
                               constant float& shellRadius [[buffer(1)]],
                               texture2d<float> cloudTex [[texture(0)]],
                               texture2d<float> detailMask [[texture(1)]],
                               sampler s [[sampler(0)]],
                               sampler cs [[sampler(1)]]) {
    float2 duv;
    float detailW = detailCoverage(in.uv, u, detailMask, cs, duv);
    float amount = u.cloudOpacity * (1.0 - u.liveImagery * 0.9) * (1.0 - 0.75 * detailW);
    // Step aside for the weather maps and seismic waves painted on the ground beneath.
    amount *= (1.0 - 0.6 * max(u.temperatureOverlay, u.rainOverlay)) * (1.0 - 0.5 * u.seismicCenter.w);
    float2 cuv = float2(in.uv.x + u.cloudDrift, in.uv.y);
    // Derivatives before any discard (the relief samples below reuse them explicitly).
    gradient2d grad = gradient2d(dfdx(cuv), dfdy(cuv));
    float worldPerPixel = length(fwidth(in.world));
    float density = smoothstep(0.16, 0.92, cloudTex.sample(s, cuv).r);
    float alpha = density * amount;
    if (alpha < 0.004 || inCutaway(in.world, u.cutaway)) discard_fragment();

    float3 N = normalize(in.world);
    float3 V = normalize(u.cameraPos - in.world);
    float3 L = normalize(u.sunDir);
    float NdotL = dot(N, L);
    float NdotV = saturate(dot(N, V));

    // Relief: thick cloud bulges up, so the map's slopes tilt the normal. The step follows the
    // footprint of a pixel, keeping the relief alive when the texture is minified.
    float texel = 1.0 / float(cloudTex.get_width());
    float footprint = clamp(worldPerPixel / (2.0 * M_PI_F * texel), 1.0, 8.0);
    float2 o = float2(texel, 1.0 / float(cloudTex.get_height())) * 2.5 * footprint;
    float gE = smoothstep(0.16, 0.92, cloudTex.sample(s, cuv + float2(o.x, 0), grad).r) - smoothstep(0.16, 0.92, cloudTex.sample(s, cuv - float2(o.x, 0), grad).r);
    float gN = smoothstep(0.16, 0.92, cloudTex.sample(s, cuv - float2(0, o.y), grad).r) - smoothstep(0.16, 0.92, cloudTex.sample(s, cuv + float2(0, o.y), grad).r);
    float3 east = tangentEast(N);
    float3 north = cross(N, east);
    float3 Nc = normalize(N - (east * gE + north * gN) * 1.2);

    // Sunlight at the cloud tops: white by day, gold then rose at sunset, gone in Earth's shadow.
    float shadowEdge = -sqrt(max(1.0 - 1.0 / (shellRadius * shellRadius), 0.0));
    float sunlit = smoothstep(shadowEdge - 0.004, shadowEdge + 0.035, NdotL);
    float3 sunColor = mix(float3(1.0, 0.97, 0.93), float3(1.0, 0.66, 0.38), 1.0 - smoothstep(-0.02, 0.32, NdotL));
    sunColor = mix(sunColor, float3(0.95, 0.36, 0.30), 1.0 - smoothstep(shadowEdge + 0.01, 0.04, NdotL));
    float lambert = saturate(dot(Nc, L) * 0.65 + 0.35);
    float3 color = sunColor * lambert * 1.75 * sunlit * (0.75 + 0.25 * density);
    color += float3(0.03, 0.048, 0.078) * smoothstep(-0.1, 0.3, NdotL);     // blue skylight
    color += float3(0.006, 0.009, 0.016);                                    // moonlit at night
    color = limbHaze(color, NdotV, NdotL);

    // Seen obliquely the layer is thicker; fade at the shell's own silhouette so it never rings
    // the planet. At night, city glow bleeds through.
    alpha = 1.0 - pow(1.0 - min(alpha, 0.999), min(1.0 / max(NdotV, 0.05), 3.5));
    alpha *= smoothstep(0.0, 0.12, NdotV) * mix(0.8, 1.0, smoothstep(-0.2, 0.05, NdotL));
    alpha *= u.sceneFade;
    return float4(color * alpha, alpha);
}

// ---------------------------------------------------------------------------------------
// Stars & Sun
// ---------------------------------------------------------------------------------------

struct StarData {
    packed_float3 dir;
    float mag;
    uchar4 color;
};

struct StarOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
    float seed;
};

vertex StarOut star_vertex(uint vid [[vertex_id]],
                           const device StarData* stars [[buffer(0)]],
                           constant FrameUniforms& u [[buffer(1)]]) {
    StarData s = stars[vid];
    float3 dir = (u.starRotation * float4(float3(s.dir), 0.0)).xyz;
    float3 viewDir = (u.view * float4(dir, 0.0)).xyz;
    float4 clip = u.proj * float4(viewDir, 1.0);
    clip.z = clip.w * 0.99999;
    StarOut o;
    o.position = clip;
    float m = s.mag;
    o.pointSize = clamp(4.6 - 0.62 * m, 1.2, 6.0) * u.pixelScale;
    float brightness = clamp(pow(10.0, -0.4 * (m - 0.2)), 0.05, 2.2);
    o.color = float4(float3(s.color.rgb) / 255.0, 1.0) * brightness;
    o.seed = fract(sin(float(vid) * 12.9898) * 43758.5453);
    return o;
}

fragment float4 star_fragment(StarOut in [[stage_in]],
                              float2 pc [[point_coord]],
                              constant FrameUniforms& u [[buffer(0)]]) {
    float r = length(pc * 2.0 - 1.0);
    float core = exp(-r * r * 9.0);
    float twinkle = 0.82 + 0.18 * sin(u.time * (1.5 + in.seed * 3.0) + in.seed * 40.0);
    return float4(in.color.rgb * core * twinkle * u.starIntensity * u.sceneFade, 0.0);
}

struct SunOut {
    float4 position [[position]];
    float2 local;
};

vertex SunOut sun_vertex(uint vid [[vertex_id]], constant FrameUniforms& u [[buffer(0)]]) {
    float2 c = kQuad[vid];
    // Far from the camera in the Sun's direction, so it stays at infinity however far out you zoom.
    float3 center = u.cameraPos + normalize(u.sunDir) * 250.0;
    float size = 68.75;
    float3 world = center + (u.cameraRight * c.x + u.cameraUp * c.y) * size;
    SunOut o;
    o.position = u.viewProj * float4(world, 1.0);
    o.local = c;
    return o;
}

fragment float4 sun_fragment(SunOut in [[stage_in]], constant FrameUniforms& u [[buffer(0)]]) {
    float r = length(in.local);
    if (r > 1.0) discard_fragment();
    float edge = smoothstep(1.0, 0.45, r);
    float disc = smoothstep(0.040, 0.026, r) * 40.0;
    float glow = exp(-r * 11.0) * 2.2 + exp(-r * 34.0) * 8.0 + exp(-r * 4.0) * 0.12;
    float ang = atan2(in.local.y, in.local.x);
    float rays = pow(abs(cos(ang * 4.0 + u.time * 0.05)), 60.0) * exp(-r * 5.0) * 0.5;
    float3 col = float3(1.0, 0.93, 0.82) * (disc + (glow + rays) * edge);
    return float4(col * u.sceneFade, 0.0);
}

// ---------------------------------------------------------------------------------------
// Milky Way backdrop: a panorama in galactic coordinates baked by tools/build_milkyway.py
// (l = 0 in the middle, increasing to the left; b = +45° at the top edge, −45° at the bottom).
// ---------------------------------------------------------------------------------------

// J2000 equatorial → galactic (the IAU definition as tabulated for Hipparcos), by columns.
constant float3x3 kEquatorialToGalactic = float3x3(
    float3(-0.0548755604, 0.4941094279, -0.8676661490),
    float3(-0.8734370902, -0.4448296300, -0.1980763734),
    float3(-0.4838350155, 0.7469822445, 0.4559837762));

struct SkyOut {
    float4 position [[position]];
    float3 ray;    // render-frame view ray; linear across the screen, so it interpolates exactly
};

vertex SkyOut milkyway_vertex(uint vid [[vertex_id]], constant FrameUniforms& u [[buffer(0)]]) {
    float2 ndc = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    float3 forward = cross(u.cameraUp, u.cameraRight);
    SkyOut o;
    // At the far plane: the depth test keeps it behind everything, even the Moon's far orbit.
    o.position = float4(ndc, 0.9999999, 1.0);
    o.ray = forward + u.cameraRight * (ndc.x / u.proj[0][0]) + u.cameraUp * (ndc.y / u.proj[1][1]);
    return o;
}

fragment float4 milkyway_fragment(SkyOut in [[stage_in]],
                                  constant FrameUniforms& u [[buffer(0)]],
                                  texture2d<float> sky [[texture(0)]],
                                  sampler s [[sampler(0)]]) {
    float3 d = normalize(in.ray);
    // starRotation's columns are the equatorial axes seen in the render frame.
    float3 eq = float3(dot(u.starRotation[0].xyz, d), dot(u.starRotation[1].xyz, d), dot(u.starRotation[2].xyz, d));
    float3 g = kEquatorialToGalactic * eq;
    float lon = atan2(g.y, g.x);
    float lat = asin(clamp(g.z, -1.0, 1.0));
    float2 uv = float2(0.5 - lon * (0.5 / M_PI_F), 0.5 - lat * (2.0 / M_PI_F));
    float3 c = sky.sample(s, uv, level(0.0)).rgb;
    return float4(c * u.milkyWay * u.sceneFade, 0.0);
}

// ---------------------------------------------------------------------------------------
// The Moon, to scale and at its real distance (about 60 Earth radii), tidally locked so the near
// side faces Earth, lit by the Sun with its true phase.
// ---------------------------------------------------------------------------------------

struct MoonOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float2 uv;
};

vertex MoonOut moon_vertex(uint vid [[vertex_id]],
                           const device SphereVertex* verts [[buffer(0)]],
                           constant FrameUniforms& u [[buffer(1)]],
                           constant MoonUniforms& m [[buffer(2)]]) {
    SphereVertex v = verts[vid];
    float4 world = m.model * float4(float3(v.position), 1.0);
    MoonOut o;
    o.position = u.viewProj * world;
    o.world = world.xyz;
    o.normal = (m.model * float4(float3(v.position), 0.0)).xyz;
    o.uv = float2(v.uv);
    return o;
}

fragment float4 moon_fragment(MoonOut in [[stage_in]],
                              constant FrameUniforms& u [[buffer(0)]],
                              constant MoonUniforms& m [[buffer(1)]],
                              texture2d<float> tex [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(u.cameraPos - in.world);
    float3 L = normalize(u.sunDir);
    float3 albedo = tex.sample(s, in.uv).rgb;
    float mu0 = dot(N, L);
    float mu = saturate(dot(N, V));
    // Lommel-Seeliger scattering: the regolith keeps a full Moon evenly bright out to its limb.
    float sunlit = mu0 > 0.0 ? 2.0 * mu0 / (mu0 + mu + 0.05) : 0.0;
    sunlit *= smoothstep(-0.02, 0.06, mu0);

    // Earth's shadow, cylindrical at this distance: the penumbra dims, the umbra turns copper
    // (sunlight bent through Earth's atmosphere) during a lunar eclipse.
    float along = dot(in.world, L);
    float axis = length(in.world - L * along);
    float behind = step(along, 0.0);
    float penumbra = mix(1.0, smoothstep(0.70, 1.27, axis), behind);
    float umbra = behind * (1.0 - smoothstep(0.69, 0.76, axis));
    float3 direct = albedo * sunlit * 1.1 * penumbra * (1.0 - umbra);
    float3 copper = albedo * float3(0.55, 0.17, 0.07) * 0.16 * umbra * smoothstep(0.0, 0.1, mu0 + 0.1);

    // Earthshine on the night side, strongest around new Moon when Earth is nearly full from here.
    float3 toEarth = normalize(-in.world);
    float3 earthlit = albedo * float3(0.45, 0.60, 1.0) * m.earthshine * saturate(dot(N, toEarth)) * (1.0 - smoothstep(0.0, 0.2, mu0));

    float3 color = direct + copper + earthlit;
    return float4(color * u.sceneFade, 1.0);
}

// ---------------------------------------------------------------------------------------
// Rings (quakes, embers, user location, selection) lying on the surface
// ---------------------------------------------------------------------------------------

struct RingOut {
    float4 position [[position]];
    float2 local;
    float4 color;
    float phase;
    float speed;
    float kind;
    float intensity;
    float facing;
};

vertex RingOut ring_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device RingInstance* rings [[buffer(0)]],
                           constant FrameUniforms& u [[buffer(1)]]) {
    RingInstance r = rings[iid];
    float2 c = kQuad[vid];
    float3 N = normalize(r.position);
    float3 east = tangentEast(N);
    float3 north = cross(N, east);
    float size = r.size;
    if (r.kind > 1.5) {
        // "You are here" and selection rings keep a fixed on-screen size in close-ups.
        float dist = max(length(u.cameraPos - N), 0.05);
        float pxPerUnit = 0.5 * u.viewport.y * u.proj[1][1] / dist;
        size = min(size, (r.kind > 2.5 ? 34.0 : 22.0) * u.pixelScale / pxPerUnit);
    }
    float3 world = N * 1.0018 + (east * c.x + north * c.y) * size;
    RingOut o;
    o.position = u.viewProj * float4(world, 1.0);
    o.local = c;
    o.color = r.color;
    o.phase = r.phase;
    o.speed = r.speed;
    o.kind = r.kind;
    o.intensity = r.intensity;
    o.facing = dot(N, normalize(u.cameraPos - N));
    return o;
}

fragment float4 ring_fragment(RingOut in [[stage_in]], constant FrameUniforms& u [[buffer(0)]]) {
    float r = length(in.local);
    if (r > 1.0) discard_fragment();
    float t = u.time * in.speed + in.phase;
    float3 col = in.color.rgb;
    float a = 0.0;
    int kind = int(in.kind + 0.5);
    if (kind == 0) {
        float core = smoothstep(0.13, 0.02, r) * 1.0 + exp(-r * 12.0) * 0.35;
        float ring = 0.0;
        if (in.speed > 0.0) {
            for (int k = 0; k < 3; k++) {
                float ph = fract(t + float(k) / 3.0);
                float w = 0.035 + 0.05 * ph;
                float fade = (1.0 - ph);
                ring += smoothstep(w, 0.0, abs(r - ph)) * fade * fade;
            }
        } else {
            ring = smoothstep(0.035, 0.0, abs(r - 0.6)) * 0.25;
        }
        a = core + ring * 1.4;
    } else if (kind == 1) {
        float flick = 0.7 + 0.3 * sin(u.time * 8.7 + in.phase * 40.0) * sin(u.time * 5.1 + in.phase * 17.0);
        a = (exp(-r * 5.5) * 1.1 + smoothstep(0.22, 0.0, r) * 1.6) * flick;
    } else if (kind == 2) {
        float ph = fract(t);
        a = smoothstep(0.24, 0.16, r) * 1.6 + smoothstep(0.05, 0.0, abs(r - ph)) * (1.0 - ph) * 1.2 + exp(-r * 4.0) * 0.25;
        col = mix(col, float3(1.0), smoothstep(0.12, 0.02, r));
    } else {
        float ang = atan2(in.local.y, in.local.x) + u.time * 0.9;
        float dashes = step(0.45, fract(ang / 6.2831853 * 8.0));
        a = smoothstep(0.045, 0.0, abs(r - 0.84)) * (0.35 + 0.65 * dashes) + smoothstep(0.025, 0.0, abs(r - 0.97)) * 0.6;
    }
    float limb = smoothstep(-0.02, 0.28, in.facing);
    return float4(col * a * in.intensity * limb * u.markerFade * u.sceneFade, 0.0);
}

// ---------------------------------------------------------------------------------------
// Icons (storms, volcanoes, launches...) as camera-facing billboards
// ---------------------------------------------------------------------------------------

struct IconOut {
    float4 position [[position]];
    float2 local;
    float2 glyphUV;
    float4 color;
    float emphasis;
    float facing;
};

constant float kAtlasCells = 12.0;

vertex IconOut icon_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device IconInstance* icons [[buffer(0)]],
                           constant FrameUniforms& u [[buffer(1)]]) {
    IconInstance ic = icons[iid];
    float2 c = kQuad[vid];
    float3 N = normalize(ic.position);
    float3 world = N * (1.0 + ic.altitude);
    float4 clip = u.viewProj * float4(world, 1.0);
    float sizePx = ic.sizePx * u.pixelScale * (1.0 + ic.emphasis * 0.3);
    clip.xy += c * sizePx / u.viewport * clip.w;
    float ang = u.time * ic.rotationSpeed;
    float2 rc = float2(c.x * cos(ang) - c.y * sin(ang), c.x * sin(ang) + c.y * cos(ang));
    float2 g = rc * 0.62;
    IconOut o;
    o.position = clip;
    o.local = c;
    o.glyphUV = float2((ic.atlasIndex + g.x * 0.5 + 0.5) / kAtlasCells, 0.5 - g.y * 0.5);
    o.color = ic.color;
    o.emphasis = ic.emphasis;
    o.facing = dot(N, normalize(u.cameraPos - world));
    return o;
}

fragment float4 icon_fragment(IconOut in [[stage_in]],
                              constant FrameUniforms& u [[buffer(0)]],
                              texture2d<float> atlas [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    float r = length(in.local);
    if (r > 1.0) discard_fragment();
    float plate = smoothstep(1.0, 0.9, r);
    float rim = smoothstep(0.07, 0.0, abs(r - 0.88));
    float inside = step(abs(in.glyphUV.y - 0.5), 0.5);
    float glyph = atlas.sample(s, in.glyphUV).r * inside * step(r, 0.86);
    float3 base = float3(0.015, 0.02, 0.035);
    float3 col = mix(base, in.color.rgb * 1.05, glyph) + in.color.rgb * rim * (0.55 + in.emphasis * 0.9);
    float alpha = max(plate * 0.86, glyph);
    float limb = smoothstep(0.0, 0.22, in.facing);
    alpha *= limb * u.markerFade * u.sceneFade;
    return float4(col * alpha, alpha);
}

// ---------------------------------------------------------------------------------------
// Tropical cyclones: a procedural cloud spiral lying on the globe, lit by the Sun
// ---------------------------------------------------------------------------------------

struct StormOut {
    float4 position [[position]];
    float2 local;
    float strength;
    float hemi;
    float phase;
    float emphasis;
    float lit;
    float facing;
};

vertex StormOut storm_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             const device StormInstance* storms [[buffer(0)]],
                             constant FrameUniforms& u [[buffer(1)]]) {
    StormInstance s = storms[iid];
    float2 c = kQuad[vid];
    float3 N = normalize(s.position);
    float3 east = tangentEast(N);
    float3 north = cross(N, east);
    // Stay readable from orbit: never smaller than ~20 points across on screen.
    float dist = max(length(u.cameraPos - N), 0.05);
    float pxPerUnit = 0.5 * u.viewport.y * u.proj[1][1] / dist;
    float radius = max(s.radius, 20.0 * u.pixelScale / pxPerUnit) * (1.0 + s.emphasis * 0.08);
    float3 world = N * 1.004 + (east * c.x + north * c.y) * radius;
    StormOut o;
    o.position = u.viewProj * float4(world, 1.0);
    o.local = c;
    o.strength = s.strength;
    o.hemi = s.hemisphere;
    o.phase = s.phase;
    o.emphasis = s.emphasis;
    o.lit = dot(N, u.sunDir);
    o.facing = dot(N, normalize(u.cameraPos - N));
    return o;
}

static float3 stormCategoryColor(float s) {
    // Tropical storm cyan → category 1 yellow → 3 orange → 5 magenta.
    float3 c = mix(float3(0.35, 0.85, 1.0), float3(1.0, 0.9, 0.35), smoothstep(0.15, 0.4, s));
    c = mix(c, float3(1.0, 0.5, 0.2), smoothstep(0.45, 0.7, s));
    return mix(c, float3(1.0, 0.3, 0.75), smoothstep(0.75, 1.0, s));
}

fragment float4 storm_fragment(StormOut in [[stage_in]], constant FrameUniforms& u [[buffer(0)]]) {
    float r = length(in.local);
    if (r > 1.0) discard_fragment();
    float theta = atan2(in.local.y, in.local.x);
    float h = in.hemi;
    float t = u.time + in.phase * 40.0;
    float omega = 0.22 + 0.18 * in.strength;

    // Trailing logarithmic spiral bands, mirrored south of the equator.
    float phi = h * theta + 2.3 * log(r + 0.04) - omega * t;
    float bands = pow(0.5 + 0.5 * cos(3.0 * phi), 1.6);

    // Cloud texture turning with the storm.
    float a = -h * omega * t * 0.6;
    float2 q = float2(in.local.x * cos(a) - in.local.y * sin(a), in.local.x * sin(a) + in.local.y * cos(a));
    float n = fbm(q * 5.5 + in.phase * 13.0);
    float fine = fbm(q * 14.0 + 3.7);

    float eye = mix(0.10, 0.045, in.strength);
    float eyewall = smoothstep(eye, eye + 0.035, r) * smoothstep(eye + 0.24, eye + 0.06, r);
    float core = smoothstep(0.55, 0.12, r) * (0.55 + 0.45 * in.strength);
    float arms = bands * smoothstep(1.0, 0.3, r) * smoothstep(0.06, 0.22, r);
    float density = max(eyewall, core * 0.85 + arms * 0.75);
    density *= 0.7 + 0.45 * n + 0.15 * fine;
    density *= smoothstep(eye * 0.6, eye, r) * smoothstep(1.0, 0.82, r);
    density = saturate(density);

    // Sunlit white tops; deep blue-grey on the night side.
    float day = smoothstep(-0.12, 0.3, in.lit);
    float shade = 0.78 + 0.22 * bands;
    // Night tops stay faintly visible, as in infrared imagery, and hide the city lights below.
    float3 cloud = mix(float3(0.10, 0.12, 0.18), float3(0.96, 0.97, 1.0), day) * shade * (0.88 + 0.12 * fine);

    // A thin category-coloured glow on the eyewall keeps storms legible day and night.
    float3 cat = stormCategoryColor(in.strength);
    float rim = smoothstep(0.035, 0.0, abs(r - (eye + 0.05))) * (0.35 + 0.9 * in.emphasis);
    float halo = smoothstep(1.0, 0.0, r) * 0.05 * (1.0 - day);

    float vis = smoothstep(0.0, 0.18, in.facing) * u.markerFade * u.sceneFade;
    float alpha = density * 0.92 * vis;
    float3 emissive = cat * (rim + halo) * vis;
    return float4(cloud * alpha + emissive, alpha);
}

// ---------------------------------------------------------------------------------------
// Satellites (points interpolated between two propagated keyframes)
// ---------------------------------------------------------------------------------------

struct PointOut {
    float4 position [[position]];
    float2 local;
    float4 color;
};

vertex PointOut satellite_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device float4* prev [[buffer(0)]],
                                 const device float4* next [[buffer(1)]],
                                 constant FrameUniforms& u [[buffer(2)]],
                                 constant PointInstance& style [[buffer(3)]]) {
    float4 a = prev[iid];
    float4 b = next[iid];
    float3 p = mix(a.xyz, b.xyz, u.satelliteLerp);
    float lit = mix(a.w, b.w, u.satelliteLerp);
    float4 clip = u.viewProj * float4(p, 1.0);
    float2 c = kQuad[vid];
    float size = style.sizePx * u.pixelScale;
    clip.xy += c * size / u.viewport * clip.w;
    PointOut o;
    o.position = clip;
    o.local = c;
    o.color = style.color * mix(0.22, 1.0, lit);
    return o;
}

fragment float4 satellite_fragment(PointOut in [[stage_in]], constant FrameUniforms& u [[buffer(0)]]) {
    float r = length(in.local);
    if (r > 1.0) discard_fragment();
    float a = exp(-r * r * 6.0) + smoothstep(0.35, 0.1, r) * 0.8;
    return float4(in.color.rgb * a * in.color.a * u.markerFade * u.sceneFade, 0.0);
}

vertex PointOut point_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             const device PointInstance* pts [[buffer(0)]],
                             constant FrameUniforms& u [[buffer(1)]]) {
    PointInstance pi = pts[iid];
    float4 clip = u.viewProj * float4(pi.position, 1.0);
    float2 c = kQuad[vid];
    clip.xy += c * pi.sizePx * u.pixelScale / u.viewport * clip.w;
    PointOut o;
    o.position = clip;
    o.local = c;
    o.color = pi.color;
    return o;
}

// ---------------------------------------------------------------------------------------
// Paths (orbits, storm tracks) drawn as screen-space ribbons
// ---------------------------------------------------------------------------------------

struct PathOut {
    float4 position [[position]];
    float across;
    float alpha;
    float along;
};

vertex PathOut path_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device PathVertex* pts [[buffer(0)]],
                           constant FrameUniforms& u [[buffer(1)]],
                           constant PathStyle& style [[buffer(2)]]) {
    PathVertex a = pts[iid];
    PathVertex b = pts[iid + 1];
    float4 ca = u.viewProj * float4(a.position, 1.0);
    float4 cb = u.viewProj * float4(b.position, 1.0);
    PathOut o;
    if (ca.w < 0.01 || cb.w < 0.01 || a.alpha < 0.0 || b.alpha < 0.0) {
        o.position = float4(0, 0, -2, 1);
        o.across = 0; o.alpha = 0; o.along = 0;
        return o;
    }
    float2 halfVP = u.viewport * 0.5;
    float2 sa = ca.xy / ca.w * halfVP;
    float2 sb = cb.xy / cb.w * halfVP;
    float2 d = sb - sa;
    float len = max(length(d), 1e-4);
    float2 dir = d / len;
    float2 nrm = float2(-dir.y, dir.x);
    bool isB = vid >= 2;
    float side = (vid % 2 == 0) ? -1.0 : 1.0;
    float4 c = isB ? cb : ca;
    float w = style.widthPx * u.pixelScale * (1.0 + style.glow * 2.5) * 0.5;
    c.xy += nrm * side * w / halfVP * c.w;
    o.position = c;
    o.across = side;
    o.alpha = isB ? b.alpha : a.alpha;
    o.along = float(iid) + (isB ? 1.0 : 0.0);
    return o;
}

fragment float4 path_fragment(PathOut in [[stage_in]],
                              constant FrameUniforms& u [[buffer(0)]],
                              constant PathStyle& style [[buffer(1)]]) {
    float x = abs(in.across);
    float coreWidth = 1.0 / (1.0 + style.glow * 2.5);
    float core = smoothstep(coreWidth, coreWidth * 0.4, x);
    float glow = exp(-x * x * 4.0) * style.glow;
    float dash = style.dash > 0.0 ? step(0.5, fract(in.along / style.dash - u.time * 0.6)) * 0.7 + 0.3 : 1.0;
    float a = (core + glow * 0.6) * in.alpha * dash * style.color.a;
    return float4(style.color.rgb * a * u.markerFade * u.sceneFade, 0.0);
}

// ---------------------------------------------------------------------------------------
// Wind: a particle swarm advected through the GFS 10 m wind on the GPU, each particle
// trailing a ribbon of its recent positions (recorded 30 times a second).
// ---------------------------------------------------------------------------------------

static uint pcgHash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

static float rand01(uint a, uint b) {
    return float(pcgHash(a ^ pcgHash(b)) & 0x00FFFFFFu) / 16777216.0;
}

static float2 windAt(texture2d_array<float> wx, sampler s, float3 P, constant WindParams& p) {
    return decodeWind(sampleWeather(wx, s, weatherUVAt(P), p.slice, p.slices));
}

kernel void wind_step(uint id [[thread_position_in_grid]],
                      device WindParticle* particles [[buffer(0)]],
                      device float4* trail [[buffer(1)]],
                      constant WindParams& p [[buffer(2)]],
                      texture2d_array<float> wx [[texture(0)]],
                      sampler ws [[sampler(0)]]) {
    if (id >= p.count) return;
    WindParticle pt = particles[id];
    float3 P = pt.position;
    uint base = id * p.trailLength;
    bool spawn = pt.age >= pt.life || length_squared(P) < 0.25 || dot(P, p.cap.xyz) < p.cap.w - 0.03;
    if (spawn) {
        // Uniform over the visible cap: cos(angle from its centre) uniform down to the edge.
        uint key = id * 3u + p.seed * 7919u;
        float cosT = mix(1.0, p.cap.w, rand01(key, 1u));
        float sinT = sqrt(max(0.0, 1.0 - cosT * cosT));
        float phi = rand01(key, 2u) * 6.2831853;
        float3 c = p.cap.xyz;
        float3 e = tangentEast(c);
        float3 n = cross(c, e);
        P = normalize(c * cosT + (e * cos(phi) + n * sin(phi)) * sinT);
        pt.age = 0.0;
        pt.life = p.maxAge * (0.45 + 0.9 * rand01(key, 3u));
        pt.speed = length(windAt(wx, ws, P, p));
        for (uint k = 0u; k < p.trailLength; k++) trail[base + k] = float4(P, pt.speed);
    } else {
        // Midpoint (RK2) step along the flow on the sphere.
        float k = p.speedScale * p.dt;
        float2 w1 = windAt(wx, ws, P, p);
        float3 e1 = tangentEast(P);
        float3 mid = normalize(P + (e1 * w1.x + cross(P, e1) * w1.y) * (0.5 * k));
        float2 w2 = windAt(wx, ws, mid, p);
        float3 e2 = tangentEast(mid);
        P = normalize(P + (e2 * w2.x + cross(mid, e2) * w2.y) * k);
        pt.speed = length(w2);
        // Calm air recycles sooner, so the swarm gathers where the wind blows.
        pt.age += p.dt * (pt.speed < 1.0 ? 3.0 : 1.0);
    }
    pt.position = P;
    particles[id] = pt;
    if (p.record != 0u) trail[base + p.head] = float4(P, pt.speed);
}

struct WindOut {
    float4 position [[position]];
    float across;
    float alpha;
    float speed;
};

/// Point k of a particle's trail: 0 is the live head, then the recorded ring, newest first.
static float4 windTrailPoint(const device WindParticle* particles, const device float4* trail,
                             constant WindParams& p, uint iid, uint k) {
    if (k == 0u) return float4(particles[iid].position, particles[iid].speed);
    uint K = p.trailLength;
    return trail[iid * K + (p.head + K - (k - 1u)) % K];
}

vertex WindOut wind_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device WindParticle* particles [[buffer(0)]],
                           const device float4* trail [[buffer(1)]],
                           constant FrameUniforms& u [[buffer(2)]],
                           constant WindParams& p [[buffer(3)]]) {
    uint last = p.trailLength;               // points 0…trailLength
    uint k = vid >> 1;
    float side = (vid & 1u) != 0u ? 1.0 : -1.0;
    float4 here = windTrailPoint(particles, trail, p, iid, k);
    float4 ahead = windTrailPoint(particles, trail, p, iid, k > 0u ? k - 1u : 0u);
    float4 behind = windTrailPoint(particles, trail, p, iid, min(k + 1u, last));
    const float lift = 1.003;
    float4 cp = u.viewProj * float4(here.xyz * lift, 1.0);
    float4 ca = u.viewProj * float4(ahead.xyz * lift, 1.0);
    float4 cb = u.viewProj * float4(behind.xyz * lift, 1.0);
    WindOut o;
    if (cp.w < 0.01 || ca.w < 0.01 || cb.w < 0.01) {
        o.position = float4(0.0, 0.0, -2.0, 1.0);
        o.across = 0.0; o.alpha = 0.0; o.speed = 0.0;
        return o;
    }
    float2 halfVP = u.viewport * 0.5;
    float2 d = ca.xy / ca.w * halfVP - cb.xy / cb.w * halfVP;
    float len = length(d);
    float2 dir = len > 1e-3 ? d / len : float2(1.0, 0.0);
    float2 nrm = float2(-dir.y, dir.x);
    float f = float(k) / float(last);         // 0 head … 1 tail
    float width = p.widthPx * u.pixelScale * mix(1.0, 0.35, f);
    cp.xy += nrm * side * width * 0.5 / halfVP * cp.w;
    WindParticle pt = particles[iid];
    float life = smoothstep(0.0, 0.5, pt.age) * (1.0 - smoothstep(pt.life - 0.9, pt.life, pt.age));
    float3 N = normalize(here.xyz);
    float facing = dot(N, normalize(u.cameraPos - N));
    float calm = 0.22 + 0.78 * smoothstep(0.6, 5.0, here.w);
    float night = 1.0 - smoothstep(-0.15, 0.25, dot(N, u.sunDir));
    o.position = cp;
    o.across = side;
    o.alpha = pow(1.0 - f, 1.5) * life * calm * smoothstep(0.0, 0.22, facing) * mix(0.85, 1.2, night);
    o.speed = here.w;
    return o;
}

static float3 windColor(float ms) {
    float3 c = mix(float3(0.30, 0.52, 1.0), float3(0.80, 0.93, 1.0), smoothstep(1.0, 7.0, ms));
    c = mix(c, float3(1.0, 0.92, 0.62), smoothstep(8.0, 14.0, ms));
    c = mix(c, float3(1.0, 0.58, 0.22) * 1.25, smoothstep(14.0, 20.0, ms));
    return mix(c, float3(1.0, 0.28, 0.58) * 1.5, smoothstep(20.0, 30.0, ms));
}

fragment float4 wind_fragment(WindOut in [[stage_in]],
                              constant FrameUniforms& u [[buffer(0)]],
                              constant WindParams& p [[buffer(1)]]) {
    float edge = 1.0 - smoothstep(0.35, 1.0, abs(in.across));
    float a = in.alpha * edge * p.intensity * u.markerFade * u.sceneFade;
    return float4(windColor(in.speed) * a, 0.0);
}

// ---------------------------------------------------------------------------------------
// Post-processing: bloom (dual filter), lens flare, tone mapping, grading
// ---------------------------------------------------------------------------------------

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FullscreenOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static float3 downsample13(texture2d<float> t, sampler s, float2 uv, float2 texel) {
    float3 a = t.sample(s, uv + texel * float2(-2, -2)).rgb;
    float3 b = t.sample(s, uv + texel * float2( 0, -2)).rgb;
    float3 c = t.sample(s, uv + texel * float2( 2, -2)).rgb;
    float3 d = t.sample(s, uv + texel * float2(-2,  0)).rgb;
    float3 e = t.sample(s, uv).rgb;
    float3 f = t.sample(s, uv + texel * float2( 2,  0)).rgb;
    float3 g = t.sample(s, uv + texel * float2(-2,  2)).rgb;
    float3 h = t.sample(s, uv + texel * float2( 0,  2)).rgb;
    float3 i = t.sample(s, uv + texel * float2( 2,  2)).rgb;
    float3 j = t.sample(s, uv + texel * float2(-1, -1)).rgb;
    float3 k = t.sample(s, uv + texel * float2( 1, -1)).rgb;
    float3 l = t.sample(s, uv + texel * float2(-1,  1)).rgb;
    float3 m = t.sample(s, uv + texel * float2( 1,  1)).rgb;
    float3 r = e * 0.125;
    r += (a + c + g + i) * 0.03125;
    r += (b + d + f + h) * 0.0625;
    r += (j + k + l + m) * 0.125;
    return r;
}

fragment float4 bloom_prefilter(FullscreenOut in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                sampler s [[sampler(0)]],
                                constant float& threshold [[buffer(0)]]) {
    float2 texel = 1.0 / float2(src.get_width(), src.get_height());
    float3 c = downsample13(src, s, in.uv, texel);
    float br = max(c.r, max(c.g, c.b));
    float knee = threshold * 0.6;
    float soft = clamp(br - threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float contrib = max(soft, br - threshold) / max(br, 1e-4);
    return float4(min(c * contrib, float3(64.0)), 1.0);
}

fragment float4 bloom_downsample(FullscreenOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 sampler s [[sampler(0)]]) {
    float2 texel = 1.0 / float2(src.get_width(), src.get_height());
    return float4(downsample13(src, s, in.uv, texel), 1.0);
}

fragment float4 bloom_upsample(FullscreenOut in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               sampler s [[sampler(0)]],
                               constant float& radius [[buffer(0)]]) {
    float2 texel = radius / float2(src.get_width(), src.get_height());
    float3 r = src.sample(s, in.uv).rgb * 4.0;
    r += src.sample(s, in.uv + texel * float2(-1, 0)).rgb * 2.0;
    r += src.sample(s, in.uv + texel * float2( 1, 0)).rgb * 2.0;
    r += src.sample(s, in.uv + texel * float2( 0, -1)).rgb * 2.0;
    r += src.sample(s, in.uv + texel * float2( 0,  1)).rgb * 2.0;
    r += src.sample(s, in.uv + texel * float2(-1, -1)).rgb;
    r += src.sample(s, in.uv + texel * float2( 1, -1)).rgb;
    r += src.sample(s, in.uv + texel * float2(-1,  1)).rgb;
    r += src.sample(s, in.uv + texel * float2( 1,  1)).rgb;
    return float4(r / 16.0, 1.0);
}

static float3 acesFilm(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

fragment float4 composite_fragment(FullscreenOut in [[stage_in]],
                                   texture2d<float> hdr [[texture(0)]],
                                   texture2d<float> bloom [[texture(1)]],
                                   texture2d<float> bloomWide [[texture(2)]],
                                   sampler s [[sampler(0)]],
                                   constant PostUniforms& p [[buffer(0)]]) {
    float2 uv = in.uv;
    float3 scene = hdr.sample(s, uv).rgb;
    float3 b1 = bloom.sample(s, uv).rgb;
    float3 b2 = bloomWide.sample(s, uv).rgb;
    float3 color = scene + (b1 * 0.85 + b2 * 0.6) * p.bloomStrength;

    // Lens flare: ghosts mirrored through the centre plus an anamorphic streak.
    if (p.sunVisible > 0.001) {
        float2 sunUV = float2(p.sunScreen.x * 0.5 + 0.5, 0.5 - p.sunScreen.y * 0.5);
        float2 toCenter = float2(0.5) - sunUV;
        float3 flare = float3(0.0);
        const float ghostPos[5] = { 0.35, 0.62, 0.9, 1.25, 1.6 };
        const float3 ghostTint[5] = { float3(0.5, 0.8, 1.0), float3(1.0, 0.6, 0.3), float3(0.4, 1.0, 0.6), float3(0.8, 0.5, 1.0), float3(1.0, 0.85, 0.5) };
        for (int i = 0; i < 5; i++) {
            float2 gp = sunUV + toCenter * ghostPos[i] * 2.0;
            float2 d = (uv - gp) * float2(p.aspect, 1.0);
            float size = 0.02 + 0.025 * float(i % 3);
            float g = smoothstep(size, size * 0.55, length(d)) * 0.018 + exp(-length(d) / size * 3.5) * 0.012;
            flare += ghostTint[i] * g;
        }
        float dy = (uv.y - sunUV.y);
        float streak = exp(-dy * dy * 14000.0) * exp(-abs(uv.x - sunUV.x) * 3.2) * 0.45;
        float2 ds = (uv - sunUV) * float2(p.aspect, 1.0);
        float halo = smoothstep(0.010, 0.0, abs(length(ds) - 0.32)) * 0.02;
        color += (flare + float3(0.85, 0.9, 1.0) * streak + float3(0.7, 0.85, 1.0) * halo) * p.sunVisible * p.flareStrength;
    }

    color *= p.exposure;
    color = acesFilm(color);
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(float3(luma), color, p.saturation);

    float2 vd = (uv - 0.5) * float2(p.aspect, 1.0);
    float vig = 1.0 - p.vignette * smoothstep(0.35, 1.15, length(vd) * 1.35);
    color *= vig;

    float n = hash21(uv * 1000.0 + fract(p.time * 13.0) * 100.0) - 0.5;
    color += n * p.grain;
    return float4(saturate(color) * p.fade, 1.0);
}
