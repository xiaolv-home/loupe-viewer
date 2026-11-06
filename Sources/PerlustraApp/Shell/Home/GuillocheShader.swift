/// The start page's engraving and the loupe that examines it. Compiled when the app runs, since the
/// command line tools have no Metal compiler.
///
/// The lines are a guilloché, the fine interwoven pattern engraved on banknotes, and like a banknote's
/// they are microprinting: through the lens each hairline turns out to be a line of words. The curves
/// are drawn as real geometry from one function, so the loupe sees the same lines the page shows.
enum GuillocheShader {
    static let source = #"""
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float4 frame;   // width, height, points to pixels, 1 on black
            float4 lens;    // x, y, radius, how present it is
            float4 motion;  // how far the engraving has run, how much the loupe parts the lines, spread when a file is dragged over, where the title ends
            float4 lines;   // number of lines, segments per line on the page, segments through the lens, atlas width over height
        };

        constant float TAU = 6.2831853;
        constant float MAGNIFY = 8.5;
        constant float WORDS_HEIGHT = 8.6;  // points, as seen through the lens

        /// The height of a line at a place. `t` runs across the family of lines, 0 to 1.
        static float curve(float x, float t, constant Uniforms& u) {
            const float w = max(u.frame.x, 1.0), h = u.frame.y;
            const float X = x / w;
            const float wide = 1 + u.motion.z * 0.32;
            float y = h * 0.52;
            y += h * 0.24 * sin(TAU * (0.70 * X + 0.06) + t * 2.5);
            y += h * 0.11 * sin(TAU * (1.62 * X + 0.34) - t * 3.8);
            y += h * (t - 0.5) * 0.46 * wide * sin(TAU * (0.58 * X + 0.13));
            // The loupe parts the lines around it, like a finger drawn through silk.
            const float2 away = float2(x, y) - u.lens.xy;
            const float reach = u.lens.z * 1.7;
            y += away.y * u.motion.y * 0.62 * exp(-dot(away, away) / (2 * reach * reach));
            return y;
        }

        struct LineVertex {
            float4 position [[position]];
            float2 point;
            float across;    // -1 to 1 over the drawn width
            float halfWidth; // points, the ink's own half width
            float along;     // points along the line
            float seed;
            float t;
            float x;
        };

        /// `mode` 0 draws the page; 1 draws the same lines as seen through the lens.
        vertex LineVertex lineVertex(uint id [[vertex_id]], uint line [[instance_id]], constant Uniforms& u [[buffer(0)]], constant int& mode [[buffer(1)]]) {
            const float t = float(line) / max(u.lines.x - 1, 1.0);
            const float segments = mode == 0 ? u.lines.y : u.lines.z;
            const float s = float(id / 2) / segments;
            const float side = (id & 1) == 0 ? -1 : 1;
            const float pixel = 1 / u.frame.z;
            const float span = u.lens.z / MAGNIFY * 1.4;
            const float x = mode == 0 ? -8 + s * (u.frame.x + 16) : u.lens.x + (s * 2 - 1) * span;
            const float y = curve(x, t, u);
            const float dy = curve(x + 0.5, t, u) - curve(x - 0.5, t, u);
            float2 normal = normalize(float2(-dy, 1));

            LineVertex v;
            v.seed = fract(float(line) * 0.61803);
            v.t = t;
            v.x = x;
            v.along = x * sqrt(1 + dy * dy * 0.5);
            float2 at;
            if (mode == 0) {
                // Engraver's swell: each line thickens and thins along its length.
                v.halfWidth = 0.30 * (0.72 + 0.46 * sin(x * 0.021 + t * 9.0));
                const float drawn = v.halfWidth + pixel;
                at = float2(x, y) + normal * side * drawn;
                v.across = side * drawn;
            } else {
                v.halfWidth = WORDS_HEIGHT * 0.5;
                // Pincushion, as through a simple lens.
                const float2 paper = float2(x, y) - u.lens.xy;
                const float2 seen = paper * MAGNIFY;
                const float q = length(seen) / u.lens.z;
                at = u.lens.xy + seen * (1 + 0.10 * q * q) + normal * side * v.halfWidth;
                v.across = side;
            }
            v.point = at;
            v.position = float4(at.x / u.frame.x * 2 - 1, 1 - at.y / u.frame.y * 2, 0, 1);
            return v;
        }

        static float3 inkColor(float X, float t, bool black) {
            const float place = saturate(X * 1.25 + (t - 0.5) * 0.62 - 0.12);
            if (black) {
                const float3 indigo = float3(0.34, 0.31, 1.00), ember = float3(1.00, 0.36, 0.11), gold = float3(1.00, 0.76, 0.38);
                return place < 0.62 ? mix(indigo, ember, smoothstep(0.08, 0.62, place)) : mix(ember, gold, smoothstep(0.62, 1.0, place));
            }
            const float3 indigo = float3(0.13, 0.17, 0.56), ember = float3(0.85, 0.24, 0.07);
            return mix(indigo, ember, smoothstep(0.12, 0.86, place));
        }

        fragment float4 linePage(LineVertex in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
            const bool black = u.frame.w > 0.5;
            const float pixel = 1 / u.frame.z;
            const float X = in.x / u.frame.x;
            const float ink = saturate((in.halfWidth + pixel * 0.5 - abs(in.across)) / pixel);

            // The engraving runs in once, from the left, each line a little behind the last.
            const float front = u.motion.x * 1.35 - in.seed * 0.12;
            const float run = smoothstep(0.0, 0.05, front - X);
            // Quiet behind the title and at the top and bottom of the band.
            const float clear = pow(smoothstep(u.motion.w - 30, u.motion.w + 240, in.x), 1.4);
            const float edge = smoothstep(0.0, 26.0, in.point.y) * smoothstep(0.0, 26.0, u.frame.y - in.point.y);
            const float strength = (black ? 0.84 : 0.72) * ink * run * clear * edge;
            const float3 color = inkColor(X, in.t, black);
            // Light adds up where lines cross, on black; ink builds up, on paper.
            return float4(color * strength, black ? strength * 0.25 : strength);
        }

        fragment float4 lineLens(LineVertex in [[stage_in]], constant Uniforms& u [[buffer(0)]], texture2d<float> words [[texture(0)]]) {
            const float reach = length(in.point - u.lens.xy);
            if (reach > u.lens.z) discard_fragment();
            const bool black = u.frame.w > 0.5;
            constexpr sampler wrap(address::repeat, filter::linear);
            const float stripLength = WORDS_HEIGHT * u.lines.w;
            const float start = in.seed * 37.0;
            const float2 at = float2(in.along * MAGNIFY / stripLength + start, in.across * 0.5 + 0.5);
            const float ink = words.sample(wrap, at).r;
            const float strength = ink * u.lens.w * (black ? 0.96 : 0.92);
            const float3 color = inkColor(in.x / u.frame.x, in.t, black);
            return float4(color * strength, strength);
        }

        struct Whole { float4 position [[position]]; float2 point; };

        vertex Whole wholeVertex(uint id [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
            const float2 q = float2((id << 1) & 2, id & 2);
            Whole v;
            v.position = float4(q * 2 - 1, 0, 1);
            v.point = float2(q.x, 1 - q.y) * u.frame.xy;
            return v;
        }

        constant float RING = 3.0;

        /// Below the magnified lines: the lens's shadow on the sheet and its glass.
        fragment float4 lensUnder(Whole in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
            const bool black = u.frame.w > 0.5;
            const float2 toLens = in.point - u.lens.xy;
            const float reach = length(toLens);
            const float presence = u.lens.w;
            if (reach < u.lens.z) {
                const float3 glass = black ? float3(0.070, 0.070, 0.080) : float3(0.945, 0.938, 0.915);
                return float4(glass * presence, presence);
            }
            const float fall = length(toLens - float2(2, 4)) - u.lens.z - RING;
            const float shade = (black ? 0.55 : 0.20) * presence * exp(-max(fall, 0.0) / 7.0);
            return float4(0, 0, 0, shade);
        }

        /// Above the magnified lines: everything that belongs to the instrument.
        fragment float4 lensOver(Whole in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
            const bool black = u.frame.w > 0.5;
            const float pixel = 1 / u.frame.z;
            const float2 toLens = in.point - u.lens.xy;
            const float reach = length(toLens);
            const float radius = u.lens.z;
            const float rel = reach / radius;
            const float presence = u.lens.w;
            const float angle = atan2(toLens.y, toLens.x);
            float4 color = float4(0);

            if (rel < 1) {
                const float falloff = pow(rel, 14.0) * (black ? 0.5 : 0.16);
                color = float4(0, 0, 0, falloff);

                // One thin reflection along the rim; the glass itself stays flat and clear.
                const float along = exp(-pow((angle + 2.25) / 0.62, 2.0));
                const float gleam = along * smoothstep(0.93, 0.97, rel) * smoothstep(1.0, 0.98, rel) * (black ? 0.34 : 0.55);
                color = color * (1 - gleam) + float4(gleam);
            } else if (reach < radius + RING + 1) {
                // The metal bezel, its brightness turning with the angle like a lathed ring.
                const float depth = reach - radius;
                const float sweep = 0.5 + 0.5 * cos(2 * (angle + 0.82));
                float metal = mix(black ? 0.20 : 0.30, black ? 0.78 : 0.86, pow(sweep, 2.0));
                metal = mix(metal, 0.05, smoothstep(0.8, 0.1, depth));
                const float coverage = smoothstep(RING + pixel * 0.7, RING - pixel * 0.7, depth);
                color = float4(float3(1.0, 0.985, 0.955) * metal * coverage, coverage);
            }
            return color * presence;
        }
        """#
}
