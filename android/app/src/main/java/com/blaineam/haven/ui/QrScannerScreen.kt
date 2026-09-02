package com.blaineam.haven.ui

import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size as GSize
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.blaineam.haven.R
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors

/**
 * A custom, on-brand in-app QR scanner (CameraX preview + zxing-core frame decoding) replacing
 * the default ZXing CaptureActivity. Calls [onResult] once with the decoded string.
 */
@Composable
fun QrScannerScreen(onResult: (String) -> Unit, onCancel: () -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val executor = remember0 { Executors.newSingleThreadExecutor() }
    val reader = remember0 {
        MultiFormatReader().apply {
            setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(com.google.zxing.BarcodeFormat.QR_CODE)))
        }
    }
    var done = remember0 { booleanArrayOf(false) }

    // A viewfinder is up: a song preview must not start behind it, and one already playing stops.
    androidx.compose.runtime.DisposableEffect(Unit) {
        MusicPlayer.beginCameraSession()
        onDispose { MusicPlayer.endCameraSession() }
    }

    // Without this, system back skips the scanner entirely and finishes the Activity — measured:
    // pressing back here dropped straight to the launcher. Connect is shown by AnimatedVisibility,
    // not a Dialog or a nav destination, so nothing else was ever going to catch it.
    BackHandler { onCancel() }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                val previewView = PreviewView(ctx)
                val future = ProcessCameraProvider.getInstance(ctx)
                future.addListener({
                    val provider = future.get()
                    val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
                    // setTargetResolution's replacement, and NOT a rename — the two pick
                    // different buffers, so this deliberately does not pin 16:9.
                    //
                    // The old call took its Size in the TARGET ROTATION's frame: portrait turned
                    // 1280x720 into a 720x1280 request, and the rule was "smallest supported size
                    // >= that", which only a tall 4:3 buffer can satisfy. Measured on the API 35
                    // emulator (YUV_420_888 offers 640x480 / 1024x768 / 1280x720 / 1856x1392):
                    // the analysis stream came out 1856x1392, never 720p. Pinning 16:9 here would
                    // hand the analyzer a literal 1280x720 — a silent resolution CUT on every
                    // device, and Haven's own invite QR carries a ~800-character payload, so the
                    // pixels-per-module margin is the thing keeping it scannable.
                    //
                    // So keep ImageAnalysis's default 4:3 and let the same "closest not-smaller"
                    // rule choose: 1856x1392 on the emulator, identical to what shipped.
                    val analysis = ImageAnalysis.Builder()
                        .setResolutionSelector(
                            ResolutionSelector.Builder()
                                .setResolutionStrategy(
                                    ResolutionStrategy(
                                        Size(1280, 720),
                                        ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                                    ),
                                )
                                .build(),
                        )
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build()
                    analysis.setAnalyzer(executor) { proxy ->
                        if (!done[0]) {
                            decodeQr(proxy, reader)?.let { text ->
                                if (!done[0]) {
                                    done[0] = true
                                    previewView.post { onResult(text) }
                                }
                            }
                        }
                        proxy.close()
                    }
                    runCatching {
                        provider.unbindAll()
                        provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                    }
                }, ContextCompat.getMainExecutor(ctx))
                previewView
            },
        )

        // Branded scanning frame.
        Canvas(Modifier.fillMaxSize()) {
            val side = size.minDimension * 0.66f
            val left = (size.width - side) / 2f
            val top = (size.height - side) / 2f
            // dim
            drawRect(Color(0x99000000))
            // clear window
            drawRect(Color.Transparent, topLeft = Offset(left, top), size = GSize(side, side),
                blendMode = androidx.compose.ui.graphics.BlendMode.Clear)
            // corner brackets
            val c = 36f; val sw = 6f
            val pink = Color(0xFFEC4899)
            listOf(
                Offset(left, top) to listOf(Offset(left, top + c), Offset(left, top), Offset(left + c, top)),
                Offset(left + side, top) to listOf(Offset(left + side - c, top), Offset(left + side, top), Offset(left + side, top + c)),
                Offset(left, top + side) to listOf(Offset(left, top + side - c), Offset(left, top + side), Offset(left + c, top + side)),
                Offset(left + side, top + side) to listOf(Offset(left + side - c, top + side), Offset(left + side, top + side), Offset(left + side, top + side - c)),
            ).forEach { (_, pts) ->
                drawLine(pink, pts[0], pts[1], strokeWidth = sw)
                drawLine(pink, pts[1], pts[2], strokeWidth = sw)
            }
        }

        // statusBarsPadding is load-bearing, not cosmetic: enableEdgeToEdge() means we draw UNDER
        // the status bar, and the system's status-bar window eats touches in that strip. Measured on
        // a Pixel 8 — the button sat at y=32..158px with a ~110px status bar, so tapping the arrow's
        // visible centre did nothing while only a sliver at its bottom edge worked. StoryEditor's
        // top chrome already does this; this screen just missed it.
        Column(Modifier.fillMaxWidth().align(Alignment.TopStart).statusBarsPadding().padding(16.dp)) {
            Box(Modifier.size(40.dp).clip(RoundedCornerShape(20.dp)).clickable { onCancel() },
                contentAlignment = Alignment.Center) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.common_back), tint = Color.White)
            }
        }
        Text(
            stringResource(R.string.qr_point_at_qr),
            color = Color.White, fontSize = 15.sp, textAlign = TextAlign.Center,
            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(bottom = 60.dp),
        )

        DisposableEffect(Unit) { onDispose { executor.shutdown() } }
    }
}

private fun decodeQr(proxy: ImageProxy, reader: MultiFormatReader): String? {
    val plane = proxy.planes.firstOrNull() ?: return null
    val buffer = plane.buffer
    val data = ByteArray(buffer.remaining()).also { buffer.get(it) }
    val w = proxy.width; val h = proxy.height
    val source = PlanarYUVLuminanceSource(data, plane.rowStride, h, 0, 0, plane.rowStride.coerceAtMost(w), h, false)
    return runCatching { reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text }.getOrNull()
        ?: runCatching {
            val inv = PlanarYUVLuminanceSource(data, plane.rowStride, h, 0, 0, plane.rowStride.coerceAtMost(w), h, false).invert()
            reader.decodeWithState(BinaryBitmap(HybridBinarizer(inv))).text
        }.getOrNull()
}

/** A non-composable-keyed remember (state that must survive recomposition but isn't observed). */
@Composable
private fun <T> remember0(factory: () -> T): T = androidx.compose.runtime.remember { factory() }
