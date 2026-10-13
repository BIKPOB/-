package app.quietvpn.quiet_vpn

import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/** SOCKS5 domain requests keep target DNS inside Xray, with verified TLS. */
object ProxyProbe {
    @Volatile private var pending: Socket? = null
    @Volatile private var generation = 0
    private val timer = Executors.newSingleThreadScheduledExecutor()
    fun socksConnect(socket: Socket, host: String, ipv4: ByteArray? = null) {
        val output = socket.getOutputStream()
        val input = DataInputStream(socket.getInputStream())
        output.write(byteArrayOf(5, 1, 0)); output.flush()
        if (input.readUnsignedByte() != 5 || input.readUnsignedByte() != 0) throw IOException("SOCKS auth")
        val domain = host.toByteArray(Charsets.US_ASCII)
        require(domain.size in 1..255)
        if (ipv4 == null) {
            output.write(byteArrayOf(5, 1, 0, 3, domain.size.toByte()))
            output.write(domain)
        } else {
            require(ipv4.size == 4)
            output.write(byteArrayOf(5, 1, 0, 1)); output.write(ipv4)
        }
        output.write(byteArrayOf(1, 187.toByte())); output.flush()
        val version = input.readUnsignedByte()
        val status = input.readUnsignedByte()
        input.readUnsignedByte()
        val type = input.readUnsignedByte()
        if (version != 5 || status != 0) throw IOException("SOCKS reply $status")
        val length = when (type) { 1 -> 4; 4 -> 16; 3 -> input.readUnsignedByte(); else -> throw IOException("SOCKS address") }
        input.readFully(ByteArray(length + 2))
    }
    fun measure(context: android.content.Context): Map<String, Any> {
        val token = generation
        val failures = mutableListOf<String>()
        // Isolate proxy transport from target DNS; TLS still verifies the IP SAN.
        for (host in listOf("1.1.1.1", "www.gstatic.com", "cp.cloudflare.com")) {
            if (token != generation) break
            val start = android.os.SystemClock.elapsedRealtime()
            val socket = Socket()
            pending = socket
            if (token != generation) { socket.close(); break }
            val deadline = timer.schedule({ try { socket.close() } catch (_: Exception) { } }, 20, TimeUnit.SECONDS)
            var stage = "локальный SOCKS"
            try {
                socket.soTimeout = 18000
                socket.connect(InetSocketAddress("127.0.0.1", 10807), 1500)
                stage = "локальное согласование SOCKS"
                val numeric = host == "1.1.1.1"
                socksConnect(socket, host, if (numeric) byteArrayOf(1, 1, 1, 1) else null)
                stage = if (numeric) "HTTPS по IP через Xray без DNS" else "HTTPS по имени через Xray"
                val tls = (SSLSocketFactory.getDefault() as SSLSocketFactory).createSocket(socket, host, 443, true) as SSLSocket
                tls.use {
                    it.sslParameters = it.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
                    it.soTimeout = 18000
                    it.startHandshake()
                    stage = "HTTPS-ответ"
                    val path = if (numeric) "/cdn-cgi/trace" else "/generate_204"
                    it.outputStream.write("GET $path HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII))
                    it.outputStream.flush()
                    val input = it.inputStream
                    val line = StringBuilder()
                    while (line.length < 512) {
                        val ch = input.read()
                        if (ch < 0 || ch == 10) break
                        line.append(ch.toChar())
                    }
                    val status = if (numeric) 200 else 204
                    if (!Regex("HTTP/1\\.[01] $status(?: .*|\\r)?").matches(line.toString().trimEnd())) throw IOException("HTTP status")
                }
                if (token != generation) break
                val tunnel = TunnelProbe.measure(context).toMutableMap()
                tunnel["detail"] = "${if (numeric) "HTTPS по IP без DNS подтверждён" else "HTTPS через прокси подтверждён"}; ${tunnel["detail"]}"
                return tunnel
            } catch (e: Exception) {
                failures.add("$host: $stage (${ProbeFailure.describe(e)}, ${android.os.SystemClock.elapsedRealtime() - start} мс)")
            } finally {
                deadline.cancel(false)
                try { socket.close() } catch (_: Exception) { }
                if (pending === socket) pending = null
            }
        }
        return mapOf("delay" to -1L, "detail" to failures.joinToString("; "))
    }
    fun cancel() { generation++; TunnelProbe.cancel(); try { pending?.close() } catch (_: Exception) { }; pending = null }
}

