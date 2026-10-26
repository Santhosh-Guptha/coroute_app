import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/data/services/smart_airbag_bridge_service.dart';
import 'package:coroute_app/presentation/rider/widgets/smart_airbag_hud_pill.dart';

class MockSafetyService extends ChangeNotifier implements SafetyService {
  final List<Map<String, dynamic>> impactCalls = [];

  @override
  void externalImpact({
    required ExternalImpactSource source,
    required double g,
    required int atMs,
  }) {
    impactCalls.add({
      'source': source,
      'g': g,
      'atMs': atMs,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSafetyService mockSafety;
  late SmartAirbagBridgeService bridge;

  setUp(() {
    mockSafety = MockSafetyService();
    SafetyService.instance = mockSafety;
    bridge = SmartAirbagBridgeService(safetyService: mockSafety);
    bridge.reset();
  });

  tearDown(() {
    bridge.reset();
    SafetyService.instance = null;
  });

  group('FEAT-06: Multi-Brand Motorcycle Airbag Vest Detection', () {
    test('TEST-AB-01: Detects In&motion Airbag Vests (Klim Ai-1, Held eVest, Ixon U03, RST)', () {
      expect(
        SmartAirbagBridgeService.detectBrand(deviceName: 'Klim Ai-1 Airbag Vest'),
        equals(AirbagBrand.inMotion),
      );
      expect(
        SmartAirbagBridgeService.detectBrand(deviceName: 'Held eVest In&box'),
        equals(AirbagBrand.inMotion),
      );
      expect(
        SmartAirbagBridgeService.detectBrand(deviceName: 'Ixon U03 In&box'),
        equals(AirbagBrand.inMotion),
      );
      expect(
        SmartAirbagBridgeService.detectBrand(deviceName: 'RST In&motion Airbag'),
        equals(AirbagBrand.inMotion),
      );
      expect(
        SmartAirbagBridgeService.detectBrand(
          serviceUuids: [AirbagGattConstants.inMotionServiceUuid],
        ),
        equals(AirbagBrand.inMotion),
      );
    });

    test('TEST-AB-02: Detects Alpinestars Tech-Air Vests (Tech-Air 3, 5, 10)', () {
      expect(
        SmartAirbagBridgeService.detectBrand(deviceName: 'Alpinestars Tech-Air 5'),
        equals(AirbagBrand.alpinestars),
      );
      expect(
        SmartAirbagBridgeService.detectBrand(deviceName: 'TechAir 3'),
        equals(AirbagBrand.alpinestars),
      );
      expect(
        SmartAirbagBridgeService.detectBrand(deviceName: 'Tech-Air 10 Racing'),
        equals(AirbagBrand.alpinestars),
      );
      expect(
        SmartAirbagBridgeService.detectBrand(
          serviceUuids: [AirbagGattConstants.techAirServiceUuid],
        ),
        equals(AirbagBrand.alpinestars),
      );
    });

    test('TEST-AB-03: Detects Helite e-Vest Systems (e-Turtle, e-GP-Air CDU bridge)', () {
      expect(
        SmartAirbagBridgeService.detectBrand(deviceName: 'Helite e-Turtle 2'),
        equals(AirbagBrand.helite),
      );
      expect(
        SmartAirbagBridgeService.detectBrand(deviceName: 'Helite e-GP-Air CDU'),
        equals(AirbagBrand.helite),
      );
      expect(
        SmartAirbagBridgeService.detectBrand(
          serviceUuids: [AirbagGattConstants.heliteServiceUuid],
        ),
        equals(AirbagBrand.helite),
      );
    });

    test('TEST-AB-04: Detects Dainese D-air Vests (Smart Jacket, Misano)', () {
      expect(
        SmartAirbagBridgeService.detectBrand(deviceName: 'Dainese Smart Jacket D-air'),
        equals(AirbagBrand.dainese),
      );
      expect(
        SmartAirbagBridgeService.detectBrand(deviceName: 'D-air Misano 2'),
        equals(AirbagBrand.dainese),
      );
      expect(
        SmartAirbagBridgeService.detectBrand(
          serviceUuids: [AirbagGattConstants.dAirServiceUuid],
        ),
        equals(AirbagBrand.dainese),
      );
    });

    test('TEST-AB-05: Returns unknown for generic non-airbag BLE peripherals', () {
      expect(
        SmartAirbagBridgeService.detectBrand(deviceName: 'Sena 50S Headset'),
        equals(AirbagBrand.unknown),
      );
      expect(
        SmartAirbagBridgeService.detectBrand(deviceName: 'Garmin HRM-Pro'),
        equals(AirbagBrand.unknown),
      );
    });
  });

  group('FEAT-06: State Management & Telemetry Notifiers', () {
    test('TEST-AB-06: Initial state is disconnected with empty telemetry', () {
      expect(bridge.connectionState, equals(AirbagConnectionState.disconnected));
      expect(bridge.isConnected, isFalse);
      expect(bridge.isArmed, isFalse);
      expect(bridge.isDeployed, isFalse);
      expect(bridge.batteryLevel, isNull);
    });

    test('TEST-AB-07: Scan lifecycle triggers connectionStateNotifier updates', () {
      final states = <AirbagConnectionState>[];
      bridge.connectionStateNotifier.addListener(() {
        states.add(bridge.connectionState);
      });

      bridge.startScan();
      expect(bridge.connectionState, equals(AirbagConnectionState.scanning));

      bridge.stopScan();
      expect(bridge.connectionState, equals(AirbagConnectionState.disconnected));

      expect(states, equals([AirbagConnectionState.scanning, AirbagConnectionState.disconnected]));
    });

    test('TEST-AB-08: Peripheral connection updates telemetry and battery notifiers', () {
      int telemetryCount = 0;
      int batteryCount = 0;

      bridge.telemetryNotifier.addListener(() => telemetryCount++);
      bridge.batteryLevelNotifier.addListener(() => batteryCount++);

      bridge.connect(
        deviceId: 'BLE:INMOTION:001',
        name: 'Klim Ai-1 Airbag',
        brand: AirbagBrand.inMotion,
        serialNumber: 'INBOX-883921',
        batteryLevel: 94,
        isArmed: true,
      );

      expect(bridge.connectionState, equals(AirbagConnectionState.connected));
      expect(bridge.isConnected, isTrue);
      expect(bridge.isArmed, isTrue);
      expect(bridge.isDeployed, isFalse);
      expect(bridge.batteryLevel, equals(94));
      expect(bridge.telemetry.modelName, equals('Klim Ai-1 Airbag'));
      expect(bridge.telemetry.serialNumber, equals('INBOX-883921'));
      expect(bridge.telemetry.systemState, equals(AirbagSystemState.armed));

      expect(telemetryCount, greaterThan(0));
      expect(batteryCount, greaterThan(0));
    });

    test('TEST-AB-09: Standard GATT Battery Service updates battery notifier without impact', () {
      bridge.connect(
        deviceId: 'BLE:TECHAIR:005',
        name: 'Alpinestars Tech-Air 5',
        brand: AirbagBrand.alpinestars,
        batteryLevel: 80,
      );

      bridge.processGattNotification(
        characteristicUuid: AirbagGattConstants.standardBatteryLevelUuid,
        data: [72],
      );

      expect(bridge.batteryLevel, equals(72));
      expect(bridge.telemetry.batteryLevel, equals(72));
      expect(mockSafety.impactCalls, isEmpty);
    });
  });

  group('FEAT-06: Instant Escalation to Safety Pipeline & Latency Guarantee', () {
    test('TEST-AB-10: In&motion pyrotechnic deployment triggers SafetyService externalImpact with sub-150ms latency', () {
      bridge.connect(
        deviceId: 'BLE:INMOTION:001',
        name: 'Held eVest In&box',
        brand: AirbagBrand.inMotion,
        batteryLevel: 90,
      );

      final stopwatch = Stopwatch()..start();

      // In&motion deployment notification byte 0 = 0x02 (or 0xDE)
      bridge.processGattNotification(
        characteristicUuid: AirbagGattConstants.inMotionDeployNotificationUuid,
        data: [0x02, 88],
      );

      stopwatch.stop();

      // 1. Verify sub-150ms execution
      expect(stopwatch.elapsedMilliseconds, lessThan(150),
          reason: 'Deployment escalation must execute in under 150ms');

      // 2. Verify state transition
      expect(bridge.connectionState, equals(AirbagConnectionState.deployed));
      expect(bridge.isDeployed, isTrue);
      expect(bridge.telemetry.lastDeploymentMs, isNotNull);

      // 3. Verify safety pipeline escalation
      expect(mockSafety.impactCalls.length, equals(1));
      final call = mockSafety.impactCalls.first;
      expect(call['source'], equals(ExternalImpactSource.wearable));
      expect(call['g'], equals(6.0));
      expect(call['atMs'], isA<int>());
    });

    test('TEST-AB-11: Alpinestars Tech-Air System State Deployed triggers SafetyService externalImpact', () {
      bridge.connect(
        deviceId: 'BLE:TECHAIR:003',
        name: 'Alpinestars Tech-Air 3',
        brand: AirbagBrand.alpinestars,
        batteryLevel: 100,
      );

      // Tech-Air system state byte 0x02 = Deployed
      bridge.processGattNotification(
        characteristicUuid: AirbagGattConstants.techAirSystemStateUuid,
        data: [0x02],
      );

      expect(bridge.connectionState, equals(AirbagConnectionState.deployed));
      expect(bridge.isDeployed, isTrue);
      expect(mockSafety.impactCalls.length, equals(1));
      expect(mockSafety.impactCalls.first['source'], equals(ExternalImpactSource.wearable));
      expect(mockSafety.impactCalls.first['g'], equals(6.0));
    });

    test('TEST-AB-12: Helite e-Vest CDU pyrotechnic trigger triggers SafetyService externalImpact', () {
      bridge.connect(
        deviceId: 'BLE:HELITE:001',
        name: 'Helite e-Turtle',
        brand: AirbagBrand.helite,
        batteryLevel: 95,
      );

      // Helite CDU trigger byte 0xAA = Deployed
      bridge.processGattNotification(
        characteristicUuid: AirbagGattConstants.heliteTriggerUuid,
        data: [0xAA, 95],
      );

      expect(bridge.connectionState, equals(AirbagConnectionState.deployed));
      expect(bridge.isDeployed, isTrue);
      expect(mockSafety.impactCalls.length, equals(1));
      expect(mockSafety.impactCalls.first['source'], equals(ExternalImpactSource.wearable));
      expect(mockSafety.impactCalls.first['g'], equals(6.0));
    });

    test('TEST-AB-13: Dainese D-air shield deployment triggers SafetyService externalImpact', () {
      bridge.connect(
        deviceId: 'BLE:DAIR:001',
        name: 'Dainese D-air Smart Jacket',
        brand: AirbagBrand.dainese,
        batteryLevel: 85,
      );

      // Dainese D-air status byte 0x02 = Deployed
      bridge.processGattNotification(
        characteristicUuid: AirbagGattConstants.dAirStatusUuid,
        data: [0x02],
      );

      expect(bridge.connectionState, equals(AirbagConnectionState.deployed));
      expect(bridge.isDeployed, isTrue);
      expect(mockSafety.impactCalls.length, equals(1));
      expect(mockSafety.impactCalls.first['source'], equals(ExternalImpactSource.wearable));
      expect(mockSafety.impactCalls.first['g'], equals(6.0));
    });

    test('TEST-AB-14: Manual hardware test deployment triggers immediate SafetyService externalImpact', () {
      bridge.connect(
        deviceId: 'BLE:INMOTION:TEST',
        name: 'Hardware Test Vest',
        brand: AirbagBrand.inMotion,
        batteryLevel: 99,
      );

      bridge.triggerHardwareTestDeployment();

      expect(bridge.connectionState, equals(AirbagConnectionState.deployed));
      expect(bridge.isDeployed, isTrue);
      expect(mockSafety.impactCalls.length, equals(1));
      expect(mockSafety.impactCalls.first['source'], equals(ExternalImpactSource.wearable));
      expect(mockSafety.impactCalls.first['g'], equals(6.0));
    });
  });

  group('FEAT-06: Strict Immunity to False Positives', () {
    test('TEST-AB-15: Low battery warnings never trigger crash deployment', () {
      bridge.connect(
        deviceId: 'BLE:TECHAIR:005',
        name: 'Alpinestars Tech-Air 5',
        brand: AirbagBrand.alpinestars,
        batteryLevel: 15,
      );

      // Tech-Air state 0x05 = Low battery warning
      bridge.processGattNotification(
        characteristicUuid: AirbagGattConstants.techAirSystemStateUuid,
        data: [0x05, 12],
      );

      expect(bridge.connectionState, equals(AirbagConnectionState.connected));
      expect(bridge.isDeployed, isFalse);
      expect(bridge.telemetry.systemState, equals(AirbagSystemState.lowBatteryWarning));
      expect(mockSafety.impactCalls, isEmpty,
          reason: 'Low battery warning must be strictly immune from triggering crash alarm');

      // Dainese status 0x05 = Low battery alert
      bridge.processGattNotification(
        characteristicUuid: AirbagGattConstants.dAirStatusUuid,
        data: [0x05],
        brand: AirbagBrand.dainese,
      );

      expect(bridge.isDeployed, isFalse);
      expect(mockSafety.impactCalls, isEmpty);
    });

    test('TEST-AB-16: Firmware update / OTA mode never triggers crash deployment', () {
      bridge.connect(
        deviceId: 'BLE:INMOTION:001',
        name: 'Klim Ai-1 In&box',
        brand: AirbagBrand.inMotion,
        batteryLevel: 80,
      );

      // In&motion status 0x04 = In&box Firmware Flashing / Desktop sync
      bridge.processGattNotification(
        characteristicUuid: AirbagGattConstants.inMotionDeployNotificationUuid,
        data: [0x04],
      );

      expect(bridge.connectionState, equals(AirbagConnectionState.connected));
      expect(bridge.isDeployed, isFalse);
      expect(bridge.telemetry.systemState, equals(AirbagSystemState.firmwareUpdate));
      expect(mockSafety.impactCalls, isEmpty,
          reason: 'Firmware update OTA mode must never trigger crash alarm');

      // Alpinestars state 0x04 = Bootloader / Firmware flashing
      bridge.processGattNotification(
        characteristicUuid: AirbagGattConstants.techAirSystemStateUuid,
        data: [0x04],
        brand: AirbagBrand.alpinestars,
      );

      expect(bridge.isDeployed, isFalse);
      expect(mockSafety.impactCalls, isEmpty);
    });

    test('TEST-AB-17: Cartridge fault/diagnostic errors transition to fault state without deployment', () {
      bridge.connect(
        deviceId: 'BLE:HELITE:001',
        name: 'Helite e-Turtle',
        brand: AirbagBrand.helite,
        batteryLevel: 75,
      );

      // Helite mode 0x03 = Sensor / Cartridge fault
      bridge.processGattNotification(
        characteristicUuid: AirbagGattConstants.heliteTriggerUuid,
        data: [0x03],
      );

      expect(bridge.connectionState, equals(AirbagConnectionState.fault));
      expect(bridge.isDeployed, isFalse);
      expect(bridge.telemetry.systemState, equals(AirbagSystemState.fault));
      expect(mockSafety.impactCalls, isEmpty);
    });
  });

  group('FEAT-06: Disconnect Handling & Recovery', () {
    test('TEST-AB-18: Disconnect event updates state and clears armed status', () {
      bridge.connect(
        deviceId: 'BLE:TECHAIR:005',
        name: 'Alpinestars Tech-Air 5',
        brand: AirbagBrand.alpinestars,
        batteryLevel: 88,
        isArmed: true,
      );

      expect(bridge.isConnected, isTrue);
      expect(bridge.isArmed, isTrue);

      bridge.handleDisconnectEvent();

      expect(bridge.connectionState, equals(AirbagConnectionState.disconnected));
      expect(bridge.isConnected, isFalse);
      expect(bridge.isArmed, isFalse);
    });

    test('TEST-AB-19: Reconnect restores connection and armed state', () {
      bridge.connect(
        deviceId: 'BLE:INMOTION:001',
        name: 'Klim Ai-1 Airbag',
        brand: AirbagBrand.inMotion,
        serialNumber: 'IN-7788',
        batteryLevel: 92,
        isArmed: true,
      );

      bridge.disconnect();
      expect(bridge.isConnected, isFalse);

      bridge.reconnect();
      expect(bridge.isConnected, isTrue);
      expect(bridge.isArmed, isTrue);
      expect(bridge.telemetry.modelName, equals('Klim Ai-1 Airbag'));
      expect(bridge.telemetry.serialNumber, equals('IN-7788'));
      expect(bridge.batteryLevel, equals(92));
    });
  });

  group('FEAT-06: Cockpit HUD Pill Widget Integration', () {
    testWidgets('TEST-AB-20: Renders [ 🦺 Airbag Vest Connected ] indicator with battery level and armed status', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SmartAirbagHudPill(
                connectionState: AirbagConnectionState.connected,
                telemetry: const AirbagTelemetry(
                  modelName: 'Klim Ai-1 Airbag',
                  batteryLevel: 90,
                  isArmed: true,
                  brand: AirbagBrand.inMotion,
                  systemState: AirbagSystemState.armed,
                ),
                batteryLevel: 90,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(SmartAirbagHudPill), findsOneWidget);
      expect(find.textContaining('🦺 Airbag Vest Connected'), findsOneWidget);
      expect(find.textContaining('Armed'), findsOneWidget);
      expect(find.textContaining('90%'), findsOneWidget);
      expect(find.byIcon(Icons.shield_rounded), findsOneWidget);
    });

    testWidgets('TEST-AB-21: Renders Disarmed state when vest zipper/magnet is uncoupled', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SmartAirbagHudPill(
                connectionState: AirbagConnectionState.connected,
                telemetry: const AirbagTelemetry(
                  modelName: 'Alpinestars Tech-Air 5',
                  batteryLevel: 85,
                  isArmed: false,
                  brand: AirbagBrand.alpinestars,
                  systemState: AirbagSystemState.disarmed,
                ),
                batteryLevel: 85,
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining('🦺 Airbag Vest Connected'), findsOneWidget);
      expect(find.textContaining('Disarmed'), findsOneWidget);
      expect(find.textContaining('85%'), findsOneWidget);
      expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
    });

    testWidgets('TEST-AB-22: Renders Deployed emergency indicator upon crash inflation', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SmartAirbagHudPill(
                connectionState: AirbagConnectionState.deployed,
                telemetry: const AirbagTelemetry(
                  modelName: 'Dainese D-air Smart Jacket',
                  batteryLevel: 75,
                  isArmed: true,
                  isDeployed: true,
                  brand: AirbagBrand.dainese,
                  systemState: AirbagSystemState.deployed,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining('🚨 AIRBAG DEPLOYED'), findsOneWidget);
      expect(find.byIcon(Icons.emergency_rounded), findsOneWidget);
    });

    testWidgets('TEST-AB-23: Renders Fault indicator when canister or sensor diagnostic fails', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SmartAirbagHudPill(
                connectionState: AirbagConnectionState.fault,
                telemetry: const AirbagTelemetry(
                  modelName: 'Helite e-Turtle',
                  batteryLevel: 60,
                  isArmed: false,
                  brand: AirbagBrand.helite,
                  systemState: AirbagSystemState.fault,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining('⚠️ AIRBAG FAULT'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });
  });
}
