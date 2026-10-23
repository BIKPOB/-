package app.quietvpn.quiet_vpn

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.*
import android.os.Bundle
import android.os.SystemClock
import android.widget.RemoteViews

/** Passive view of Quiet's last state. Buttons open its UI to keep VPN consent and ownership explicit. */
class QuietWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) = refresh(context)
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) = refresh(context)
    companion object {
        private var lastRender = 0L
        private var lastStatus = ""
        fun update(context: Context, values: Map<*, *>) {
            val status = values["status"] as? String ?: "Отключено"
            val now = SystemClock.elapsedRealtime()
            if (status == lastStatus && now - lastRender < 5000) return
            lastStatus = status; lastRender = now
            context.getSharedPreferences("quiet-widget", Context.MODE_PRIVATE).edit()
                .putString("status", status).putString("download", values["download"] as? String ?: "—")
                .putString("upload", values["upload"] as? String ?: "—")
                .putBoolean("active", values["active"] == true)
                .putLong("updated", System.currentTimeMillis()).apply()
            refresh(context)
        }
        fun connectionWarning(context: Context) {
            context.getSharedPreferences("quiet-widget", Context.MODE_PRIVATE).edit()
                .putString("status", "Проверьте связь").putBoolean("active", false)
                .putLong("updated", System.currentTimeMillis()).apply()
            refresh(context)
        }
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, QuietWidget::class.java))
            if (ids.isEmpty()) return
            val prefs = context.getSharedPreferences("quiet-widget", Context.MODE_PRIVATE)
            // Never claim a live measurement after Flutter has stopped publishing it.
            val fresh = System.currentTimeMillis() - prefs.getLong("updated", 0) in 0..15000
            val status = if (fresh) prefs.getString("status", "Отключено")!! else "Откройте для проверки"
            val active = fresh && prefs.getBoolean("active", false)
            val bitmap = Bitmap.createBitmap(800, 400, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            paint.shader = LinearGradient(800f, 0f, 0f, 400f, intArrayOf(Color.rgb(1,6,50), Color.rgb(6,130,114)), null, Shader.TileMode.CLAMP)
            canvas.drawRoundRect(0f, 0f, 800f, 400f, 26f, 26f, paint); paint.shader = null
            val type = try { Typeface.createFromAsset(context.assets, "flutter_assets/assets/fonts/Bahnschrift.ttf") } catch (_: Exception) { Typeface.DEFAULT }
            paint.typeface = Typeface.create(type, Typeface.NORMAL); paint.setFontVariationSettings("'wght' 300, 'wdth' 87.5"); paint.color = Color.WHITE
            fun text(value: String, x: Float, y: Float, size: Float) {
                paint.textSize = size
                while (paint.measureText(value) > 435 && paint.textSize > 20) paint.textSize -= 1
                canvas.drawText(value, x, y, paint)
            }
            fun icon(name: String, x: Int, y: Int, size: Int) {
                try { context.assets.open("flutter_assets/assets/design/$name.png").use {
                    val image = BitmapFactory.decodeStream(it)
                    canvas.drawBitmap(image, null, Rect(x,y,x+size,y+size), paint); image.recycle()
                } } catch (_: Exception) { }
            }
            icon("logo", 24, 24, 72)
            text(status, 55f, 170f, 47f)
            text(if (fresh) "↓ ${prefs.getString("download", "—")}   ↑ ${prefs.getString("upload", "—")}" else "Нажмите, чтобы обновить", 55f, 300f, 25f)
            paint.style = Paint.Style.STROKE; paint.color = Color.rgb(41,145,113); paint.strokeWidth = 4f
            canvas.drawRoundRect(490f,75f,750f,205f,65f,65f,paint)
            canvas.drawRoundRect(490f,230f,750f,360f,65f,65f,paint)
            paint.style = Paint.Style.FILL
            icon(if(active) "power_on" else "power_off",500,85,110); icon("search",635,110,65)
            icon("ai",520,260,65); icon("reserve",635,260,65)
            for(id in ids) {
                val view = RemoteViews(context.packageName, R.layout.quiet_widget)
                view.setImageViewBitmap(R.id.widget_image, bitmap)
                view.setContentDescription(R.id.widget_image, "Quiet VPN: $status")
                val targets = listOf(R.id.widget_power to "power", R.id.widget_search to "search", R.id.widget_ai to "ai", R.id.widget_reserve to "reserve", R.id.widget_open to "open")
                for((index, target) in targets.withIndex()) {
                    val intent = Intent(context, MainActivity::class.java).setAction("quietvpn.widget.${target.second}")
                        .putExtra("widget_action", target.second).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    view.setOnClickPendingIntent(target.first, PendingIntent.getActivity(context, index, intent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
                }
                manager.updateAppWidget(id,view)
            }
        }
    }
}
