package com.blaineam.haven.core

/**
 * Portable photo/video filters — a direct port of the iOS `FilterSpec` / `HavenFilter` set
 * (apple/HavenApp/MediaFilters.swift). The *look* of each filter is a small set of platform-neutral
 * parameters; here we render that spec with a single GLSL fragment shader that is shared by the
 * photo path (offscreen GL), the video path (MediaCodec transcode), and the live preview — so a
 * photo/video looks the same on Android as it does on iOS.
 */
data class FilterSpec(
    val temperatureK: Double = 6500.0, // white-balance target (neutral 6500K)
    val tint: Double = 0.0,            // green ↔ magenta
    val saturation: Double = 1.0,      // 0 = grayscale, 1 = normal
    val contrast: Double = 1.0,
    val brightness: Double = 0.0,
    val vibrance: Double = 0.0,        // protects already-saturated tones
    val highlights: Double = 1.0,      // 0…1, pull highlights down
    val shadows: Double = 0.0,         // −1…1, lift/deepen shadows
    val fade: Double = 0.0,            // 0…1, lifted blacks (matte film look)
    val grain: Double = 0.0,           // 0…1, film grain
    val vignette: Double = 0.0,        // 0…1, corner darkening
    val monochrome: MonoTone? = null,
) {
    enum class MonoTone { NEUTRAL, WARM, COOL }
}

/** The built-in filter set — nine Apple-Photos-style looks plus a realistic Kodak Gold film sim. */
enum class HavenFilter(val title: String, val spec: FilterSpec) {
    ORIGINAL("Original", FilterSpec()),
    VIVID("Vivid", FilterSpec(saturation = 1.22, contrast = 1.06, vibrance = 0.25)),
    VIVID_WARM("Vivid Warm", FilterSpec(temperatureK = 5200.0, saturation = 1.2, contrast = 1.05, vibrance = 0.22)),
    VIVID_COOL("Vivid Cool", FilterSpec(temperatureK = 7800.0, saturation = 1.2, contrast = 1.05, vibrance = 0.22)),
    DRAMATIC("Dramatic", FilterSpec(saturation = 0.92, contrast = 1.22, highlights = 0.85, shadows = -0.2)),
    DRAMATIC_WARM("Dramatic Warm", FilterSpec(temperatureK = 5000.0, saturation = 0.95, contrast = 1.2, highlights = 0.85, shadows = -0.18)),
    DRAMATIC_COOL("Dramatic Cool", FilterSpec(temperatureK = 8200.0, saturation = 0.9, contrast = 1.2, highlights = 0.85, shadows = -0.2)),
    MONO("Mono", FilterSpec(contrast = 1.05, monochrome = FilterSpec.MonoTone.NEUTRAL)),
    SILVERTONE("Silvertone", FilterSpec(contrast = 1.1, monochrome = FilterSpec.MonoTone.WARM)),
    NOIR("Noir", FilterSpec(contrast = 1.3, shadows = -0.3, monochrome = FilterSpec.MonoTone.COOL)),
    // Warm highlights, gently lifted/faded blacks, soft contrast, a touch of grain + vignette.
    KODAK_GOLD("Kodak Gold", FilterSpec(temperatureK = 5400.0, tint = 6.0, saturation = 1.08, contrast = 0.96,
        vibrance = 0.12, highlights = 0.92, shadows = 0.08, fade = 0.12, grain = 0.22, vignette = 0.18)),
    ;

    companion object { val all = entries }
}

/** Builds the GLSL fragment shader for a spec, with the spec's constants baked in (no uniforms). */
object FilterShader {
    const val VERTEX = """
attribute vec4 aPosition;
attribute vec4 aTextureCoord;
varying highp vec2 vTextureCoord;
void main() {
    gl_Position = aPosition;
    vTextureCoord = aTextureCoord.xy;
}
"""

    /** A glsl float literal (always has a decimal point). Locale.ROOT, not the device locale: on a
     *  German/French phone `%.5f` wrote `1,50000`, which is not GLSL, so the shader failed to compile. */
    private fun g(v: Double): String = "%.5f".format(java.util.Locale.ROOT, v)

    /** White balance (temperature/tint) → per-channel gains, matching iOS temperatureAndTint feel. */
    private fun wbGains(tempK: Double, tint: Double): Triple<Double, Double, Double> {
        val warm = (6500.0 - tempK) / 6500.0      // + warmer, − cooler
        val r = (1.0 + 0.40 * warm + 0.002 * tint).coerceIn(0.5, 1.6)
        val b = (1.0 - 0.40 * warm + 0.002 * tint).coerceIn(0.5, 1.6)
        val gr = (1.0 - 0.004 * tint).coerceIn(0.5, 1.6) // +tint → magenta (less green)
        return Triple(r, gr, b)
    }

    /** Vertex shader for the live camera (applies the SurfaceTexture transform to the OES coords). */
    const val CAMERA_VERTEX = """
attribute vec4 aPosition;
attribute vec4 aTextureCoord;
uniform mat4 uTexMatrix;
varying highp vec2 vTextureCoord;
void main() {
    gl_Position = aPosition;
    vTextureCoord = (uTexMatrix * aTextureCoord).xy;
}
"""

    /** sampler2D fragment shader — used by the offscreen photo pass and the video transcoder. */
    fun fragmentFor(spec: FilterSpec): String = buildString {
        append("precision mediump float;\n")
        append("varying highp vec2 vTextureCoord;\n")
        append("uniform lowp sampler2D sTexture;\n")
        append(mainBody(spec))
    }

    /** External-OES fragment shader — same grading, used by the live camera preview. */
    fun fragmentForOes(spec: FilterSpec): String = buildString {
        append("#extension GL_OES_EGL_image_external : require\n")
        append("precision mediump float;\n")
        append("varying highp vec2 vTextureCoord;\n")
        append("uniform samplerExternalOES sTexture;\n")
        append(mainBody(spec))
    }

    /** The shared main() — samples sTexture and applies the grading pipeline. */
    private fun mainBody(spec: FilterSpec): String {
        val sb = StringBuilder()
        sb.append("const vec3 L = vec3(0.299, 0.587, 0.114);\n")
        sb.append("void main() {\n")
        sb.append("    vec2 uv = vTextureCoord;\n")
        sb.append("    vec4 c = texture2D(sTexture, uv);\n")
        sb.append("    vec3 rgb = c.rgb;\n")

        val (rG, gG, bG) = wbGains(spec.temperatureK, spec.tint)
        if (spec.temperatureK != 6500.0 || spec.tint != 0.0)
            sb.append("    rgb *= vec3(${g(rG)}, ${g(gG)}, ${g(bG)});\n")

        if (spec.highlights != 1.0 || spec.shadows != 0.0) {
            sb.append("    { float l = dot(rgb, L);\n")
            sb.append("      rgb += ${g(spec.shadows)} * (1.0 - smoothstep(0.0, 0.5, l)) * 0.5;\n")
            sb.append("      rgb -= ${g(1.0 - spec.highlights)} * smoothstep(0.5, 1.0, l) * 0.5;\n")
            sb.append("      rgb = clamp(rgb, 0.0, 1.0); }\n")
        }
        if (spec.contrast != 1.0 || spec.brightness != 0.0)
            sb.append("    rgb = (rgb - 0.5) * ${g(spec.contrast)} + 0.5 + ${g(spec.brightness)};\n")

        val mono = spec.monochrome
        if (mono != null) {
            val tone = when (mono) {
                FilterSpec.MonoTone.NEUTRAL -> doubleArrayOf(0.6, 0.6, 0.6)
                FilterSpec.MonoTone.WARM -> doubleArrayOf(0.68, 0.62, 0.5)
                FilterSpec.MonoTone.COOL -> doubleArrayOf(0.5, 0.55, 0.62)
            }
            val luma = tone[0] * 0.299 + tone[1] * 0.587 + tone[2] * 0.114
            val n = if (luma > 0) 1.0 / luma else 1.0 // preserve overall brightness, just tint
            sb.append("    { float my = dot(clamp(rgb, 0.0, 1.0), L);\n")
            sb.append("      rgb = my * vec3(${g(tone[0] * n)}, ${g(tone[1] * n)}, ${g(tone[2] * n)}); }\n")
        } else {
            if (spec.saturation != 1.0)
                sb.append("    { float gy = dot(rgb, L); rgb = mix(vec3(gy), rgb, ${g(spec.saturation)}); }\n")
            if (spec.vibrance != 0.0) {
                sb.append("    { float mx = max(rgb.r, max(rgb.g, rgb.b));\n")
                sb.append("      float mn = min(rgb.r, min(rgb.g, rgb.b));\n")
                sb.append("      float sat = mx - mn; float gy = dot(rgb, L);\n")
                sb.append("      rgb = mix(vec3(gy), rgb, 1.0 + ${g(spec.vibrance)} * (1.0 - sat)); }\n")
            }
        }
        if (spec.fade > 0.0)
            sb.append("    rgb = max(rgb, vec3(${g(spec.fade * 0.12)}));\n")
        if (spec.grain > 0.0)
            // Per-PIXEL hash (gl_FragCoord, not uv): a uv-based hash bands into horizontal lines
            // because adjacent pixels get near-identical uv. This gives real film grain.
            sb.append("    { float n = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453);\n" +
                "      rgb += (n - 0.5) * ${g(spec.grain * 0.28)}; }\n")
        if (spec.vignette > 0.0)
            sb.append("    rgb *= 1.0 - ${g(spec.vignette)} * smoothstep(0.35, 0.85, distance(uv, vec2(0.5)));\n")

        sb.append("    gl_FragColor = vec4(clamp(rgb, 0.0, 1.0), c.a);\n")
        sb.append("}\n")
        return sb.toString()
    }
}
