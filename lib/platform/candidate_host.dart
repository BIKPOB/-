import 'dart:async';
import 'dart:convert';
import 'dart:io';

class CandidateStartException implements Exception {
  const CandidateStartException(this.code);
  final String code;
}

/// A bounded proxy-only core. Implementations must never create a TUN here.
abstract interface class CandidateHost {
  Future<String> resolveCandidate(String host);
  Future<void> startCandidates(String configuration);
  Future<void> stopCandidates();
}

class CandidatePorts {
  static Future<void> closed(String config) async {
    final inbounds=(jsonDecode(config) as Map)['inbounds'] as List;
    await Future.wait(inbounds.map((entry) async {
      for(var i=0;i<20;i++) {
        Socket? socket;
        try {
          socket=await Socket.connect(InternetAddress.loopbackIPv4,entry['port'] as int,
            timeout:const Duration(milliseconds:100));
        } catch(_) {return;}
        finally {socket?.destroy();}
        await Future<void>.delayed(const Duration(milliseconds:50));
      }
      throw StateError('Остановка проверочного прокси не подтверждена');
    }));
  }
  static Future<void> wait(String config) async {
    final inbounds=(jsonDecode(config) as Map)['inbounds'] as List;
    await Future.wait(inbounds.map((entry) async {
      for(var i=0;i<12;i++) {
        try {
          final socket=await Socket.connect(InternetAddress.loopbackIPv4,entry['port'] as int,
            timeout:const Duration(milliseconds:200));
          socket.destroy();return;
        } catch(_) {
          if(i==11) throw StateError('Локальный проверочный прокси не запущен');
          await Future<void>.delayed(const Duration(milliseconds:50));
        }
      }
    }));
  }
}

/// Only implementations with an independently bound physical route opt in.
abstract interface class ReserveCandidateHost implements CandidateHost {
  Future<void> startReserveCandidates(String configuration);
}
class ReserveHostAdapter implements CandidateHost {
  ReserveHostAdapter(this.host);
  final ReserveCandidateHost host;
  @override Future<String> resolveCandidate(String hostName) => host.resolveCandidate(hostName);
  @override Future<void> startCandidates(String config) => host.startReserveCandidates(config);
  @override Future<void> stopCandidates() => host.stopCandidates();
}
