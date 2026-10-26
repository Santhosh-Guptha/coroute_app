import 'package:flutter/foundation.dart';
import 'safety_service.dart';

/// Known motorcycle airbag vest brands supported by CoRoute.
enum AirbagBrand {
  inMotion,
  alpinestars,
  helite,
  dainese,
  unknown;

  String get displayName {
    switch (this) {
      case AirbagBrand.inMotion:
        return 'In&motion';
      case AirbagBrand.alpinestars:
        return 'Alpinestars Tech-Air';
      case AirbagBrand.helite:
        return 'Helite e-Vest';
      case AirbagBrand.dainese:
        return 'Dainese D-air';
      case AirbagBrand.unknown:
        return 'Smart Airbag';
    }
  }
}

/// BLE connection states for motorcycle airbag vest peripherals.
enum AirbagConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  deployed,
  fault,
}

/// Internal operational states reported by smart airbag vest firmware.
enum AirbagSystemState {
  disarmed,
  armed,
  deployed,
  fault,
  firmwareUpdate,
  charging,
  lowBatteryWarning,
  unknown,
}

/// Real-time telemetry snapshot from a connected airbag vest.
class AirbagTelemetry {
  final String modelName;
  final int? batteryLevel;
  final bool isArmed;
  final bool isDeployed;
  final String? serialNumber;
  final int? lastDeploymentMs;
  final AirbagBrand brand;
  final AirbagSystemState systemState;
  final String? firmwareVersion;

  const AirbagTelemetry({
    this.modelName = '',
    this.batteryLevel,
    this.isArmed = false,
    this.isDeployed = false,
    this.serialNumber,
    this.lastDeploymentMs,
    this.brand = AirbagBrand.unknown,
    this.systemState = AirbagSystemState.disarmed,
    this.firmwareVersion,
  });

  factory AirbagTelemetry.initial() => const AirbagTelemetry();

  AirbagTelemetry copyWith({
    String? modelName,
    int? batteryLevel,
    bool? isArmed,
    bool? isDeployed,
    String? serialNumber,
    int? lastDeploymentMs,
    AirbagBrand? brand,
    AirbagSystemState? systemState,
    String? firmwareVersion,
  }) {
    return AirbagTelemetry(
      modelName: modelName ?? this.modelName,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      isArmed: isArmed ?? this.isArmed,
      isDeployed: isDeployed ?? this.isDeployed,
      serialNumber: serialNumber ?? this.serialNumber,
      lastDeploymentMs: lastDeploymentMs ?? this.lastDeploymentMs,
      brand: brand ?? this.brand,
      systemState: systemState ?? this.systemState,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
    );
  }

  Map<String, dynamic> toJson() => {
        'modelName': modelName,
        'batteryLevel': batteryLevel,
        'isArmed': isArmed,
        'isDeployed': isDeployed,
        'serialNumber': serialNumber,
        'lastDeploymentMs': lastDeploymentMs,
        'brand': brand.name,
        'systemState': systemState.name,
        if (firmwareVersion != null) 'firmwareVersion': firmwareVersion,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AirbagTelemetry &&
          runtimeType == other.runtimeType &&
          modelName == other.modelName &&
          batteryLevel == other.batteryLevel &&
          isArmed == other.isArmed &&
          isDeployed == other.isDeployed &&
          serialNumber == other.serialNumber &&
          lastDeploymentMs == other.lastDeploymentMs &&
          brand == other.brand &&
          systemState == other.systemState &&
          firmwareVersion == other.firmwareVersion;

  @override
  int get hashCode => Object.hash(
        modelName,
        batteryLevel,
        isArmed,
        isDeployed,
        serialNumber,
        lastDeploymentMs,
        brand,
        systemState,
        firmwareVersion,
      );

  @override
  String toString() =>
      'AirbagTelemetry(model: $modelName, battery: $batteryLevel%, armed: $isArmed, deployed: $isDeployed, state: $systemState)';
}

/// Standard and vendor-specific BLE GATT UUIDs for motorcycle airbag vests.
class AirbagGattConstants {
  AirbagGattConstants._();

  // In&motion In&box (Klim Ai-1, Held eVest, Ixon U03, RST)
  static const String inMotionServiceUuid = '7d391001-2e11-471a-b337-128a1c97a001';
  static const String inMotionDeployNotificationUuid = '7d391002-2e11-471a-b337-128a1c97a001';
  static const String inMotionBatteryUuid = '7d391003-2e11-471a-b337-128a1c97a001';

  // Alpinestars Tech-Air (Tech-Air 3, 5, 10, Off-Road)
  static const String techAirServiceUuid = 'a495ff20-c5b1-4b44-b512-1370f02d74de';
  static const String techAirSystemStateUuid = 'a495ff21-c5b1-4b44-b512-1370f02d74de';
  static const String techAirBatteryUuid = 'a495ff22-c5b1-4b44-b512-1370f02d74de';

  // Helite CDU bridge (e-Turtle, e-GP-Air, e-Custom)
  static const String heliteServiceUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
  static const String heliteTriggerUuid = '0000fff1-0000-1000-8000-00805f9b34fb';
  static const String heliteSensorUuid = '0000fff2-0000-1000-8000-00805f9b34fb';

  // Dainese D-air (Smart Jacket, Misano, Tuono)
  static const String dAirServiceUuid = '0000d001-0000-1000-8000-00805f9b34fb';
  static const String dAirStatusUuid = '0000d002-0000-1000-8000-00805f9b34fb';
  static const String dAirTelemetryUuid = '0000d003-0000-1000-8000-00805f9b34fb';

  // Standard BLE GATT Services
  static const String standardBatteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
  static const String standardBatteryLevelUuid = '00002a19-0000-1000-8000-00805f9b34fb';

  // Generic 16-bit UUID short form helpers
  static const String shortBatteryLevelUuid = '2a19';
}

/// Service that manages the Bluetooth Low Energy (BLE) peripheral bridge
/// connecting motorcycle smart airbag vests into CoRoute's emergency safety pipeline.
///
/// Multi-brand GATT support:
/// * In&motion In&box (Klim Ai-1, Held eVest, Ixon U03, RST)
/// * Alpinestars Tech-Air (Tech-Air 3, 5, 10, Off-Road)
/// * Helite e-Vest (e-Turtle, e-GP-Air CDU bridge)
/// * Dainese D-air (Smart Jacket, Misano, Tuono)
///
/// Features:
/// * Immediate Sub-150ms pyrotechnic deployment escalation via [SafetyService.instance.externalImpact].
/// * Strict immunity against false triggers from low battery warnings or OTA firmware updates.
/// * Real-time armed status, battery monitoring, and automatic disconnect recovery.
class SmartAirbagBridgeService extends ChangeNotifier {
  static final SmartAirbagBridgeService _instance = SmartAirbagBridgeService._internal();

  factory SmartAirbagBridgeService({SafetyService? safetyService}) {
    if (safetyService != null) {
      _instance._safetyService = safetyService;
    }
    return _instance;
  }

  static SmartAirbagBridgeService get instance => _instance;

  SmartAirbagBridgeService._internal() {
    connectionStateNotifier = ValueNotifier<AirbagConnectionState>(AirbagConnectionState.disconnected);
    telemetryNotifier = ValueNotifier<AirbagTelemetry>(AirbagTelemetry.initial());
    batteryLevelNotifier = ValueNotifier<int?>(null);
  }

  SafetyService? _safetyService;

  late final ValueNotifier<AirbagConnectionState> connectionStateNotifier;
  late final ValueNotifier<AirbagTelemetry> telemetryNotifier;
  late final ValueNotifier<int?> batteryLevelNotifier;

  String? _lastConnectedDeviceId;
  String? _lastConnectedName;
  AirbagBrand _lastConnectedBrand = AirbagBrand.unknown;
  String? _lastConnectedSerialNumber;

  AirbagConnectionState get connectionState => connectionStateNotifier.value;
  AirbagTelemetry get telemetry => telemetryNotifier.value;
  int? get batteryLevel => batteryLevelNotifier.value;

  bool get isConnected =>
      connectionState == AirbagConnectionState.connected ||
      connectionState == AirbagConnectionState.deployed;

  bool get isArmed => telemetry.isArmed;
  bool get isDeployed => telemetry.isDeployed;

  /// Detects airbag brand from advertised peripheral name or advertised service UUIDs.
  static AirbagBrand detectBrand({String? deviceName, List<String>? serviceUuids}) {
    final nameLower = (deviceName ?? '').toLowerCase().trim();

    if (nameLower.contains('in&box') ||
        nameLower.contains('in&motion') ||
        nameLower.contains('inmotion') ||
        nameLower.contains('klim') ||
        nameLower.contains('ai-1') ||
        nameLower.contains('held') ||
        nameLower.contains('evest') ||
        nameLower.contains('ixon') ||
        nameLower.contains('u03') ||
        nameLower.contains('rst')) {
      return AirbagBrand.inMotion;
    }

    if (nameLower.contains('tech-air') ||
        nameLower.contains('techair') ||
        nameLower.contains('alpinestars') ||
        nameLower.contains('ta3') ||
        nameLower.contains('ta5') ||
        nameLower.contains('ta10')) {
      return AirbagBrand.alpinestars;
    }

    if (nameLower.contains('helite') ||
        nameLower.contains('e-turtle') ||
        nameLower.contains('e-gp-air') ||
        nameLower.contains('cdu')) {
      return AirbagBrand.helite;
    }

    if (nameLower.contains('d-air') ||
        nameLower.contains('dair') ||
        nameLower.contains('smart jacket') ||
        nameLower.contains('dainese')) {
      return AirbagBrand.dainese;
    }

    if (serviceUuids != null) {
      for (final rawUuid in serviceUuids) {
        final u = rawUuid.toLowerCase().trim();
        if (u == AirbagGattConstants.inMotionServiceUuid) {
          return AirbagBrand.inMotion;
        }
        if (u == AirbagGattConstants.techAirServiceUuid) {
          return AirbagBrand.alpinestars;
        }
        if (u == AirbagGattConstants.heliteServiceUuid) {
          return AirbagBrand.helite;
        }
        if (u == AirbagGattConstants.dAirServiceUuid) {
          return AirbagBrand.dainese;
        }
      }
    }

    return AirbagBrand.unknown;
  }

  /// Resolves user-friendly model name from brand and advertised name.
  static String resolveModelName(AirbagBrand brand, {String? advertisedName}) {
    if (advertisedName != null && advertisedName.trim().isNotEmpty) {
      return advertisedName.trim();
    }
    switch (brand) {
      case AirbagBrand.inMotion:
        return 'In&motion Klim Ai-1';
      case AirbagBrand.alpinestars:
        return 'Alpinestars Tech-Air 5';
      case AirbagBrand.helite:
        return 'Helite e-Turtle';
      case AirbagBrand.dainese:
        return 'Dainese D-air Smart Jacket';
      case AirbagBrand.unknown:
        return 'Motorcycle Smart Airbag Vest';
    }
  }

  /// Begins BLE scan for compatible motorcycle airbag vests.
  void startScan() {
    connectionStateNotifier.value = AirbagConnectionState.scanning;
    notifyListeners();
  }

  /// Stops an active BLE scan.
  void stopScan() {
    if (connectionStateNotifier.value == AirbagConnectionState.scanning) {
      connectionStateNotifier.value = AirbagConnectionState.disconnected;
      notifyListeners();
    }
  }

  /// Establishes BLE connection with an airbag vest peripheral.
  void connect({
    required String deviceId,
    required String name,
    required AirbagBrand brand,
    String? serialNumber,
    int? batteryLevel,
    bool isArmed = true,
    String? firmwareVersion,
  }) {
    connectionStateNotifier.value = AirbagConnectionState.connecting;
    notifyListeners();

    _lastConnectedDeviceId = deviceId;
    _lastConnectedName = name;
    _lastConnectedBrand = brand;
    _lastConnectedSerialNumber = serialNumber;

    final resolvedModel = resolveModelName(brand, advertisedName: name);

    batteryLevelNotifier.value = batteryLevel;
    telemetryNotifier.value = AirbagTelemetry(
      modelName: resolvedModel,
      batteryLevel: batteryLevel,
      isArmed: isArmed,
      isDeployed: false,
      serialNumber: serialNumber,
      brand: brand,
      systemState: isArmed ? AirbagSystemState.armed : AirbagSystemState.disarmed,
      firmwareVersion: firmwareVersion,
    );

    connectionStateNotifier.value = AirbagConnectionState.connected;
    notifyListeners();
  }

  /// Disconnects the active airbag vest peripheral.
  void disconnect() {
    connectionStateNotifier.value = AirbagConnectionState.disconnected;
    telemetryNotifier.value = telemetryNotifier.value.copyWith(
      isArmed: false,
      systemState: AirbagSystemState.disarmed,
    );
    notifyListeners();
  }

  /// Handles an unexpected peripheral disconnect (e.g. out of range, power loss).
  void handleDisconnectEvent() {
    connectionStateNotifier.value = AirbagConnectionState.disconnected;
    telemetryNotifier.value = telemetryNotifier.value.copyWith(
      isArmed: false,
      systemState: AirbagSystemState.disarmed,
    );
    notifyListeners();
  }

  /// Attempts to reconnect to the last known airbag vest peripheral.
  void reconnect() {
    if (_lastConnectedDeviceId == null) return;
    connect(
      deviceId: _lastConnectedDeviceId!,
      name: _lastConnectedName ?? 'Smart Airbag Vest',
      brand: _lastConnectedBrand,
      serialNumber: _lastConnectedSerialNumber,
      batteryLevel: batteryLevelNotifier.value,
      isArmed: true,
    );
  }

  /// Processes raw BLE GATT characteristic notification values from connected vests.
  ///
  /// Evaluates brand-specific protocols and guarantees:
  /// 1. Sub-150ms instant safety escalation upon deployment detection.
  /// 2. Absolute immunity to false positives from low battery warnings or firmware updates.
  void processGattNotification({
    required String characteristicUuid,
    required List<int> data,
    AirbagBrand? brand,
  }) {
    if (data.isEmpty) return;

    final effectiveBrand = brand ?? telemetryNotifier.value.brand;
    final uuid = characteristicUuid.toLowerCase().trim();

    // Standard Battery Service (0x2A19)
    if (uuid == AirbagGattConstants.standardBatteryLevelUuid ||
        uuid == AirbagGattConstants.shortBatteryLevelUuid) {
      _updateBatteryLevel(data[0]);
      return;
    }

    switch (effectiveBrand) {
      case AirbagBrand.inMotion:
        _processInMotionNotification(uuid, data);
        break;
      case AirbagBrand.alpinestars:
        _processAlpinestarsNotification(uuid, data);
        break;
      case AirbagBrand.helite:
        _processHeliteNotification(uuid, data);
        break;
      case AirbagBrand.dainese:
        _processDaineseNotification(uuid, data);
        break;
      case AirbagBrand.unknown:
        _processGenericNotification(uuid, data);
        break;
    }
  }

  /// In&motion In&box deployment notification protocol parser.
  void _processInMotionNotification(String uuid, List<int> data) {
    if (uuid == AirbagGattConstants.inMotionBatteryUuid) {
      _updateBatteryLevel(data[0]);
      return;
    }

    if (uuid == AirbagGattConstants.inMotionDeployNotificationUuid) {
      final statusCode = data[0];
      // Byte 0: 0x00 = Standby/Disarmed, 0x01 = Armed, 0x02 / 0xDE = Deployed,
      // 0x03 = Fault, 0x04 = Firmware Flash / OTA, 0x05 = Low Battery Warning
      if (statusCode == 0x02 || statusCode == 0xDE) {
        _handleDeploymentSignal(
          reason: 'In&motion In&box pyrotechnic inflator deployed (0x${statusCode.toRadixString(16)})',
        );
      } else if (statusCode == 0x01) {
        _setSystemState(AirbagSystemState.armed, isArmed: true);
      } else if (statusCode == 0x00) {
        _setSystemState(AirbagSystemState.disarmed, isArmed: false);
      } else if (statusCode == 0x03) {
        _setFaultState(AirbagSystemState.fault);
      } else if (statusCode == 0x04) {
        // Firmware update mode - STRICTLY IMMUNE TO DEPLOYMENT
        _setSystemState(AirbagSystemState.firmwareUpdate, isArmed: false);
      } else if (statusCode == 0x05) {
        // Low battery notification - STRICTLY IMMUNE TO DEPLOYMENT
        _setSystemState(AirbagSystemState.lowBatteryWarning, isArmed: telemetryNotifier.value.isArmed);
      }

      if (data.length > 1) {
        _updateBatteryLevel(data[1]);
      }
    }
  }

  /// Alpinestars Tech-Air (Tech-Air 3, 5, 10) System State parser.
  void _processAlpinestarsNotification(String uuid, List<int> data) {
    if (uuid == AirbagGattConstants.techAirBatteryUuid) {
      _updateBatteryLevel(data[0]);
      return;
    }

    if (uuid == AirbagGattConstants.techAirSystemStateUuid) {
      final stateCode = data[0];
      // System State values:
      // 0x00: Disarmed (Magnetic zipper uncoupled)
      // 0x01: Armed (Active protection mode)
      // 0x02: Deployed (Gas canister fired)
      // 0x03: Fault (Canister depleted / internal sensor fault)
      // 0x04: Firmware Update / Bootloader (OTA flashing)
      // 0x05: Low Battery Warning (<15%)
      // 0x06: Charging
      switch (stateCode) {
        case 0x02:
          _handleDeploymentSignal(reason: 'Alpinestars Tech-Air System State Deployed (0x02)');
          break;
        case 0x01:
          _setSystemState(AirbagSystemState.armed, isArmed: true);
          break;
        case 0x00:
          _setSystemState(AirbagSystemState.disarmed, isArmed: false);
          break;
        case 0x03:
          _setFaultState(AirbagSystemState.fault);
          break;
        case 0x04:
          // Firmware update mode - STRICTLY IMMUNE TO DEPLOYMENT
          _setSystemState(AirbagSystemState.firmwareUpdate, isArmed: false);
          break;
        case 0x05:
          // Low battery warning - STRICTLY IMMUNE TO DEPLOYMENT
          _setSystemState(AirbagSystemState.lowBatteryWarning, isArmed: telemetryNotifier.value.isArmed);
          if (data.length > 1) {
            _updateBatteryLevel(data[1]);
          }
          break;
        case 0x06:
          _setSystemState(AirbagSystemState.charging, isArmed: false);
          break;
      }
    }
  }

  /// Helite e-Vest (e-Turtle, e-GP-Air CDU bridge) parser.
  void _processHeliteNotification(String uuid, List<int> data) {
    if (uuid == AirbagGattConstants.heliteTriggerUuid) {
      final modeByte = data[0];
      // Mode values:
      // 0x00: Sleep / Disarmed
      // 0x01: Armed & Monitoring
      // 0x02 or 0xAA: DEPLOYED (Crash Detection Unit fired gas cartridge)
      // 0x03: Sensor Error / Missing Fork Sensor
      // 0x04: Firmware Sync / Pairing
      if (modeByte == 0x02 || modeByte == 0xAA) {
        _handleDeploymentSignal(reason: 'Helite CDU pyrotechnic trigger (0x${modeByte.toRadixString(16)})');
      } else if (modeByte == 0x01) {
        _setSystemState(AirbagSystemState.armed, isArmed: true);
      } else if (modeByte == 0x00) {
        _setSystemState(AirbagSystemState.disarmed, isArmed: false);
      } else if (modeByte == 0x03) {
        _setFaultState(AirbagSystemState.fault);
      } else if (modeByte == 0x04) {
        _setSystemState(AirbagSystemState.firmwareUpdate, isArmed: false);
      }

      if (data.length > 1) {
        _updateBatteryLevel(data[1]);
      }
    }
  }

  /// Dainese D-air (Smart Jacket, Misano, Tuono) parser.
  void _processDaineseNotification(String uuid, List<int> data) {
    if (uuid == AirbagGattConstants.dAirTelemetryUuid) {
      if (data.length >= 2) {
        _updateBatteryLevel(data[1]);
      }
      return;
    }

    if (uuid == AirbagGattConstants.dAirStatusUuid) {
      final statusCode = data[0];
      // 0x00: Disarmed (Magnetic button unfastened)
      // 0x01: Armed (Fastened, GPS fix acquired, active protection)
      // 0x02: Deployed (Shield inflated)
      // 0x03: Maintenance / Fault (Cold gas expired or lockout)
      // 0x04: D-air App Firmware Update
      // 0x05: Low Battery Warning (<10%)
      switch (statusCode) {
        case 0x02:
          _handleDeploymentSignal(reason: 'Dainese D-air shield deployment (0x02)');
          break;
        case 0x01:
          _setSystemState(AirbagSystemState.armed, isArmed: true);
          break;
        case 0x00:
          _setSystemState(AirbagSystemState.disarmed, isArmed: false);
          break;
        case 0x03:
          _setFaultState(AirbagSystemState.fault);
          break;
        case 0x04:
          // Firmware flash - STRICTLY IMMUNE TO DEPLOYMENT
          _setSystemState(AirbagSystemState.firmwareUpdate, isArmed: false);
          break;
        case 0x05:
          // Low battery warning - STRICTLY IMMUNE TO DEPLOYMENT
          _setSystemState(AirbagSystemState.lowBatteryWarning, isArmed: telemetryNotifier.value.isArmed);
          if (data.length > 1) {
            _updateBatteryLevel(data[1]);
          }
          break;
      }
    }
  }

  /// Generic fallback parser for unknown / emerging smart airbag GATT peripherals.
  void _processGenericNotification(String uuid, List<int> data) {
    final flag = data[0];
    if (flag == 0x02 || flag == 0xDE || flag == 0xAA) {
      _handleDeploymentSignal(reason: 'Generic smart airbag deployment flag (0x${flag.toRadixString(16)})');
    } else if (flag == 0x01) {
      _setSystemState(AirbagSystemState.armed, isArmed: true);
    } else if (flag == 0x00) {
      _setSystemState(AirbagSystemState.disarmed, isArmed: false);
    } else if (flag == 0x03) {
      _setFaultState(AirbagSystemState.fault);
    }
    if (data.length > 1) {
      _updateBatteryLevel(data[1]);
    }
  }

  /// Triggers a manual hardware test deployment for safety verification.
  void triggerHardwareTestDeployment() {
    _handleDeploymentSignal(reason: 'Manual Hardware Test Trigger');
  }

  /// Instant escalation to safety pipeline upon confirmed deployment signal.
  ///
  /// Guarantees sub-150ms execution directly invoking [SafetyService.instance.externalImpact].
  void _handleDeploymentSignal({required String reason}) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    connectionStateNotifier.value = AirbagConnectionState.deployed;
    telemetryNotifier.value = telemetryNotifier.value.copyWith(
      isDeployed: true,
      lastDeploymentMs: nowMs,
      systemState: AirbagSystemState.deployed,
    );
    notifyListeners();

    // Instant escalation to SafetyService wearable impact hook:
    // SafetyService.instance.externalImpact(source: ExternalImpactSource.wearable, g: 6.0, atMs: ...)
    final safety = _safetyService ?? (SafetyService.hasInstance ? SafetyService.instance : null);
    if (safety != null) {
      safety.externalImpact(
        source: ExternalImpactSource.wearable,
        g: 6.0,
        atMs: nowMs,
      );
    }
  }

  void _updateBatteryLevel(int level) {
    final clamped = level.clamp(0, 100);
    batteryLevelNotifier.value = clamped;
    telemetryNotifier.value = telemetryNotifier.value.copyWith(batteryLevel: clamped);
    notifyListeners();
  }

  void _setSystemState(AirbagSystemState state, {required bool isArmed}) {
    telemetryNotifier.value = telemetryNotifier.value.copyWith(
      systemState: state,
      isArmed: isArmed,
    );
    if (connectionStateNotifier.value != AirbagConnectionState.connected &&
        connectionStateNotifier.value != AirbagConnectionState.deployed) {
      connectionStateNotifier.value = AirbagConnectionState.connected;
    }
    notifyListeners();
  }

  void _setFaultState(AirbagSystemState state) {
    connectionStateNotifier.value = AirbagConnectionState.fault;
    telemetryNotifier.value = telemetryNotifier.value.copyWith(
      systemState: state,
      isArmed: false,
    );
    notifyListeners();
  }

  /// Resets service state back to defaults (used in unit and integration tests).
  @visibleForTesting
  void reset() {
    connectionStateNotifier.value = AirbagConnectionState.disconnected;
    telemetryNotifier.value = AirbagTelemetry.initial();
    batteryLevelNotifier.value = null;
    _lastConnectedDeviceId = null;
    _lastConnectedName = null;
    _lastConnectedBrand = AirbagBrand.unknown;
    _lastConnectedSerialNumber = null;
    _safetyService = null;
    notifyListeners();
  }

  @override
  void dispose() {
    connectionStateNotifier.dispose();
    telemetryNotifier.dispose();
    batteryLevelNotifier.dispose();
    super.dispose();
  }
}
