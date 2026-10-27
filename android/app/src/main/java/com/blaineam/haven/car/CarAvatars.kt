package com.blaineam.haven.car

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.Typeface
import android.util.LruCache
import androidx.car.app.model.CarIcon
import androidx.core.graphics.drawable.IconCompat
import com.blaineam.haven.core.AppearancePrefs
import com.blaineam.haven.core.AvatarStore
import com.blaineam.haven.core.CarCalls
import com.blaineam.haven.ui.Palettes

/**
 * Round avatars for the head unit's rows: the contact's photo when they shared one, otherwise their
 * initials on a circle in the user's palette tint (CarPlay parity — `CarPlayAvatar`). Small
 * ([SIZE_PX]) because the host marshals the bitmap over IPC; cached by contact + palette so a redraw
 * never decodes again, and prefetched off the main thread ([prefetch]).
 */
object CarAvatars {
    const val SIZE_PX = 128

    private val cache = LruCache<String, CarIcon>(160)

    fun icon(hex: String, name: String): CarIcon {
        val palette = AppearancePrefs.palette
        val key = "${hex.lowercase()}|$palette|${name}"
        cache.get(key)?.let { return it }
        val bmp = AvatarStore.bitmap(hex)?.let { circleCrop(it) } ?: initialsBitmap(name, tint(palette))
        val icon = CarIcon.Builder(IconCompat.createWithBitmap(bmp)).build()
        cache.put(key, icon)
        return icon
    }

    /** Build (and cache) the icons for [entries] — call off the main thread. */
    fun prefetch(entries: List<CarCalls.Entry>) { entries.forEach { runCatching { icon(it.hex, it.name) } } }

    /** The palette's middle gradient stop (the tint stop), deepened for white text on Neutral. */
    private fun tint(paletteId: String): Int {
        val p = Palettes.byId(paletteId)
        return Palettes.gradientStops(p).second or (0xFF shl 24)
    }

    private fun circleCrop(src: Bitmap): Bitmap {
        val side = minOf(src.width, src.height)
        val out = Bitmap.createBitmap(SIZE_PX, SIZE_PX, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        c.drawCircle(SIZE_PX / 2f, SIZE_PX / 2f, SIZE_PX / 2f, paint)
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        val from = Rect((src.width - side) / 2, (src.height - side) / 2, (src.width + side) / 2, (src.height + side) / 2)
        c.drawBitmap(src, from, Rect(0, 0, SIZE_PX, SIZE_PX), paint)
        return out
    }

    private fun initialsBitmap(name: String, color: Int): Bitmap {
        val out = Bitmap.createBitmap(SIZE_PX, SIZE_PX, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
        c.drawCircle(SIZE_PX / 2f, SIZE_PX / 2f, SIZE_PX / 2f, fill)
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = Color.WHITE
            textAlign = Paint.Align.CENTER
            typeface = Typeface.DEFAULT_BOLD
            textSize = SIZE_PX * 0.42f
        }
        val y = SIZE_PX / 2f - (text.descent() + text.ascent()) / 2f
        c.drawText(CarCalls.initials(name), SIZE_PX / 2f, y, text)
        return out
    }
}
