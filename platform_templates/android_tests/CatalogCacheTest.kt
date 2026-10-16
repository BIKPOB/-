package app.quietvpn.quiet_vpn

import android.content.Context
import android.app.job.JobScheduler
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class CatalogCacheTest {
    @Test fun publisherMirrorKeepsOriginalAsFallback() {
        val original = CatalogCache.sources.getValue("igareck RU VLESS")
        assertEquals(listOf(original.replace("raw.githubusercontent.com", "raw.githack.com"), original),
            CatalogCache.addresses(original))
        val other = CatalogCache.sources.getValue("NiREvil/vless")
        assertEquals(listOf(other), CatalogCache.addresses(other))
    }
    @Test fun candidateDoesNotOverwriteValidatedSnapshot() {
        val context: Context = RuntimeEnvironment.getApplication()
        val source = "NiREvil/vless"
        CatalogCache.save(context, source, "validated-profile", true)
        CatalogCache.save(context, source, "invalid-candidate", false)
        val values = CatalogCache.read(context, source).map { it["text"] }
        assertTrue(values.contains("validated-profile"))
        assertTrue(values.contains("invalid-candidate"))
        try { CatalogCache.save(context, "../unknown", "test", false); fail("unknown source") }
        catch (_: IllegalArgumentException) { }
    }
    @Test fun schedulesPersistentNetworkJobWithoutResettingIt() {
        val context: Context = RuntimeEnvironment.getApplication()
        CatalogCache.schedule(context)
        CatalogCache.schedule(context)
        val job = context.getSystemService(JobScheduler::class.java).getPendingJob(7541)!!
        assertTrue(job.isPersisted)
        assertTrue(job.isPeriodic)
        assertEquals(6 * 60 * 60 * 1000L, job.intervalMillis)
    }
}
