package app.quietvpn.quiet_vpn

import org.junit.Assert.assertEquals
import org.junit.Test

class TrafficRateTest {
    @Test fun elapsedTimeAndCounterReset() {
        val rate = TrafficRate()
        assertEquals("↓ —   ↑ —", rate.sample(100, 50, 1000))
        assertEquals("↓ 1.0 КиБ/с   ↑ 512 Б/с", rate.sample(2148, 1074, 3000))
        assertEquals("↓ 0 Б/с   ↑ 0 Б/с", rate.sample(2148, 1074, 4000))
        assertEquals("↓ —   ↑ —", rate.sample(0, 0, 5000))
        rate.reset()
        assertEquals("↓ —   ↑ —", rate.sample(1024, 1024, 6000))
    }
    @Test fun units() {
        assertEquals("1.0 МиБ/с", TrafficRate.format(1048576.0))
    }
}
