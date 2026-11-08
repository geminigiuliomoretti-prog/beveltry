import 'dart:async';
import 'dart:typed_data';

import 'package:beveltry/src/ble/ble.dart';
import 'package:beveltry/src/repository/whoop_repository.dart';
import 'package:beveltry/src/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

class MockPuffinTransport implements PuffinTransport {
  MockPuffinTransport({this.isConnected = true});

  @override
  bool isConnected;
  bool simulateBondException = false;

  final List<Uint8List> writtenFrames = [];
  final List<PuffinCharacteristic> writtenCharacteristics = [];

  final _incomingFramesController =
      StreamController<PuffinIncomingFrame>.broadcast();

  @override
  Stream<PuffinIncomingFrame> get incomingFrames =>
      _incomingFramesController.stream;

  void emit(
    Uint8List payload, {
    int field = 1,
    PuffinCharacteristic characteristic = PuffinCharacteristic.cmdFromStrap,
  }) {
    final frame = PuffinFrame(
      field: field,
      payload: payload,
      rawPayload: payload,
      headerCRC: 0,
      payloadCRC: 0,
    );
    _incomingFramesController.add(PuffinIncomingFrame(
      frame: frame,
      characteristic: characteristic,
    ));
  }

  @override
  Future<void> write(
    Uint8List frame, {
    PuffinCharacteristic characteristic = PuffinCharacteristic.cmdToStrap,
  }) async {
    writtenFrames.add(Uint8List.fromList(frame));
    writtenCharacteristics.add(characteristic);
  }

  @override
  Stream<List<WhoopDiscoveredDevice>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) =>
      Stream.value([
        const WhoopDiscoveredDevice(
          name: 'WBB5AP-5AG0558675',
          macAddress: 'FD:49:44:66:1D:92',
          rssi: -58,
        ),
      ]);

  @override
  Future<bool> connectAndBond(
    WhoopDiscoveredDevice device, {
    void Function()? onBondingStarted,
    void Function(String message)? onRetryProgress,
  }) async {
    onBondingStarted?.call();
    if (simulateBondException) {
      isConnected = false;
      throw BleBondException('Bonding fallito o annullato: timeout');
    }
    isConnected = true;
    return true;
  }

  @override
  Future<void> disconnect() async {
    isConnected = false;
  }
}

void main() {
  group('PuffinFrameReassembler Tests', () {
    test('Riassembla un frame diviso in 2 chunk BLE', () {
      final reassembler = PuffinFrameReassembler();
      final inner = Uint8List.fromList([0x23, 0x01, 0x91, 0x01]);
      final fullFrame = PuffinFrameCodec.encode(0x0100, inner);

      // Dividi in 2 frammenti
      final chunk1 = fullFrame.sublist(0, 10);
      final chunk2 = fullFrame.sublist(10);

      final r1 = reassembler.feed(chunk1);
      expect(r1, isEmpty);

      final r2 = reassembler.feed(chunk2);
      expect(r2.length, equals(1));
      expect(r2.first.field, equals(0x0100));
      expect(r2.first.payload, equals(inner));
    });

    test('Estrae multipli frame presenti in un unico chunk', () {
      final reassembler = PuffinFrameReassembler();
      final f1 = PuffinFrameCodec.encode(1, Uint8List.fromList([0x23, 0x01, 0x16, 0x00]));
      final f2 = PuffinFrameCodec.encode(1, Uint8List.fromList([0x23, 0x02, 0x17, 0x01]));

      final merged = Uint8List(f1.length + f2.length);
      merged.setRange(0, f1.length, f1);
      merged.setRange(f1.length, merged.length, f2);

      final frames = reassembler.feed(merged);
      expect(frames.length, equals(2));
      expect(frames[0].payload[2], equals(0x16));
      expect(frames[1].payload[2], equals(0x17));
    });

    test('Scarta byte non validi prima del SOF 0xAA 0x01', () {
      final reassembler = PuffinFrameReassembler();
      final valid = PuffinFrameCodec.encode(1, Uint8List.fromList([0x23, 0x05, 0x22, 0x00]));
      final corrupted = Uint8List.fromList([0x00, 0xFF, 0xAA, 0x02, ...valid]);

      final frames = reassembler.feed(corrupted);
      expect(frames.length, equals(1));
      expect(frames.first.payload[2], equals(0x22));
    });
  });

  group('DartPuffinHandshake Tests', () {
    test('Handshake esegue l intera sequenza e risponde agli ACK', () async {
      final transport = MockPuffinTransport();
      final handshake = DartPuffinHandshake(transport, timeout: const Duration(seconds: 1));

      // Auto-responder sul mock transport: quando riceve un comando write, emette l'ACK 0x24 corrispondente
      void handleWrite(Uint8List frame) {
        final inner = PuffinFrameCodec.decode(frame);
        final seq = inner[1];
        final opcode = inner[2];

        // Se GET_CLOCK (0x0B), invia timestamp
        if (opcode == 0x0B) {
          transport.emit(Uint8List.fromList([
            0x24, seq, 0x0B, 0x00, 0x00, 0x00, 0x50, 0x69, 0x2A,
          ]));
        } else {
          // ACK generico 0x24 con status 0x00
          transport.emit(Uint8List.fromList([0x24, seq, opcode, 0x00, 0x00]));
        }
      }

      final progressSteps = <String>[];
      final handshakeFuture = handshake.start(onProgress: progressSteps.add);

      // Loop di risposta automatica
      var processed = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 5), (t) {
        while (processed < transport.writtenFrames.length) {
          handleWrite(transport.writtenFrames[processed]);
          processed++;
        }
      });

      await handshakeFuture;
      timer.cancel();

      expect(progressSteps, contains(contains('HELLO confermato')));
      expect(progressSteps, contains(contains('Handshake hardware completato')));
      expect(transport.writtenFrames.length, greaterThan(15));

      // Verifica che il frame 0x91 inviato usi field = 1 (byte 4 e 5: 0x01, 0x00 LE)
      final firstFrame = transport.writtenFrames.first;
      expect(firstFrame[4], equals(0x01));
      expect(firstFrame[5], equals(0x00));
    });

    test('0x24 legge status a byte[4] e non confonde strap_seq=0x02 con status', () async {
      final transport = MockPuffinTransport();
      final handshake = DartPuffinHandshake(transport, timeout: const Duration(milliseconds: 300));

      final handshakeFuture = handshake.start();

      // Risponde a 0x91 con strap_seq = 0x02 a byte[3] e status = 0x00 a byte[4]
      await Future<void>.delayed(const Duration(milliseconds: 10));
      transport.emit(Uint8List.fromList([0x24, 0x01, 0x91, 0x02, 0x00]));

      // Risponde ai restanti comandi per far completare
      for (var i = 0; i < 25; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (transport.writtenFrames.length > 1) {
          final last = PuffinFrameCodec.decode(transport.writtenFrames.last);
          final op = last[2];
          final seq = last[1];
          if (op == 0x0B) {
            transport.emit(Uint8List.fromList([0x24, seq, 0x0B, 0x03, 0x00, 0x00, 0x50, 0x69, 0x2A]));
          } else {
            transport.emit(Uint8List.fromList([0x24, seq, op, 0x04, 0x00]));
          }
        }
      }

      await handshakeFuture;
      expect(handshake, isNotNull);
    });

    test('0x91 accetta status 0x02 (Session Already Active)', () async {
      final transport = MockPuffinTransport();
      final handshake = DartPuffinHandshake(transport, timeout: const Duration(milliseconds: 300));

      final handshakeFuture = handshake.start();

      // Risponde a 0x91 con status 0x02 a byte[4]
      await Future<void>.delayed(const Duration(milliseconds: 10));
      transport.emit(Uint8List.fromList([0x24, 0x01, 0x91, 0x01, 0x02]));

      // Risponde ai restanti comandi
      for (var i = 0; i < 25; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (transport.writtenFrames.length > 1) {
          final last = PuffinFrameCodec.decode(transport.writtenFrames.last);
          final op = last[2];
          final seq = last[1];
          if (op == 0x0B) {
            transport.emit(Uint8List.fromList([0x24, seq, 0x0B, 0x01, 0x00, 0x00, 0x50, 0x69, 0x2A]));
          } else {
            transport.emit(Uint8List.fromList([0x24, seq, op, 0x01, 0x00]));
          }
        }
      }

      await handshakeFuture;
    });

    test('Handshake fallisce se il cinturino risponde con status di errore 0xFF su 0x91', () async {
      final transport = MockPuffinTransport();
      final handshake = DartPuffinHandshake(transport, timeout: const Duration(milliseconds: 200));

      final handshakeFuture = handshake.start();

      // Risponde con status di errore 0xFF per HELLO (0x91)
      await Future<void>.delayed(const Duration(milliseconds: 10));
      transport.emit(Uint8List.fromList([0x24, 0x01, 0x91, 0x00, 0xFF]));

      expect(
        () async => await handshakeFuture,
        throwsA(isA<DartPuffinHandshakeException>()),
      );
    });
  });

  group('SyncService Hardware Integration Tests', () {
    late WhoopRepository repository;
    late MockPuffinTransport transport;
    late SyncService syncService;

    setUp(() {
      repository = WhoopRepository.inMemory();
      transport = MockPuffinTransport(isConnected: true);
      syncService = SyncService(
        repository: repository,
        transport: transport,
        simulateIfNoHardware: false,
      );
    });

    tearDown(() async {
      await repository.close();
    });

    test('sendVibration invia 0x42 e legge status ACK 0x00', () async {
      final vibFuture = syncService.sendVibration(slot: 1, pattern: 1, durationMs: 1000);

      // Simula risposta ACK 0x24 dal cinturino
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(transport.writtenFrames.length, equals(1));
      transport.emit(Uint8List.fromList([0x24, 0x01, 0x42, 0x00, 0x00]));

      final result = await vibFuture;
      expect(result, isTrue);
      expect(syncService.lastVibrationStatusNotifier.value, equals(0x00));
      expect(syncService.statusMessageNotifier.value, contains('Status ACK cinturino: 0x00'));
    });

    test('Auto-ACK 0x31 METADATA_CURSOR invia 0x17 con il cursore a 8 byte', () async {
      final syncFuture = syncService.startSync();

      await Future<void>.delayed(const Duration(milliseconds: 10));
      // Verifica invio 0x16 (START_HISTORICAL_OFFLOAD)
      expect(transport.writtenFrames.length, equals(1));
      final firstFrame = PuffinFrameCodec.decode(transport.writtenFrames.first);
      expect(firstFrame[2], equals(0x16));

      // Invia frame 0x31 METADATA_CURSOR con cursor [1, 2, 3, 4, 5, 6, 7, 8] a byte 13..20
      final cursorBytes = Uint8List(24);
      cursorBytes[0] = 0x31;
      cursorBytes.setRange(13, 21, [1, 2, 3, 4, 5, 6, 7, 8]);
      transport.emit(cursorBytes, characteristic: PuffinCharacteristic.dataFromStrap);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(transport.writtenFrames.length, equals(2));

      final ackFrame = PuffinFrameCodec.decode(transport.writtenFrames[1]);
      expect(ackFrame[2], equals(0x17)); // Opcode ACK_CURSOR
      expect(ackFrame[3], equals(0x01)); // Flag
      expect(ackFrame.sublist(4, 12), equals([1, 2, 3, 4, 5, 6, 7, 8]));

      syncService.stopSync();
      await syncFuture;
    });

    test('Ricezione 0x28 aggiorna liveHrNotifier e liveRrNotifier in tempo reale', () async {
      final syncFuture = syncService.startSync();

      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Pacchetto Live28: type 0x28, version 0x02, ts, HR 74, validity 1, RR 810 ms
      final live28 = Uint8List(12);
      live28[0] = 0x28;
      live28[1] = 0x02;
      ByteData.sublistView(live28).setUint32(2, 1700000000, Endian.little);
      live28[8] = 74; // HR
      live28[9] = 1;  // validity
      ByteData.sublistView(live28).setUint16(10, 810, Endian.little); // RR

      transport.emit(live28, characteristic: PuffinCharacteristic.dataFromStrap);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(syncService.liveHrNotifier.value, equals(74));
      expect(syncService.liveRrNotifier.value, equals(810));

      syncService.stopSync();
      await syncFuture;
    });

    test('BleBondException imposta stato BleStatusError e messaggio chiaro', () async {
      transport.simulateBondException = true;
      const device = WhoopDiscoveredDevice(name: 'WHOOP', macAddress: 'AA:BB:CC:DD:EE:FF');
      final result = await syncService.connectAndBond(device);
      expect(result, isFalse);
      expect(syncService.connectionState, isA<BleStatusError>());
      expect((syncService.connectionState as BleStatusError).message, contains('Bonding fallito o annullato'));
      expect(syncService.statusMessageNotifier.value, contains('Bonding fallito o annullato'));
    });

    test('Errore GATT 133 persistente mostra messaggio chiaro e non genera crash', () async {
      final simTransport = SimulatedPuffinTransport(
        simulatePersistent133: true,
      );
      final testService = SyncService(
        repository: repository,
        transport: simTransport,
        simulateIfNoHardware: true,
      );

      const device = WhoopDiscoveredDevice(name: 'WHOOP', macAddress: 'AA:BB:CC:DD:EE:FF');
      final result = await testService.connectAndBond(device);

      expect(result, isFalse);
      expect(testService.connectionState, isA<BleStatusError>());
      final err = testService.connectionState as BleStatusError;
      expect(err.message, contains('Errore GATT 133'));
      expect(testService.statusMessageNotifier.value, contains('Errore GATT 133'));
      expect(testService.statusMessageNotifier.value, contains('Dimentica il WHOOP'));
    });

    test('Retry su errore GATT 133 recupera con successo al secondo tentativo', () async {
      final simTransport = SimulatedPuffinTransport(
        simulate133FailuresBeforeSuccess: 1,
      );
      final testService = SyncService(
        repository: repository,
        transport: simTransport,
        simulateIfNoHardware: true,
      );

      // Simula il transport che ritenta
      const device = WhoopDiscoveredDevice(name: 'WHOOP', macAddress: 'AA:BB:CC:DD:EE:FF');
      
      // Il primo tentativo fallisce con 133, ma riprovando ha successo
      var firstFailed = false;
      try {
        await simTransport.connectAndBond(device);
      } catch (_) {
        firstFailed = true;
      }
      expect(firstFailed, isTrue);
      expect(simTransport.connectAttempts, equals(1));

      // Secondo tentativo
      final secondSuccess = await simTransport.connectAndBond(device);
      expect(secondSuccess, isTrue);
      expect(simTransport.connectAttempts, equals(2));
      expect(simTransport.isConnected, isTrue);
    });
  });
}
