package com.blaineam.haven.ui

import android.annotation.SuppressLint
import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.provider.MediaStore
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.MediaStoreOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.blaineam.haven.core.DEFAULT_CIRCLE
import com.blaineam.haven.core.LocalMedia
import com.blaineam.haven.core.readVideoBytes
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.ByteArrayOutputStream

private const val TAG = "StoryCamera"
private data class StoryDraft(val ref: String, val isVideo: Boolean, val filterIdx: Int = 0)

/** In-app story camera: TAP = photo, HOLD = video (release to stop), flip. Then the editor. */
@SuppressLint("MissingPermission")
@Composable
fun StoryCameraScreen(
    onClose: () -> Unit,
    storeCircle: String = DEFAULT_CIRCLE,
    // Post mode: when set, a capture is handed back (ref, isVideo) instead of opening the story editor.
    onCaptured: ((String, Boolean) -> Unit)? = null,
) {
    var draft by remember { mutableStateOf<StoryDraft?>(null) }
    val d = draft
    if (d != null) { StoryEditor(ref = d.ref, isVideo = d.isVideo, initialFilter = d.filterIdx, onClose = onClose); return }

    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()
    var lensFront by remember { mutableStateOf(false) }
    var liveFilterIdx by remember { mutableStateOf(0) }
    var status by remember { mutableStateOf("Tap for photo · hold for video") }
    var isRecording by remember { mutableStateOf(false) }
    val imageCapture = remember { ImageCapture.Builder().setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY).build() }
    val videoCapture = remember {
        VideoCapture.withOutput(
            Recorder.Builder().setQualitySelector(
                QualitySelector.fromOrderedList(
                    listOf(Quality.HD, Quality.SD, Quality.LOWEST),
                    FallbackStrategy.lowerQualityOrHigherThan(Quality.LOWEST),
                ),
            ).build(),
        )
    }
    val recordingRef = remember { arrayOfNulls<Recording>(1) }
    val hasAudio = ContextCompat.checkSelfPermission(context, android.Manifest.permission.RECORD_AUDIO) ==
        android.content.pm.PackageManager.PERMISSION_GRANTED

    fun takePhoto() {
        status = "Capturing…"
        imageCapture.takePicture(ContextCompat.getMainExecutor(context),
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: androidx.camera.core.ImageProxy) {
                    val rot = image.imageInfo.rotationDegrees
                    val raw = runCatching {
                        val buf = image.planes[0].buffer
                        ByteArray(buf.remaining()).also { buf.get(it) }
                    }.getOrNull()
                    image.close()
                    // Rotate + compress + encrypt + write off the main thread (was freezing the UI).
                    scope.launch {
                        val ref = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
                            raw?.let { uprightJpeg(it, rot, mirror = lensFront) }
                                ?.let { LocalMedia.store(storeCircle, it) }
                        }
                        if (ref != null) {
                            if (onCaptured != null) onCaptured(ref, false) else draft = StoryDraft(ref, false, liveFilterIdx)
                        } else status = "Couldn't capture"
                    }
                }
                override fun onError(e: ImageCaptureException) { status = "Capture failed" }
            })
    }

    fun startVideo() {
        if (recordingRef[0] != null) return
        status = "Recording…"; isRecording = true
        // Record to an app cache file (no MediaStore/scoped-storage — far more reliable).
        val file = java.io.File(context.cacheDir, "haven_rec_${System.nanoTime()}.mp4")
        val opts = androidx.camera.video.FileOutputOptions.Builder(file).build()
        val pending = videoCapture.output.prepareRecording(context, opts)
        val rec = if (hasAudio) pending.withAudioEnabled() else pending
        recordingRef[0] = rec.start(ContextCompat.getMainExecutor(context)) { ev ->
            if (ev is VideoRecordEvent.Finalize) {
                isRecording = false; recordingRef[0] = null
                // ERROR_NO_VALID_DATA(8) just means the tap was too brief — treat as "hold longer".
                val ok = !ev.hasError() || ev.error == VideoRecordEvent.Finalize.ERROR_NO_VALID_DATA
                if (ev.hasError()) Log.e(TAG, "record finalize error ${ev.error}", ev.cause)
                if (!ev.hasError() && file.exists() && file.length() > 0) {
                    scope.launch {
                        val ref = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                            runCatching {
                                val bytes = file.readBytes(); file.delete()
                                LocalMedia.store(storeCircle, bytes, isVideo = true)
                            }.getOrNull()
                        }
                        if (ref != null) {
                            if (onCaptured != null) onCaptured(ref, true) else draft = StoryDraft(ref, true, liveFilterIdx)
                        } else status = "Couldn't save video"
                    }
                } else {
                    runCatching { file.delete() }
                    status = if (ok) "Hold longer to record" else "Recording failed (${ev.error})"
                }
            }
        }
    }

    fun stopVideo() { runCatching { recordingRef[0]?.stop() } }

    // Live filter-applied GL preview (the camera frame is rendered through the same grading shader).
    val glView = remember { FilteredCameraView(context) }
    var surfaceTex by remember { mutableStateOf<android.graphics.SurfaceTexture?>(null) }
    DisposableEffect(glView) {
        glView.onSurfaceTextureReady = { surfaceTex = it }
        onDispose { glView.onSurfaceTextureReady = null }
    }
    LaunchedEffect(liveFilterIdx) { glView.setFilter(com.blaineam.haven.core.HavenFilter.all[liveFilterIdx].spec) }
    LaunchedEffect(surfaceTex, lensFront) {
        val st = surfaceTex ?: return@LaunchedEffect
        val provider = awaitCameraProvider(context)
        val preview = Preview.Builder().build().also { p ->
            p.setSurfaceProvider(ContextCompat.getMainExecutor(context)) { req ->
                st.setDefaultBufferSize(req.resolution.width, req.resolution.height)
                glView.setFrameSize(req.resolution.width, req.resolution.height)   // aspect-fill, no squish
                val surface = android.view.Surface(st)
                req.provideSurface(surface, ContextCompat.getMainExecutor(context)) { surface.release() }
            }
        }
        val selector = if (lensFront) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        runCatching {
            provider.unbindAll()
            provider.bindToLifecycle(lifecycleOwner, selector, preview, imageCapture, videoCapture)
        }.onFailure {
            runCatching { provider.bindToLifecycle(lifecycleOwner, selector, preview, imageCapture) }
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            modifier = Modifier.fillMaxSize().pointerInput(Unit) {
                var dx = 0f
                detectHorizontalDragGestures(
                    onDragStart = { dx = 0f },
                    onHorizontalDrag = { _, amount -> dx += amount },
                    onDragEnd = {
                        val n = com.blaineam.haven.core.HavenFilter.all.size
                        if (dx <= -40f) liveFilterIdx = (liveFilterIdx + 1) % n
                        else if (dx >= 40f) liveFilterIdx = (liveFilterIdx - 1 + n) % n
                    },
                )
            },
            factory = { glView },
        )

        // Current live-filter name + swipe hint.
        Text(com.blaineam.haven.core.HavenFilter.all[liveFilterIdx].title, color = Color.White, fontSize = 15.sp,
            modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 200.dp)
                .clip(CircleShape).background(Color.Black.copy(alpha = 0.4f)).padding(horizontal = 16.dp, vertical = 6.dp))

        // statusBarsPadding, like the filter hint's navigationBarsPadding above: we draw under the
        // system bars, and the status-bar window eats taps in its strip — so without this, Close's
        // visible centre is dead and only its bottom edge answers. The bottom inset was already
        // handled here; the top just got missed.
        Box(Modifier.align(Alignment.TopStart).statusBarsPadding().padding(16.dp).size(42.dp).clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.35f)).pointerInput(Unit) { detectTap(onClose) },
            contentAlignment = Alignment.Center) { Icon(Icons.Filled.Close, "Close", tint = Color.White) }
        Box(Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(16.dp).size(42.dp).clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.35f)).pointerInput(Unit) { detectTap { lensFront = !lensFront } },
            contentAlignment = Alignment.Center) { Icon(Icons.Filled.Cameraswitch, "Flip", tint = Color.White) }

        Text(status, color = Color.White, fontSize = 13.sp,
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 150.dp))

        Box(
            Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 40.dp).size(82.dp).clip(CircleShape)
                .border(5.dp, if (isRecording) Color(0xFFEF4444) else Color.White, CircleShape)
                .background(if (isRecording) Color(0xFFEF4444).copy(alpha = 0.55f) else Color.White.copy(alpha = 0.22f))
                .pointerInput(Unit) {
                    awaitEachGesture {
                        awaitFirstDown()
                        val held = arrayOf(false)
                        val job = scope.launch { delay(350); held[0] = true; startVideo() }
                        waitForUpOrCancellation()
                        job.cancel()
                        if (held[0]) stopVideo() else takePhoto()
                    }
                },
        )
    }
}

/** Decode a captured JPEG, rotate it upright (and un-mirror the front camera), re-encode. */
private fun uprightJpeg(jpeg: ByteArray, rotation: Int, mirror: Boolean): ByteArray? = runCatching {
    val bmp = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return null
    val out = if (rotation == 0 && !mirror) bmp else {
        val m = Matrix()
        if (rotation != 0) m.postRotate(rotation.toFloat())
        if (mirror) m.postScale(-1f, 1f)
        Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
    }
    ByteArrayOutputStream().also { out.compress(Bitmap.CompressFormat.JPEG, 90, it) }.toByteArray()
}.getOrNull()

private suspend fun androidx.compose.ui.input.pointer.PointerInputScope.detectTap(onTap: () -> Unit) {
    awaitEachGesture { awaitFirstDown(); if (waitForUpOrCancellation() != null) onTap() }
}

/** Await the CameraX provider as a suspend call (it's delivered via a ListenableFuture). */
private suspend fun awaitCameraProvider(context: android.content.Context): ProcessCameraProvider =
    kotlinx.coroutines.suspendCancellableCoroutine { cont ->
        val f = ProcessCameraProvider.getInstance(context)
        f.addListener({ runCatching { cont.resumeWith(Result.success(f.get())) } }, ContextCompat.getMainExecutor(context))
    }

