#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// Shared between Swift (via the bridging header) and the Metal shaders.

typedef struct {
    simd_float4x4 viewProj;
    simd_float4x4 view;
    simd_float4x4 proj;
    simd_float4x4 starRotation;   // ECI -> render frame, includes GMST
    simd_float3 cameraPos;
    float time;
    simd_float3 sunDir;
    float exposure;
    simd_float3 cameraRight;
    float cloudOpacity;
    simd_float3 cameraUp;
    float cityLights;
    simd_float2 viewport;         // drawable size in pixels
    float liveImagery;            // 0 = Blue Marble, 1 = today's NASA mosaic
    float auroraIntensity;
    float sceneFade;              // global fade used by the intro
    float pixelScale;             // contentScaleFactor
    float cloudDrift;             // texture-space drift of the cloud layer
    float starIntensity;
    float satelliteLerp;          // 0..1 between the previous and next satellite keyframe
    float markerFade;             // fades all markers in/out
    float atmosphereIntensity;
    float reliefStrength;
    simd_float4 detailBounds;     // regional 500 m imagery: west lon, north lat, lon span, lat span (deg)
    float detailBlend;            // 0 = base texture only
    float detailNight;            // 1 when the detail texture's alpha carries city lights
    float weatherSlice;           // fractional index into the GFS frames (time-interpolated)
    float weatherSlices;          // number of GFS frames bound (0 = none yet)
    float temperatureOverlay;     // 0..1 opacity of the 2 m temperature map
    float rainOverlay;            // 0..1 opacity of the precipitation map
} FrameUniforms;

typedef struct {
    simd_float3 position;         // unit vector on the globe (render frame)
    float size;                   // radius in globe units
    simd_float4 color;            // linear RGB + alpha
    float phase;                  // animation offset
    float speed;                  // pulse speed (cycles per second); 0 = static
    float kind;                   // 0 quake ring, 1 ember, 2 user location, 3 selection
    float intensity;
} RingInstance;

typedef struct {
    simd_float3 position;         // unit vector on the globe
    float sizePx;                 // icon size in points
    simd_float4 color;            // tint
    float atlasIndex;             // cell in the icon atlas
    float rotationSpeed;          // radians per second (storms spin)
    float altitude;               // lift above the surface
    float emphasis;               // 0..1 selection highlight
} IconInstance;

typedef struct {
    simd_float3 position;         // unit vector at the storm's centre
    float radius;                 // cloud-shield radius in globe units
    float strength;               // 0 tropical depression … 1 category 5
    float hemisphere;             // +1 north (spins counter-clockwise), -1 south
    float phase;                  // per-storm animation offset
    float emphasis;               // 0..1 selection highlight
} StormInstance;

typedef struct {
    simd_float3 position;         // render-frame position (globe units)
    float sizePx;
    simd_float4 color;
} PointInstance;

typedef struct {
    simd_float3 position;
    float alpha;
} PathVertex;

typedef struct {
    simd_float4 color;
    float widthPx;
    float glow;
    float dash;                   // 0 = solid
    float pad;
} PathStyle;

// Wind particles: a GPU-advected swarm, each with a ring of recent positions drawn as a ribbon.
typedef struct {
    simd_float4 cap;              // xyz: centre of the visible region (unit vector), w: cos of its angular radius
    float dt;                     // seconds since the previous step
    float speedScale;             // radians travelled per (m/s · s)
    float slice;                  // fractional index into the GFS frames
    float slices;                 // number of frames
    unsigned int count;           // particles
    unsigned int trailLength;     // recorded positions per particle
    unsigned int head;            // ring slot holding the newest recorded position
    unsigned int record;          // 1 when this step writes the ring
    unsigned int seed;            // changes every step
    float maxAge;                 // seconds
    float intensity;              // overall brightness (0 hides)
    float widthPx;                // ribbon width at the head, in points
} WindParams;

typedef struct {
    simd_float3 position;         // unit vector (render frame)
    float age;                    // seconds
    float life;                   // seconds
    float speed;                  // m/s at the head
    float pad0;
    float pad1;
} WindParticle;

typedef struct {
    simd_float2 sunScreen;        // normalized device coordinates
    float sunVisible;             // 0..1 (occlusion and on-screen)
    float bloomStrength;
    float vignette;
    float grain;
    float time;
    float exposure;
    float flareStrength;
    float aspect;
    float saturation;
    float fade;
} PostUniforms;

#endif /* ShaderTypes_h */
