package app.quietvpn.quiet_vpn

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.view.WindowInsets
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.*
import android.widget.*
import org.json.JSONTokener
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/** No native JavaScript interface: only bounded text is read from the top frame. */
object ConfigBrowserPolicy {
    const val LIMIT = 131072
    val sources = mapOf("vpnbook" to "https://www.vpnbook.com/freevpn/wireguard-vpn")
    fun allowed(source: String, value: String?): Boolean {
        if (value == null) return false
        val uri = Uri.parse(value)
        if (uri.scheme != "https" || uri.userInfo != null || uri.port !in listOf(-1, 443)) return false
        return when (source) {
            "vpnbook" -> uri.host in setOf("www.vpnbook.com", "vpnbook.com")
            "custom" -> !uri.host.isNullOrEmpty()
            else -> false
        }
    }
    fun config(text: String): Boolean = text.toByteArray(Charsets.UTF_8).size <= LIMIT &&
        !text.contains('\u0000') && ((text.contains("[Interface]") && text.contains("[Peer]")) ||
        text.trim().startsWith("vless://") || text.trim().startsWith("ss://"))

}

class ConfigBrowserActivity : Activity() {
    private lateinit var web: WebView
    private lateinit var status: TextView
    private var source = ""
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var webAlive = false
    private var fetching = false
    private var resumed = false
    private var delivered = false
    private var pageGeneration = 0
    @Volatile private var connection: HttpURLConnection? = null
    private val poll = object : Runnable {
        override fun run() {
            if (!resumed || isFinishing || !webAlive) return
            val generation = pageGeneration
            if (ConfigBrowserPolicy.allowed(source, web.url)) {
                web.evaluateJavascript("(function(){var x=window.__quietVpnDownloaded;window.__quietVpnDownloaded=null;return typeof x==='string'&&x.length<=131072?x:null;})()") { value ->
                    if (generation == pageGeneration && !isFinishing && !isDestroyed) {
                        val text = try { JSONTokener(value).nextValue() as? String } catch (_: Exception) { null }
                        if (text != null) accept(text)
                    }
                }
            }
            main.postDelayed(this, 750)
        }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        source = intent.getStringExtra("source") ?: ""
        val start = if (source == "custom") intent.getStringExtra("url") else ConfigBrowserPolicy.sources[source]
        if (start == null || !ConfigBrowserPolicy.allowed(source, start)) { finish(); return }
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.setOnApplyWindowInsetsListener { view, insets ->
            if (Build.VERSION.SDK_INT >= 30) {
                val bars = insets.getInsets(WindowInsets.Type.systemBars())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            } else {
                view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            }
            insets
        }
        val bar = LinearLayout(this)
        fun button(label: String, action: () -> Unit) { bar.addView(Button(this).apply { text = label; setOnClickListener { action() } }, LinearLayout.LayoutParams(0, 48.dp(), 1f)) }
        button("Закрыть") { finish() }
        button("Назад") { if (webAlive && web.canGoBack()) web.goBack() }
        button("Обновить") { if (webAlive) web.reload() }
        button("Очистить") {
            if (!webAlive) return@button
            AlertDialog.Builder(this).setMessage("Очистить кэш и вход на сайты? Сохранённые VPN-профили останутся.")
                .setNegativeButton("Отмена", null).setPositiveButton("Очистить") { _, _ ->
                    CookieManager.getInstance().removeAllCookies { if (webAlive) { web.clearCache(true); WebStorage.getInstance().deleteAllData(); web.loadUrl(start) } }
                }.show()
        }
        root.addView(bar)
        val actions = LinearLayout(this)
        actions.addView(Button(this).apply { text = "Импорт со страницы"; setOnClickListener { capturePage() } }, LinearLayout.LayoutParams(0, 52.dp(), 1f))
        actions.addView(Button(this).apply { text = "Ключ из буфера"; setOnClickListener {
            val clipboard = getSystemService(android.content.ClipboardManager::class.java)
            val clip = clipboard.primaryClip
            if (clip != null && clip.itemCount > 0) accept(clip.getItemAt(0).coerceToText(this@ConfigBrowserActivity).toString())
        } }, LinearLayout.LayoutParams(0, 52.dp(), 1f))
        root.addView(actions)
        status = TextView(this).apply { text = "Войдите на сайт, выберите сервер и скачайте .conf либо нажмите ссылку vless:// или ss://."; setPadding(12.dp(), 8.dp(), 12.dp(), 8.dp()) }
        root.addView(status)
        try { web = WebView(this) } catch (_: Exception) {
            setContentView(root); status.text = "Не удалось открыть Android System WebView. Обновите его через магазин приложений."; return
        }
        webAlive = true
        web.settings.apply {
            javaScriptEnabled = true; domStorageEnabled = true
            allowFileAccess = false; allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = WebSettings.LOAD_NO_CACHE
            setSupportMultipleWindows(false)
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, false)
        web.webChromeClient = WebChromeClient()
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                if (request.isForMainFrame && request.url.scheme in setOf("vless", "ss")) {
                    accept(request.url.toString()); return true
                }
                if (!request.isForMainFrame) return request.url.scheme != "https"
                if (!ConfigBrowserPolicy.allowed(source, request.url.toString())) {
                    status.text = "Ссылка вне выбранного источника заблокирована"; return true
                }
                return false
            }
            override fun onPageStarted(view: WebView, url: String?, icon: Bitmap?) {
                pageGeneration++
                if (!ConfigBrowserPolicy.allowed(source, url)) { view.stopLoading(); status.text = "Недопустимый адрес" }
            }
            override fun onPageFinished(view: WebView, url: String?) {
                if (ConfigBrowserPolicy.allowed(source, url)) {
                    status.text = "${Uri.parse(url).host} · получите ключ или конфигурацию"
                    view.evaluateJavascript(CAPTURE_SCRIPT, null)
                }
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) status.text = "Источник недоступен. Проверьте сеть или выберите другой источник."
            }
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                webAlive = false
                (view.parent as? ViewGroup)?.removeView(view); view.destroy()
                main.removeCallbacks(poll); resumed = false
                status.text = "Браузер остановился. Закройте окно и откройте источник снова."
                Toast.makeText(this@ConfigBrowserActivity, status.text, Toast.LENGTH_LONG).show(); finish()
                return true
            }
        }
        web.setDownloadListener { url, _, _, _, _ ->
            if (url.startsWith("blob:") || url.startsWith("data:")) {
                status.text = "Получение конфигурации…"
                // Runs inside the same origin; native code never gains arbitrary URL access.
                if (ConfigBrowserPolicy.allowed(source, web.url)) web.evaluateJavascript(
                    "window.__quietVpnCapture && window.__quietVpnCapture(${org.json.JSONObject.quote(url)});", null)
            } else download(url)
        }
        root.addView(web, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
        web.loadUrl(start)
    }
    private fun Int.dp() = (this * resources.displayMetrics.density).toInt()
    private fun download(url: String) {
        if (fetching || !ConfigBrowserPolicy.allowed(source, web.url) || !ConfigBrowserPolicy.allowed(source, url)) {
            status.text = "Не удалось скачать конфигурацию с этого адреса"; return
        }
        fetching = true
        val cookie = CookieManager.getInstance().getCookie(url)
        val agent = web.settings.userAgentString
        status.text = "Скачивание конфигурации…"
        worker.execute {
            try {
                val conn = URL(url).openConnection() as HttpURLConnection
                connection = conn
                conn.instanceFollowRedirects = false; conn.connectTimeout = 10000; conn.readTimeout = 10000
                conn.setRequestProperty("User-Agent", agent)
                if (cookie != null) conn.setRequestProperty("Cookie", cookie)
                check(conn.responseCode == 200)
                check(conn.contentLengthLong <= ConfigBrowserPolicy.LIMIT)
                val bytes = conn.inputStream.use { input ->
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(4096)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        check(output.size() + count <= ConfigBrowserPolicy.LIMIT)
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                }
                check(bytes.size <= ConfigBrowserPolicy.LIMIT)
                val text = bytes.toString(Charsets.UTF_8)
                main.post { fetching = false; if (!isFinishing && !isDestroyed) accept(text) }
            } catch (_: Exception) {
                main.post { fetching = false; if (!isFinishing && !isDestroyed) status.text = "Скачивание не удалось. Повторите выдачу .conf на сайте." }
            } finally { connection?.disconnect(); connection = null }
        }
    }
    private fun capturePage() {
        if (!webAlive || !ConfigBrowserPolicy.allowed(source, web.url)) return
        val generation = pageGeneration
        web.evaluateJavascript("""
            (function(){
              var out=[];
              function add(t){if(typeof t!=='string'||t.length>131072)return;
                t=t.trim();
                if(t.includes('[Interface]')&&t.includes('[Peer]'))out.push(t);
                var links=t.match(/(?:vless|ss):\/\/[^\s<>"']+/g)||[];
                links.forEach(x=>out.push(x));
              }
              document.querySelectorAll('a[href]').forEach(x=>add(x.getAttribute('href')));
              document.querySelectorAll('textarea,pre,code,input').forEach(x=>add(x.value||x.textContent));
              add(window.getSelection().toString());
              return Array.from(new Set(out)).slice(0,30);
            })();
        """.trimIndent()) { value ->
            if (generation != pageGeneration || isFinishing || isDestroyed) return@evaluateJavascript
            val entries = try { org.json.JSONArray(value) } catch (_: Exception) { org.json.JSONArray() }
            val profiles = (0 until entries.length()).map { entries.getString(it) }.filter { ConfigBrowserPolicy.config(it) }
            if (profiles.isEmpty()) { status.text = "Конфигурация не найдена. Скопируйте ключ на сайте и нажмите «Ключ из буфера»."; return@evaluateJavascript }
            if (profiles.size == 1) { accept(profiles[0]); return@evaluateJavascript }
            // Never show credentials in the selection list.
            val names = profiles.mapIndexed { index, text ->
                val kind = if (text.startsWith("vless://")) "VLESS" else if (text.startsWith("ss://")) "Shadowsocks" else "WireGuard"
                "$kind · профиль ${index + 1}"
            }.toTypedArray()
            AlertDialog.Builder(this).setTitle("Выберите профиль").setItems(names) { _, index -> accept(profiles[index]) }.setNegativeButton("Отмена", null).show()
        }
    }
    private fun accept(text: String) {
        if (delivered) return
        if (!ConfigBrowserPolicy.config(text)) { status.text = "Нужен .conf WireGuard, ключ vless:// или ss:// (до 128 КБ)"; return }
        delivered = true
        setResult(RESULT_OK, Intent().putExtra("profile", text))
        finish()
    }
    override fun onResume() { super.onResume(); resumed = true; if (webAlive) { web.onResume(); main.post(poll) } }
    override fun onPause() { resumed = false; main.removeCallbacks(poll); if (webAlive) web.onPause(); super.onPause() }
    override fun onDestroy() {
        main.removeCallbacksAndMessages(null); connection?.disconnect(); worker.shutdownNow()
        if (webAlive) { (web.parent as? ViewGroup)?.removeView(web); web.stopLoading(); web.clearCache(true); web.destroy() }
        super.onDestroy()
    }
    @Deprecated("Activity back navigation")
    override fun onBackPressed() { if (webAlive && web.canGoBack()) web.goBack() else super.onBackPressed() }
    companion object {
        val CAPTURE_SCRIPT = """
        (function(){
          if(window.__quietVpnCapture) return;
          window.__quietVpnCapture=async function(url){
            try {
              if(!/^(blob:|data:)/.test(url)) return;
              var response=await fetch(url), blob=await response.blob();
              if(blob.size>131072){window.__quietVpnDownloaded='ERROR_SIZE';return;}
              var text=await blob.text();
              window.__quietVpnDownloaded=((text.includes('[Interface]')&&text.includes('[Peer]'))||/^(vless|ss):\/\//.test(text.trim()))?text:'ERROR_FORMAT';
            } catch(e) {window.__quietVpnDownloaded='ERROR_DOWNLOAD';}
          };
          var original=HTMLAnchorElement.prototype.click;
          HTMLAnchorElement.prototype.click=function(){
            if(/^(blob:|data:)/.test(this.href)){window.__quietVpnCapture(this.href);return;}
            return original.apply(this,arguments);
          };
          document.addEventListener('click',function(e){
            var a=e.target.closest&&e.target.closest('a');
            if(a&&/^(blob:|data:)/.test(a.href)){e.preventDefault();window.__quietVpnCapture(a.href);}
          },true);
        })();
        """.trimIndent()
    }
}
