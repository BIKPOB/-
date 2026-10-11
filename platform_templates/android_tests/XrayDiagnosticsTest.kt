package app.quietvpn.quiet_vpn

import org.junit.Assert.*
import org.junit.Test

class XrayDiagnosticsTest {
    @Test fun nestedTransportErrorsKeepUsefulCausesWithoutCredentials() {
        val raw = "failed to find an available destination > failed to dial WebSocket > websocket: bad handshake " +
            "vless://12345678-1234-1234-1234-123456789abc@private.example/path?token=secret"
        val result = XrayDiagnostics.classify(raw)
        assertTrue(result.contains("WebSocket: сервер отклонил"))
        assertTrue(result.contains("Xray: не удалось подключиться"))
        assertFalse(result.contains("secret"))
        assertFalse(result.contains("private.example"))
        assertFalse(result.contains("12345678"))
    }
    @Test fun unknownErrorsNeverEchoTheirContents() {
        val result = XrayDiagnostics.classify("new error password=secret ss://sensitive")
        assertTrue(result.contains("неклассифицированная"))
        assertFalse(result.contains("secret"))
        assertFalse(result.contains("ss://"))
    }
    @Test fun normalRealityStatusIsNotAnError() {
        assertTrue(XrayDiagnostics.classify("[Info] REALITY connected to endpoint").contains("не подтверждает"))
    }
    @Test fun distinguishesNoLogDnsAndTimeout() {
        assertTrue(XrayDiagnostics.classify("").contains("не подтверждает"))
        assertTrue(XrayDiagnostics.classify("lookup endpoint: no such host").contains("DNS:"))
        assertTrue(XrayDiagnostics.classify("dial tcp: i/o timeout").contains("ожидание"))
    }
}
