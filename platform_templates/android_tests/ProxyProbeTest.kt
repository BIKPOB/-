package app.quietvpn.quiet_vpn

import java.net.ServerSocket
import java.net.Socket
import java.io.DataInputStream
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Test

class ProxyProbeTest {
    @Test fun sendsLiteralIpWithoutSocksDomainResolution() {
        ServerSocket(0).use { server ->
            val pool = Executors.newSingleThreadExecutor()
            try {
                val received = pool.submit<List<Int>> {
                    server.accept().use { peer ->
                        peer.soTimeout = 2000
                        val input = DataInputStream(peer.getInputStream())
                        input.readFully(ByteArray(3))
                        peer.getOutputStream().write(byteArrayOf(5, 0))
                        val request = List(10) { input.readUnsignedByte() }
                        peer.getOutputStream().write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, 0, 0))
                        request
                    }
                }
                Socket("127.0.0.1", server.localPort).use {
                    it.soTimeout = 2000
                    ProxyProbe.socksConnect(it, "1.1.1.1", byteArrayOf(1, 1, 1, 1))
                }
                assertEquals(listOf(5, 1, 0, 1, 1, 1, 1, 1, 1, 187), received.get(3, TimeUnit.SECONDS))
            } finally { pool.shutdownNow() }
        }
    }
    @Test fun sendsDomainToSocksWithoutLocalDns() {
        ServerSocket(0).use { server ->
            val pool = Executors.newSingleThreadExecutor()
            try {
                val host = pool.submit<String> {
                    server.accept().use { peer ->
                        val input = DataInputStream(peer.getInputStream())
                        val greeting = ByteArray(3); input.readFully(greeting)
                        peer.getOutputStream().write(byteArrayOf(5, 0))
                        assertEquals(5, input.readUnsignedByte())
                        assertEquals(1, input.readUnsignedByte())
                        assertEquals(0, input.readUnsignedByte())
                        assertEquals(3, input.readUnsignedByte())
                        val name = ByteArray(input.readUnsignedByte()); input.readFully(name)
                        assertEquals(443, input.readUnsignedShort())
                        peer.getOutputStream().write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, 0, 0))
                        String(name, Charsets.US_ASCII)
                    }
                }
                Socket("127.0.0.1", server.localPort).use {
                    it.soTimeout = 2000
                    ProxyProbe.socksConnect(it, "unresolvable.invalid")
                }
                assertEquals("unresolvable.invalid", host.get(3, TimeUnit.SECONDS))
            } finally { pool.shutdownNow() }
        }
    }
}
