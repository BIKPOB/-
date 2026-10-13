package app.quietvpn.quiet_vpn

import android.Manifest
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager

/** Local per-application routing. Quiet VPN must remain in TUN for its own probes. */
object BypassApps {
    private fun prefs(context: Context) = context.getSharedPreferences("vpn_app_routing", Context.MODE_PRIVATE)
    @Suppress("DEPRECATION")
    private fun eligible(context: Context): List<ApplicationInfo> = context.packageManager
        .getInstalledApplications(0).filter {
            it.packageName != context.packageName && it.uid != context.applicationInfo.uid &&
                context.packageManager.checkPermission(Manifest.permission.INTERNET, it.packageName) == PackageManager.PERMISSION_GRANTED
        }
    fun selected(context: Context): List<String> {
        val saved = prefs(context).getStringSet("bypass", emptySet()) ?: emptySet()
        return eligible(context).map { it.packageName }.filter { it in saved }.sorted()
    }
    fun list(context: Context): List<Map<String, Any>> {
        val pm = context.packageManager
        return eligible(context).map {
            mapOf("package" to it.packageName, "name" to it.loadLabel(pm).toString(),
                "uid" to it.uid, "system" to ((it.flags and ApplicationInfo.FLAG_SYSTEM) != 0))
        }.sortedBy { (it["name"] as String).lowercase() }
    }
    fun save(context: Context, packages: List<String>) {
        val apps = eligible(context)
        val names = apps.map { it.packageName }.toSet()
        require(packages.all { it in names }) { "Unknown or protected application" }
        // Android routes by UID: reflect the complete shared-UID group in the saved selection.
        val uids = apps.filter { it.packageName in packages }.map { it.uid }.toSet()
        val selected = apps.filter { it.uid in uids }.map { it.packageName }.toSet()
        check(prefs(context).edit().putStringSet("bypass", selected).commit())
    }
    fun wireGuardProfile(profile: String, packages: List<String>): String {
        require(packages.all { it.matches(Regex("[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+")) })
        // The app's explicit routing preference is authoritative. Never mix allow/deny lists.
        val clean = profile.lineSequence().filterNot {
            val key = it.substringBefore('=').trim()
            key.equals("ExcludedApplications", true) || key.equals("IncludedApplications", true)
        }.toList()
        return clean.joinToString("\n") { line ->
            if (line.trim().equals("[Interface]", true) && packages.isNotEmpty())
                "$line\nExcludedApplications = ${packages.distinct().sorted().joinToString(", ")}" else line
        }
    }
}
