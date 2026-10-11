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
    fun socksConnect(socket: Socket, host: String) {
        val output = socket.getOutputStream()
        val input = DataInputStream(socket.getInputStream())
        output.write(byteArrayOf(5, 1, 0)); output.flush()
        if (input.readUnsignedByte() != 5 || input.readUnsignedByte() != 0) throw IOException("SOCKS auth")
        val domain = host.toByteArray(Charsets.US_ASCII)
        require(domain.size in 1..255)
        output.write(byteArrayOf(5, 1, 0, 3, domain.size.toByte()))
        output.write(domain); output.write(byteArrayOf(1, 187.toByte())); output.flush()
        val version = input.readUnsignedByte()
        val status = input.readUnsignedByte()
        input.readUnsignedByte()
        val type = input.readUnsignedByte()
        if (version != 5 || status != 0) throw IOException("SOCKS reply $status")
        val length = when (type) { 1 -> 4; 4 -> 16; 3 -> input.readUnsignedByte(); else -> throw IOException("SOCKS address") }
        input.readFully(ByteArray(length + 2))
    }
    fun measure(): Map<String, Any> {
        val token = generation
        val failures = mutableListOf<String>()
        for (host in listOf("www.gstatic.com", "cp.cloudflare.com")) {
            if (token != generation) break
            val start = android.os.SystemClock.elapsedRealtime()
            val socket = Socket()
            pending = socket
            if (token != generation) { socket.close(); break }
            val deadline = timer.schedule({ try { socket.close() } catch (_: Exception) { } }, 8, TimeUnit.SECONDS)
            var stage = "локальный SOCKS"
            try {
                socket.soTimeout = 5000
                socket.connect(InetSocketAddress("127.0.0.1", 10807), 1500)
                stage = "ответ SOCKS через сервер"
                socksConnect(socket, host)
                stage = "TLS через сервер"
                val tls = (SSLSocketFactory.getDefault() as SSLSocketFactory).createSocket(socket, host, 443, true) as SSLSocket
                tls.use {
                    it.sslParameters = it.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
                    it.soTimeout = 5000
                    it.startHandshake()
                    stage = "HTTPS-ответ"
                    it.outputStream.write("GET /generate_204 HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII))
                    it.outputStream.flush()
                    val input = it.inputStream
                    val line = StringBuilder()
                    while (line.length < 512) {
                        val ch = input.read()
                        if (ch < 0 || ch == 10) break
                        line.append(ch.toChar())
                    }
                    if (!Regex("HTTP/1\\.[01] 204(?: .*|\\r)?").matches(line.toString().trimEnd())) throw IOException("HTTP status")
                }
                return mapOf("delay" to android.os.SystemClock.elapsedRealtime() - start, "detail" to host)
            } catch (e: Exception) {
                failures.add("$host: $stage (${e.javaClass.simpleName})")
            } finally {
                deadline.cancel(false)
                try { socket.close() } catch (_: Exception) { }
                if (pending === socket) pending = null
            }
        }
        return mapOf("delay" to -1L, "detail" to failures.joinToString("; "))
    }
    fun cancel() { generation++; try { pending?.close() } catch (_: Exception) { }; pending = null }
}
