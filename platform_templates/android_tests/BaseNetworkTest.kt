package app.quietvpn.quiet_vpn

import android.net.NetworkCapabilities as NC
import org.junit.Assert.*
import org.junit.Test

class BaseNetworkTest {
    private val wifi = BaseNetwork.Candidate(10L, setOf(NC.TRANSPORT_WIFI))
    private val mobile = BaseNetwork.Candidate(20L, setOf(NC.TRANSPORT_CELLULAR))
    @Test fun vpnDefaultSelectsPhysicalWifiInsteadOfFailing() {
        assertEquals(10L, BaseNetwork.choose(99L, setOf(NC.TRANSPORT_WIFI), listOf(wifi, mobile)))
    }
    @Test fun vpnDefaultSelectsPhysicalMobile() {
        assertEquals(20L, BaseNetwork.choose(99L, setOf(NC.TRANSPORT_CELLULAR), listOf(wifi, mobile)))
    }
    @Test fun actualPhysicalDefaultWins() {
        assertEquals(20L, BaseNetwork.choose(20L, null, listOf(wifi, mobile)))
    }
    @Test fun transientMissingDefaultCanUseUniquePhysicalNetwork() {
        assertEquals(10L, BaseNetwork.choose(null, null, listOf(wifi)))
    }
    @Test fun unknownOrAmbiguousRouteIsNotGuessed() {
        assertNull(BaseNetwork.choose(99L, setOf(NC.TRANSPORT_WIFI, NC.TRANSPORT_CELLULAR), listOf(wifi, mobile)))
        assertNull(BaseNetwork.choose(null, null, emptyList()))
        assertNull(BaseNetwork.choose(null, null, listOf(wifi, mobile)))
    }
}
