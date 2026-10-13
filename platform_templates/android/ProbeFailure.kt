package app.quietvpn.quiet_vpn

/** Preserve useful failure causes without logging exception messages or keys. */
object ProbeFailure {
    fun describe(error: Throwable): String {
        val parts = mutableListOf<String>()
        val seen = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Throwable, Boolean>())
        var current: Throwable? = error
        repeat(5) {
            val cause = current ?: return@repeat
            if (!seen.add(cause)) return parts.joinToString(" → ")
            val errno = if (cause is android.system.ErrnoException) " errno=${cause.errno}" else ""
            parts.add(cause.javaClass.simpleName + errno)
            current = cause.cause
        }
        return parts.joinToString(" → ")
    }
}
