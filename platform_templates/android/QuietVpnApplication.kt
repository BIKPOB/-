package app.quietvpn.quiet_vpn

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/** The Dart search outlives a UI Activity removed from Android Recents.
 * A foreground Service holds the process while a user-initiated search runs.
 * A force-stop or system process kill is NOT a resumable search. */
class QuietVpnApplication : Application() {
    companion object { const val ENGINE_ID = "quietvpn.retained.main" }
    private var retainedEngine: FlutterEngine? = null
    private var dartStarted = false

    @Synchronized fun engineForActivity(): FlutterEngine {
        retainedEngine?.let { return it }
        val engine = FlutterEngine(this)
        retainedEngine = engine
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    @Synchronized fun startDartIfNeeded() {
        if (dartStarted) return
        val engine = engineForActivity()
        dartStarted = true
        try {
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        } catch (e: Exception) {
            dartStarted = false
            throw e
        }
    }

    override fun onCreate() {
        super.onCreate()
        CrashDiagnostics.install(this)
        CatalogCache.schedule(this)
    }
}
