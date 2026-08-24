import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_store.dart';

const String kDefaultUser = 'HUBDNI';
const String kAdminUser = 'ADMIN';
const String kWarehouseVf = 'VF_E2W';
const String kWarehouseAuto = 'AUTO_EV';
const String kWarehouseVfLabel = 'PIN XE MÁY ĐIỆN VINFAST';
const String kWarehouseAutoLabel = 'PIN Ô TÔ ĐIỆN VINFAST';
const String kSupabaseProjectUrl = 'https://adixviiotaldvxcgshyt.supabase.co';
const String kSupabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFkaXh2aWlvdGFsZHZ4Y2dzaHl0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcyMjIyNDEsImV4cCI6MjEwMjc5ODI0MX0.1rKqUezdnRDCglDISDNvic9rkmUkDe_veuiJspR-AWk';
const String kSupabaseApiUrl = '${kSupabaseProjectUrl}/functions/v1/n07-api-v4';
const String kSupabaseHistoryUrl = '${kSupabaseProjectUrl}/functions/v1/n07-history-v4';
const String kSupabaseSyncUrl = '${kSupabaseProjectUrl}/functions/v1/n07-sync-v2';
const String kBuiltInVfServerUrl = kSupabaseApiUrl;
const String kBuiltInAutoServerUrl = kSupabaseApiUrl;
// Alias giữ tương thích code cũ: cấu hình mặc định luôn là User Master VF_E2W.
const String kBuiltInServerUrl = kBuiltInVfServerUrl;

String warehouseLabel(String warehouseId) {
  if (warehouseId == kWarehouseVf) return kWarehouseVfLabel;
  if (warehouseId == kWarehouseAuto) return kWarehouseAutoLabel;
  return 'KHO KHÔNG HỢP LỆ';
}

String warehouseCellTerm(String warehouseId) =>
    warehouseId == kWarehouseAuto ? 'Vị trí' : 'Ô';

const int kVfCellsPerAisle = 4;
const int kAutoDefaultPositionsPerAisle = 4;
const int kAutoMaxPositionsPerAisle = 6;

int warehouseDefaultCellCount(String warehouseId) =>
    warehouseId == kWarehouseAuto
        ? kAutoDefaultPositionsPerAisle
        : kVfCellsPerAisle;

int warehouseDefaultCapacity(String warehouseId) =>
    kAislesPerShelf * warehouseDefaultCellCount(warehouseId) * kPinsPerCell;

const int kAislesPerShelf = 6;
const int kRowsPerAisle = 10;
const int kLegacyAislesPerShelf = 3;
const int kLegacyRowsPerAisle = 6;
const int kCellsPerRow = 4;

// V10: mỗi Ô có 18 vị trí pin.
// Giữ nguyên 100% slot V8/V9 cho pin 01-16, chỉ cấp vùng slot mới cho pin 17-18.
const int kBasePinsPerCell = 16;
const int kPinsPerCell = 18;
const int kExtraPinsPerCell = kPinsPerCell - kBasePinsPerCell;

const int kLegacyPinsPerAisle =
    kLegacyRowsPerAisle * kCellsPerRow * kBasePinsPerCell;
const int kLegacySlotsPerLocation =
    kLegacyAislesPerShelf * kLegacyPinsPerAisle;
const int kExtendedRowsSlots =
    kLegacyAislesPerShelf *
    (kRowsPerAisle - kLegacyRowsPerAisle) *
    kCellsPerRow *
    kBasePinsPerCell;
const int kBaseSlotsPerLocation =
    kAislesPerShelf * kRowsPerAisle * kCellsPerRow * kBasePinsPerCell;
const int kExtraSlotsPerLocation =
    kAislesPerShelf * kRowsPerAisle * kCellsPerRow * kExtraPinsPerCell;
const int kSlotsPerLocation =
    kBaseSlotsPerLocation + kExtraSlotsPerLocation;
const int kRequiredApiVersion = 25;
const Duration kManualAutoUploadDelay = Duration(minutes: 5);
const Duration kAutoUploadPollInterval = Duration(seconds: 5);
const Duration kForegroundSyncInterval = Duration(seconds: 60);
const Duration kNormalSyncThrottle = Duration(seconds: 30);
const int kMaxDeltaPagesPerSync = 5;
const int kAutoUploadMaxOpsPerPass = 200;
const Duration kRememberLoginDuration = Duration(hours: 24); // upper bound; actual session is capped at Vietnam midnight

const Set<String> kAndroidFieldFeatures = {
  'LOGIN',
  'WAREHOUSE_SWITCH',
  'NHAP_PIN',
  'XUAT_PIN',
  'TON_KHO',
  'TIM_PIN',
  'VI_TRI_READ_ONLY',
  'KIEM_KE',
  'LICH_SU',
  'PENDING_CONFIRMATION',
  'VF_QR_PAIR_CHECK',
};

const Set<String> kPcOnlyFeatures = {
  'LOCATION_CREATE_DELETE',
  'LAYOUT_EDIT',
  'LOCATION_LABEL_EDIT',
  'USER_ADMIN',
  'BACKEND_ADMIN',
  'SERVER_MASTER',
  'EXCEL_EXPORT',
};

bool isValidAppsScriptWebUrl(String value) {
  final clean = value.trim();
  return clean.startsWith('https://') && clean.contains('/functions/v1/');
}

String normalizeQrForComparison(String value) => value.trim();

bool qrCodesMatchExact(String cartonQr, String batteryQr) {
  final carton = normalizeQrForComparison(cartonQr);
  final battery = normalizeQrForComparison(batteryQr);
  return carton.isNotEmpty && carton == battery;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalWarehouseStore.instance.init(warehouseId: kWarehouseVf);
  runApp(const N07App());
}

class N07App extends StatefulWidget {
  const N07App({super.key});

  @override
  State<N07App> createState() => _N07AppState();
}

class _N07AppState extends State<N07App> {
  bool _loading = true;
  String _serverUrl = '';
  String _autoServerUrl = kBuiltInAutoServerUrl;
  String _deviceId = '';
  UserAccount? _rememberedUser;
  String _rememberedSessionToken = '';
  int _sessionExpiresAtMs = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString('n07_device_id') ?? '';
    if (deviceId.isEmpty) {
      deviceId =
          'N07-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(999999)}';
      await prefs.setString('n07_device_id', deviceId);
    }

    // Giữ override hợp lệ đã được ADMIN lưu từ bản cũ để tương thích nâng cấp.
    // V14 chỉ hiển thị trạng thái kết nối, không cho sửa URL trên điện thoại.
    final hasAdminOverride =
        prefs.getBool('n07_server_url_custom') ?? false;
    final savedUrl = (prefs.getString('n07_server_url') ?? '').trim();
    final serverUrl = hasAdminOverride && isValidAppsScriptWebUrl(savedUrl)
        ? savedUrl
        : kBuiltInServerUrl;

    await prefs.setString('n07_server_url', serverUrl);
    if (!hasAdminOverride) {
      await prefs.setBool('n07_server_url_custom', false);
    }

    final savedAutoUrl = (prefs.getString('n07_auto_server_url') ?? '').trim();
    final autoServerUrl = isValidAppsScriptWebUrl(savedAutoUrl)
        ? savedAutoUrl
        : kBuiltInAutoServerUrl;
    await prefs.setString('n07_auto_server_url', autoServerUrl);

    UserAccount? rememberedUser;
    var rememberedToken = '';
    var expiresAtMs = prefs.getInt('n07_session_expires_ms') ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (expiresAtMs > nowMs) {
      rememberedToken = (prefs.getString('n07_session_token') ?? '').trim();
      final rawUser = prefs.getString('n07_session_user_json') ?? '';
      if (rememberedToken.isNotEmpty && rawUser.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawUser);
          if (decoded is Map) {
            final user = UserAccount.fromJson(
              Map<String, dynamic>.from(decoded),
            );
            if (user.active && user.id.isNotEmpty) rememberedUser = user;
          }
        } catch (_) {}
      }
    }

    if (rememberedUser != null &&
        rememberedToken.isNotEmpty &&
        !await LocalWarehouseStore.instance.hasSnapshot()) {
      rememberedUser = null;
      rememberedToken = '';
    }

    if (rememberedUser == null || rememberedToken.isEmpty) {
      expiresAtMs = 0;
      await prefs.remove('n07_session_user_json');
      await prefs.remove('n07_session_token');
      await prefs.remove('n07_session_expires_ms');
    }

    if (!mounted) return;
    setState(() {
      _serverUrl = serverUrl;
      _autoServerUrl = autoServerUrl;
      _deviceId = deviceId;
      _rememberedUser = rememberedUser;
      _rememberedSessionToken = rememberedToken;
      _sessionExpiresAtMs = expiresAtMs;
      _loading = false;
    });
  }

  Future<int> _rememberSession(
    UserAccount user,
    String sessionToken,
  ) async {
    final nowUtc = DateTime.now().toUtc();
    final vietnamNow = nowUtc.add(const Duration(hours: 7));
    final nextVietnamMidnight = DateTime.utc(
      vietnamNow.year,
      vietnamNow.month,
      vietnamNow.day + 1,
    ).subtract(const Duration(hours: 7));
    final expiresAt = nextVietnamMidnight.millisecondsSinceEpoch;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'n07_session_user_json',
      jsonEncode(user.toJson()),
    );
    await prefs.setString('n07_session_token', sessionToken);
    await prefs.setInt('n07_session_expires_ms', expiresAt);
    if (mounted) {
      setState(() {
        _rememberedUser = user;
        _rememberedSessionToken = sessionToken;
        _sessionExpiresAtMs = expiresAt;
      });
    }
    return expiresAt;
  }

  Future<void> _clearRememberedSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('n07_session_user_json');
    await prefs.remove('n07_session_token');
    await prefs.remove('n07_session_expires_ms');
    if (mounted) {
      setState(() {
        _rememberedUser = null;
        _rememberedSessionToken = '';
        _sessionExpiresAtMs = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'N07 HUBDNI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffb71c1c),
        ),
        scaffoldBackgroundColor: Colors.transparent,
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          backgroundColor: Color(0xeef5f6f8),
        ),
      ),
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/background/n07_background_vertical.jpg',
            fit: BoxFit.cover,
            alignment: Alignment.center,
          ),
          const ColoredBox(color: Color(0x9effffff)),
          if (child != null) child,
        ],
      ),
      home: _loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : (_rememberedUser != null &&
                  _rememberedSessionToken.isNotEmpty &&
                  _sessionExpiresAtMs >
                      DateTime.now().millisecondsSinceEpoch)
              ? HomePage(
                  serverUrl: _serverUrl,
                  autoServerUrl: _autoServerUrl,
                  deviceId: _deviceId,
                  operatorId: _rememberedUser!.id,
                  isAdmin: _rememberedUser!.isAdmin,
                  sessionToken: _rememberedSessionToken,
                  sessionExpiresAtMs: _sessionExpiresAtMs,
                  initialPermissions: _rememberedUser!.permissions,
                  onSessionAuthenticated: _rememberSession,
                  onSessionCleared: _clearRememberedSession,
                )
              : LoginPage(
                  serverUrl: _serverUrl,
                  autoServerUrl: _autoServerUrl,
                  deviceId: _deviceId,
                  onSessionAuthenticated: _rememberSession,
                  onSessionCleared: _clearRememberedSession,
                ),
    );
  }
}

class ApiException implements Exception {
  const ApiException(this.message, {this.code, this.data});

  final String message;
  final String? code;
  final Map<String, dynamic>? data;

  @override
  String toString() => message;
}

class WarehouseApi {
  WarehouseApi(
    this.baseUrl,
    this.deviceId, {
    this.operatorId = kDefaultUser,
    this.sessionToken = '',
    this.warehouseId = kWarehouseVf,
    String? authBaseUrl,
  }) : authBaseUrl = authBaseUrl ?? baseUrl;

  final String baseUrl;
  final String authBaseUrl;
  final String deviceId;
  final String operatorId;
  final String sessionToken;
  final String warehouseId;

  static final LocalWarehouseStore _local = LocalWarehouseStore.instance;
  static bool _syncingNow = false;
  static final Map<String, DateTime> _lastPullAt = <String, DateTime>{};
  static final Map<String, DateTime> _lastSyncAttemptAt = <String, DateTime>{};
  static final Map<String, Map<String, String>> _remoteSlotByLegacy = <String, Map<String, String>>{};
  static final Map<String, Map<String, Map<String, dynamic>>> _legacyByRemoteSlot = <String, Map<String, Map<String, dynamic>>>{};

  bool get configured => baseUrl.trim().startsWith('http');
  bool get authConfigured => authBaseUrl.trim().startsWith('http');
  bool get _warehouseStillActive => _local.warehouseId == warehouseId;

  Future<Map<String, dynamic>> _edgePost(
    String url,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse(url),
            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json; charset=utf-8',
              'apikey': kSupabaseAnonKey,
              'Authorization': 'Bearer $kSupabaseAnonKey',
              'User-Agent': 'N07-HUBDNI-ANDROID/17.0-local-first',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
      dynamic decoded;
      try {
        decoded = jsonDecode(response.body.trim());
      } on FormatException {
        throw ApiException(
          'Supabase trả dữ liệu không phải JSON (HTTP ${response.statusCode}).',
          code: 'non_json',
        );
      }
      if (decoded is! Map) {
        throw const ApiException('Phản hồi Supabase không đúng định dạng.', code: 'bad_response');
      }
      final data = Map<String, dynamic>.from(decoded);
      data['_responseBytes'] = response.bodyBytes.length;
      if (response.statusCode >= 500) {
        throw ApiException(
          '${data['message'] ?? data['error'] ?? 'Supabase tạm bận.'}',
          code: 'temporary_server',
          data: data,
        );
      }
      return data;
    } on TimeoutException {
      throw const ApiException('Kết nối Supabase quá thời gian.', code: 'timeout');
    } on SocketException catch (e) {
      throw ApiException('Không kết nối được mạng: ${e.message}', code: 'network');
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('Lỗi kết nối Supabase: $e', code: 'network');
    }
  }

  int _remotePart(dynamic value) {
    final match = RegExp(r'(\d+)').firstMatch('${value ?? ''}');
    return match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
  }

  String _legacyKey(String location, int slot) => '${int.tryParse(location) ?? 0}|$slot';

  void _rememberRemoteSlots(List<dynamic> slots) {
    final byLegacy = <String, String>{};
    final byRemote = <String, Map<String, dynamic>>{};
    for (final raw in slots.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      final remoteId = '${row['id'] ?? row['slot_id'] ?? ''}'.trim();
      if (remoteId.isEmpty) continue;
      final location = _remotePart(row['aisleCode'] ?? row['aisle_code']).toString();
      final shelf = max(1, _remotePart(row['shelfCode'] ?? row['shelf_code']));
      final level = max(1, _remotePart(row['levelCode'] ?? row['level_code']));
      final pin = max(1, _remotePart(row['slotCode'] ?? row['slot_code']));
      final oldRow = ((level - 1) ~/ kCellsPerRow) + 1;
      final oldCell = ((level - 1) % kCellsPerRow) + 1;
      final oldSlot = _slotFromParts(shelf, oldRow, oldCell, pin);
      byLegacy[_legacyKey(location, oldSlot)] = remoteId;
      byRemote[remoteId] = {
        'location': location,
        'slot': oldSlot,
        'shelf': shelf,
        'level': level,
        'pin': pin,
      };
    }
    _remoteSlotByLegacy[warehouseId] = byLegacy;
    _legacyByRemoteSlot[warehouseId] = byRemote;
  }

  Map<String, dynamic>? _legacySlotForRemote(String remoteId) {
    final row = _legacyByRemoteSlot[warehouseId]?[remoteId];
    return row is Map<String, dynamic> ? row : null;
  }

  String _remoteSlotForLegacy(String location, int slot) =>
      _remoteSlotByLegacy[warehouseId]?[_legacyKey(location, slot)] ?? '';

  Map<String, dynamic> _publicUserFromSupabase(Map<String, dynamic> raw) {
    final role = '${raw['role'] ?? 'USER'}'.toUpperCase() == 'ADMIN' ? 'ADMIN' : 'USER';
    final wp = raw['warehousePermissions'];
    Iterable<dynamic> permissions = raw['permissions'] is List
        ? raw['permissions'] as List
        : const <dynamic>[];
    if (wp is Map && wp[warehouseId] is List) {
      permissions = wp[warehouseId] as List;
    }
    return {
      'id': '${raw['username'] ?? raw['id'] ?? ''}'.toUpperCase(),
      'role': role,
      'active': raw['active'] == true && '${raw['approvalStatus'] ?? ''}'.toUpperCase() == 'APPROVED',
      'permissions': {for (final p in permissions) '$p': true},
      'createdAt': '',
      'createdBy': 'SUPABASE',
      'updatedAt': '',
    };
  }

  String _normalizeSupabaseError(Map<String, dynamic> data) {
    final raw = '${data['code'] ?? data['error'] ?? 'server_error'}'.trim();
    switch (raw.toUpperCase()) {
      case 'PERMISSION_DENIED': return 'permission_denied';
      case 'PIN_ALREADY_IN_STOCK': return 'duplicate';
      case 'SLOT_OCCUPIED': return 'occupied';
      case 'PIN_NOT_IN_STOCK': return 'not_found';
      case 'SESSION_EXPIRED':
      case 'SESSION_INVALID':
      case 'DEVICE_MISMATCH': return 'session_expired';
      case 'MISSING_SESSION': return 'auth_required';
      case 'USER_DISABLED': return 'account_disabled';
      default: return raw.toLowerCase();
    }
  }

  Future<Map<String, dynamic>> _apiAction(
    String action, {
    Map<String, dynamic> extra = const {},
    String? token,
    String? device,
    String? wh,
  }) {
    return _edgePost(kSupabaseApiUrl, {
      'action': action,
      'warehouseId': wh ?? warehouseId,
      'deviceId': device ?? deviceId,
      'sessionToken': token ?? sessionToken,
      ...extra,
    }, timeout: action == 'SYNC_PULL' ? const Duration(seconds: 30) : const Duration(seconds: 15));
  }

  Future<Map<String, dynamic>> _historyAction(
    String action, {
    Map<String, dynamic> extra = const {},
  }) {
    return _edgePost(kSupabaseHistoryUrl, {
      'action': action,
      'warehouseId': warehouseId,
      'deviceId': deviceId,
      'sessionToken': sessionToken,
      ...extra,
    }, timeout: const Duration(seconds: 20));
  }

  Future<Map<String, dynamic>> _syncPullPage({
    required int sinceRevision,
    required String layoutVersion,
    required bool includeFullInventory,
  }) async {
    final other = warehouseId == kWarehouseVf ? kWarehouseAuto : kWarehouseVf;
    final data = await _edgePost(
      kSupabaseSyncUrl,
      {
        'action': 'SYNC_PULL_ALL',
        'deviceId': deviceId,
        'sessionToken': sessionToken,
        'revisions': <String, dynamic>{
          warehouseId: sinceRevision,
          other: 9007199254740991,
        },
        'layoutVersions': <String, dynamic>{
          warehouseId: layoutVersion,
          other: '',
        },
        // Additive protocol: client cũ không gửi inventoryMode vẫn nhận full
        // inventory theo includeInventory. Android mới dùng canonical delta.
        'includeInventory': includeFullInventory,
        'inventoryMode': includeFullInventory ? 'full' : 'delta',
        'activeWarehouseId': warehouseId,
      },
      timeout: const Duration(seconds: 30),
    );
    if (data['ok'] != true) {
      throw ApiException(
        '${data['message'] ?? data['error'] ?? 'Không đồng bộ được Supabase.'}',
        code: _normalizeSupabaseError(data),
        data: data,
      );
    }
    final responseBytes = _asInt(data['_responseBytes']);
    final snapshots = data['snapshots'] as List<dynamic>? ?? const [];
    for (final raw in snapshots.whereType<Map>()) {
      final snap = Map<String, dynamic>.from(raw);
      if ('${snap['warehouseId'] ?? ''}' == warehouseId) {
        snap['_responseBytes'] = responseBytes;
        return snap;
      }
    }
    throw const ApiException(
      'Server không trả snapshot cho kho đang mở.',
      code: 'sync_snapshot_missing',
    );
  }

  Future<void> _ensureRemoteSlotCache() async {
    if ((_remoteSlotByLegacy[warehouseId]?.isNotEmpty ?? false) &&
        (_legacyByRemoteSlot[warehouseId]?.isNotEmpty ?? false)) {
      return;
    }
    final rows = await _local.remoteSlotRows();
    if (rows.isNotEmpty) _rememberRemoteSlots(rows);
  }

  String _serverDateTime(dynamic value) {
    final raw = '${value ?? ''}'.trim();
    if (raw.isEmpty) return DateTime.now().toIso8601String();

    final direct = DateTime.tryParse(raw);
    if (direct != null) return direct.toIso8601String();

    final match = RegExp(
      r'^(\d{1,2})/(\d{1,2})/(\d{4})(?:\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$',
    ).firstMatch(raw);
    if (match != null) {
      final day = int.parse(match.group(1)!);
      final month = int.parse(match.group(2)!);
      final year = int.parse(match.group(3)!);
      final hour = int.tryParse(match.group(4) ?? '') ?? 0;
      final minute = int.tryParse(match.group(5) ?? '') ?? 0;
      final second = int.tryParse(match.group(6) ?? '') ?? 0;
      return DateTime(year, month, day, hour, minute, second)
          .toIso8601String();
    }

    // Không gửi chuỗi dd/MM/yyyy thô vào Supabase timestamptz.
    return DateTime.now().toIso8601String();
  }

  Future<Map<String, dynamic>> _directMutation(
    String action,
    Map<String, dynamic> extra,
  ) async {
    await _ensureRemoteSlotCache();

    String remoteSlot = '';
    String location = '${extra['location'] ?? extra['expectedLocation'] ?? ''}'.trim();
    int localSlot = _asInt(
      extra['slot'] ??
          extra['exactSlot'] ??
          extra['preferredSlot'] ??
          extra['expectedSlot'],
    );

    if (action != 'saveAudit') {
      if (location.isEmpty && action == 'exportPin') {
        location = '${extra['expectedLocation'] ?? ''}'.trim();
      }
      if (localSlot <= 0 && action == 'exportPin') {
        localSlot = _asInt(extra['expectedSlot']);
      }
      if (location.isNotEmpty && localSlot > 0) {
        remoteSlot = _remoteSlotForLegacy(location, localSlot);
        if (remoteSlot.isEmpty) {
          remoteSlot = await _local.remoteSlotForLegacy(location, localSlot);
        }
      }
    }

    if (action != 'saveAudit' && remoteSlot.isEmpty) {
      return {
        'ok': false,
        'code': 'layout_cache_missing',
        'message':
            'Không tìm thấy ánh xạ Slot local. Hãy Đồng bộ ngay một lần rồi thử lại.',
      };
    }

    final requestedOperationId = '${extra['_operationId'] ?? ''}'.trim();
    final operationId = requestedOperationId.isNotEmpty
        ? requestedOperationId
        : 'APK-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 31)}';

    Map<String, dynamic> response;
    if (action == 'importPin' || action == 'importPinToCell') {
      response = await _apiAction('APPLY_OPERATION', extra: {
        'operationId': operationId,
        'operation': 'IMPORT',
        'pinCode': '${extra['code'] ?? ''}',
        'slotId': remoteSlot,
        'pinType': '${extra['pinType'] ?? ''}',
        'scannedAt': _serverDateTime(extra['clientTime']),
      });
    } else if (action == 'exportPin') {
      response = await _apiAction('APPLY_OPERATION', extra: {
        'operationId': operationId,
        'operation': 'EXPORT',
        'pinCode': '${extra['code'] ?? ''}',
        'slotId': remoteSlot,
        'pinType': '${extra['pinType'] ?? ''}',
        'scannedAt': _serverDateTime(extra['clientTime']),
      });
    } else if (action == 'replacePin') {
      final oldCode = '${extra['expectedOldCode'] ?? ''}'.trim();
      if (oldCode.isEmpty) {
        return {
          'ok': false,
          'code': 'not_found',
          'message': 'Không xác định được PIN cũ để thay an toàn.',
        };
      }
      response = await _apiAction('REPLACE_PIN', extra: {
        'operationId': operationId,
        'oldPinCode': oldCode,
        'newPinCode': '${extra['newCode'] ?? ''}',
        'slotId': remoteSlot,
        'pinType': '${extra['pinType'] ?? ''}',
      });
    } else if (action == 'saveAudit') {
      response = await _apiAction('SAVE_AUDIT', extra: {
        'audit': {
          'sessionId': extra['sessionId'],
          'location': extra['location'],
          'scanned': extra['scanned'],
          'expected': extra['expected'],
          'matched': extra['matched'],
          'missing': extra['missing'],
          'wrongLocation': extra['wrongLocation'],
          'unknown': extra['unknown'],
          'duplicateScans': extra['duplicateScans'],
          'clientTime': _serverDateTime(extra['clientTime']),
        },
      });
    } else {
      return {
        'ok': false,
        'code': 'unsupported_sync_action',
        'message': 'Action không hỗ trợ.',
      };
    }

    if (response['ok'] != true) {
      return {
        'ok': false,
        'code': _normalizeSupabaseError(response),
        'message':
            '${response['message'] ?? response['error'] ?? 'Thao tác thất bại.'}',
      };
    }

    final legacy = remoteSlot.isEmpty
        ? null
        : (_legacySlotForRemote(remoteSlot) ??
            await _local.legacySlotForRemote(remoteSlot));
    return {
      'ok': true,
      'code': '${extra['code'] ?? extra['newCode'] ?? ''}',
      'location': '${legacy?['location'] ?? location}',
      'slot': legacy?['slot'] ?? localSlot,
      'pinType': '${extra['pinType'] ?? ''}',
      'revision': _asInt(response['revision'] ?? response['result']?['revision']),
      'operationId': operationId,
      'full': false,
      'cellFull': false,
    };
  }

  Future<Map<String, dynamic>> _call(
    String action,
    Map<String, dynamic> extra, {
    bool auth = false,
  }) async {
    final a = action.trim();
    if (a == 'ping') {
      final data = await _apiAction('PING', wh: auth ? kWarehouseVf : warehouseId);
      if (data['ok'] != true) throw ApiException('${data['message'] ?? data['error'] ?? 'Không kết nối được Supabase.'}', code: _normalizeSupabaseError(data), data: data);
      return {'ok': true, 'warehouseId': auth ? kWarehouseVf : warehouseId, 'apiVersion': kRequiredApiVersion, 'serverTime': data['serverTime'] ?? DateTime.now().toIso8601String()};
    }
    if (a == 'login') {
      final data = await _apiAction('LOGIN', wh: kWarehouseVf, extra: {'username': '${extra['id'] ?? ''}', 'password': '${extra['password'] ?? ''}', 'clientBuild': '3.3.3-reviewed'});
      if (data['ok'] != true) {
        return {'ok': true, 'valid': false, 'message': '${data['message'] ?? data['error'] ?? 'Sai ID hoặc mật khẩu.'}', 'warehouseId': kWarehouseVf, 'apiVersion': kRequiredApiVersion};
      }
      return {'ok': true, 'valid': true, 'sessionToken': '${data['token'] ?? ''}', 'user': _publicUserFromSupabase(Map<String, dynamic>.from(data['user'] as Map? ?? const {})), 'warehouseId': kWarehouseVf, 'apiVersion': kRequiredApiVersion};
    }
    if (a == 'logout') {
      final data = await _apiAction('LOGOUT', wh: kWarehouseVf);
      if (data['ok'] != true) throw ApiException('${data['message'] ?? data['error'] ?? 'Đăng xuất thất bại.'}', code: _normalizeSupabaseError(data), data: data);
      return {'ok': true, 'warehouseId': kWarehouseVf, 'apiVersion': kRequiredApiVersion};
    }
    if (a == 'changeOwnPassword') {
      final data = await _apiAction('CHANGE_PASSWORD', wh: kWarehouseVf, extra: {'currentPassword': extra['currentPassword'], 'newPassword': extra['newPassword']});
      if (data['ok'] != true) throw ApiException('${data['message'] ?? data['error'] ?? 'Đổi mật khẩu thất bại.'}', code: _normalizeSupabaseError(data), data: data);
      return {'ok': true, 'warehouseId': kWarehouseVf, 'apiVersion': kRequiredApiVersion};
    }
    if (a == 'revision') {
      final data = await _apiAction('SYNC_PULL', extra: const {'sinceRevision': 9007199254740991});
      if (data['ok'] != true) throw ApiException('${data['message'] ?? data['error']}', code: _normalizeSupabaseError(data), data: data);
      return {'ok': true, 'revision': '${data['revision'] ?? 0}', 'warehouseId': warehouseId, 'apiVersion': kRequiredApiVersion};
    }
    if (a == 'searchPin') {
      final code = '${extra['code'] ?? ''}'.trim();
      final results = await Future.wait([
        _apiAction('SEARCH_PIN', extra: {'query': code, 'exact': true}),
        _historyAction('SEARCH_PIN', extra: {'query': code, 'exact': true, 'limit': 100}),
      ]);
      final live = results[0];
      final hist = results[1];
      if (live['ok'] != true && hist['ok'] != true) throw ApiException('${live['message'] ?? hist['message'] ?? 'Tìm PIN thất bại.'}', code: _normalizeSupabaseError(live), data: live);
      final inv = live['inventory'] as List<dynamic>? ?? const [];
      if (inv.isNotEmpty) {
        final row = Map<String, dynamic>.from(inv.first as Map);
        final legacy = _legacySlotForRemote('${row['slotId'] ?? ''}');
        return {'ok': true, 'found': true, 'active': true, 'code': code, 'location': '${legacy?['location'] ?? ''}', 'slot': legacy?['slot'] ?? 0, 'storedAt': '${row['storedAt'] ?? ''}', 'exportedAt': '', 'pinType': '${row['pinType'] ?? ''}', 'warehouseId': warehouseId, 'apiVersion': kRequiredApiVersion};
      }
      final rows = hist['rows'] as List<dynamic>? ?? const [];
      if (rows.isEmpty) return {'ok': true, 'found': false, 'active': false, 'code': code, 'location': '', 'slot': 0, 'storedAt': '', 'exportedAt': '', 'pinType': '', 'warehouseId': warehouseId, 'apiVersion': kRequiredApiVersion};
      String storedAt = '', exportedAt = '';
      final latest = Map<String, dynamic>.from(rows.first as Map);
      for (final raw in rows.whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw);
        final act = '${row['action'] ?? ''}'.toUpperCase();
        if (storedAt.isEmpty && (act == 'IMPORT' || act == 'NHAP' || act == 'THAY_NHAP')) storedAt = '${row['occurredAt'] ?? ''}';
        if (exportedAt.isEmpty && (act == 'EXPORT' || act == 'XUAT' || act == 'THAY_XUAT')) exportedAt = '${row['occurredAt'] ?? ''}';
      }
      final legacy = _legacySlotForRemote('${latest['slotId'] ?? ''}');
      return {'ok': true, 'found': true, 'active': false, 'code': code, 'location': '${legacy?['location'] ?? ''}', 'slot': legacy?['slot'] ?? 0, 'storedAt': storedAt, 'exportedAt': exportedAt, 'pinType': '${latest['pinType'] ?? ''}', 'warehouseId': warehouseId, 'apiVersion': kRequiredApiVersion};
    }
    if (a == 'recentHistory') {
      final data = await _historyAction('GET_HISTORY_RANGE', extra: {'limit': min(500, _asInt(extra['limit']) == 0 ? 200 : _asInt(extra['limit'])), 'offset': 0});
      if (data['ok'] != true) throw ApiException('${data['message'] ?? data['error'] ?? 'Không tải được lịch sử.'}', code: _normalizeSupabaseError(data), data: data);
      final history = <Map<String, dynamic>>[];
      for (final raw in (data['rows'] as List<dynamic>? ?? const []).whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw);
        final legacy = _legacySlotForRemote('${row['slotId'] ?? ''}');
        var act = '${row['action'] ?? ''}'.toUpperCase();
        if (act == 'IMPORT') act = 'NHAP';
        if (act == 'EXPORT') act = 'XUAT';
        history.add({'timestamp': '${row['occurredAt'] ?? ''}', 'pinCode': '${row['pinCode'] ?? ''}', 'action': act, 'location': '${legacy?['location'] ?? ''}', 'slot': legacy?['slot'] ?? 0, 'note': '${row['reason'] ?? ''}', 'deviceId': '${row['deviceId'] ?? ''}', 'operatorId': '${row['userId'] ?? ''}', 'pinType': '${row['pinType'] ?? ''}'});
      }
      return {'ok': true, 'history': history, 'warehouseId': warehouseId, 'apiVersion': kRequiredApiVersion};
    }
    if (a == 'syncBatch') {
      List<dynamic> ops = const [];
      try { ops = extra['ops'] is List ? extra['ops'] as List : jsonDecode('${extra['ops'] ?? '[]'}') as List; } catch (_) {}
      final results = <Map<String, dynamic>>[];
      for (final raw in ops.whereType<Map>()) {
        final op = Map<String, dynamic>.from(raw);
        final payload = Map<String, dynamic>.from(op['payload'] as Map? ?? const {});
        // Hàng chờ cũ có thể còn clientTime dạng dd/MM/yyyy HH:mm:ss.
        // Chuẩn hóa ngay tại cửa syncBatch để tuyệt đối không gửi chuỗi locale
        // vào cột timestamptz của Supabase, kể cả thao tác được tạo bởi bản APK cũ.
        if (payload.containsKey('clientTime')) {
          payload['clientTime'] = _serverDateTime(payload['clientTime']);
        }
        if (payload.containsKey('scannedAt')) {
          payload['scannedAt'] = _serverDateTime(payload['scannedAt']);
        }
        final opAction = '${op['action'] ?? ''}' == 'importPinAtSlot' ? 'importPin' : '${op['action'] ?? ''}';
        // Giữ nguyên op_id local làm idempotency key trên Supabase. Nếu mạng
        // chập chờn/retry, cùng một outbox row không được tạo operation mới.
        payload['_operationId'] = '${op['opId'] ?? ''}';
        final result = await _directMutation(opAction, payload);
        results.add({...result, 'opId': '${op['opId'] ?? ''}', 'action': '${op['action'] ?? ''}'});
      }
      // Upload path is results-only by design. Never attach a full snapshot
      // after mutations; the following delta sync will reconcile local state.
      return {
        'ok': true,
        'results': results,
        'warehouseId': warehouseId,
        'apiVersion': kRequiredApiVersion,
      };
    }
    if (const {'importPin', 'importPinToCell', 'exportPin', 'replacePin', 'saveAudit'}.contains(a)) {
      final data = await _directMutation(a, Map<String, dynamic>.from(extra));
      if (data['ok'] != true) throw ApiException('${data['message'] ?? 'Thao tác thất bại.'}', code: '${data['code'] ?? 'server_error'}', data: data);
      return {...data, 'warehouseId': warehouseId, 'apiVersion': kRequiredApiVersion};
    }
    throw ApiException('Action không hỗ trợ trên APK: $a', code: 'unsupported_action');
  }

  Future<Map<String, dynamic>> pingInfo() async => _call('ping', const {});

  Future<void> ping() async {
    final data = await pingInfo();
    final apiVersion = _asInt(data['apiVersion']);
    if (apiVersion < kRequiredApiVersion) {
      throw const ApiException(
        'Backend đang là bản cũ. Cần V25 để đồng bộ đúng với N07 HUBDNI PC.',
        code: 'backend_outdated',
      );
    }
  }

  Future<String> revision() async {
    final data = await _call('revision', const {});
    return '${data['revision'] ?? ''}';
  }

  Future<LoginResult> login(String id, String password) async {
    final pingData = await _call('ping', const {}, auth: true);
    if (_asInt(pingData['apiVersion']) < kRequiredApiVersion) {
      throw const ApiException('Backend chưa tương thích.', code: 'backend_outdated');
    }
    final data = await _call('login', {'id': id, 'password': password}, auth: true);
    final result = LoginResult.fromJson(data);
    if (!result.valid || result.user == null || result.sessionToken.isEmpty) {
      return result;
    }
    await _local.cacheLogin(
      id: result.user!.id,
      password: password,
      sessionToken: result.sessionToken,
      user: Map<String, dynamic>.from(data['user'] as Map? ?? const {}),
    );
    await _local.refreshSyncState(
      online: true,
      syncing: false,
      message: 'ONLINE • Supabase',
      authError: '',
    );
    final onlineApi = WarehouseApi(
      authBaseUrl,
      deviceId,
      operatorId: result.user!.id,
      sessionToken: result.sessionToken,
      warehouseId: kWarehouseVf,
      authBaseUrl: authBaseUrl,
    );
    await onlineApi.syncNow(bypassThrottle: true, reason: 'login_bootstrap');
    if (_lastPullAt[kWarehouseVf] == null) {
      throw const ApiException('Đăng nhập thành công nhưng chưa đồng bộ được dữ liệu từ Supabase. Hãy kiểm tra mạng và thử lại.', code: 'first_sync_required');
    }
    return result;
  }

  Future<void> logout() async {
    if (sessionToken.isEmpty) return;
    await _call('logout', const {}, auth: true);
  }


  Future<void> syncNow({
    bool bypassThrottle = false,
    bool recoverLayout = false,
    String reason = 'normal',
    int uploadedRows = 0,
  }) async {
    if (_syncingNow || sessionToken.isEmpty || !_warehouseStillActive) return;
    final now = DateTime.now();
    final lastPull = _lastPullAt[warehouseId];
    if (!bypassThrottle &&
        lastPull != null &&
        now.difference(lastPull) < kNormalSyncThrottle) {
      return;
    }

    _syncingNow = true;
    final startedMs = DateTime.now().millisecondsSinceEpoch;
    var revisionBefore = 0;
    var revisionAfter = 0;
    var rowsDownloaded = 0;
    var layoutReloaded = false;
    var fullBootstrap = false;
    var historyRowsDownloaded = 0;
    var inventoryDeltaRows = 0;
    var removedPinRows = 0;
    var slotsRows = 0;
    var pageCount = 0;
    var responseBytes = 0;
    var syncMode = 'unchanged';
    String syncError = '';

    await _local.refreshSyncState(
      online: true,
      syncing: true,
      authError: '',
      message: 'Đang đồng bộ delta Supabase...',
    );

    try {
      await _ensureRemoteSlotCache();
      revisionBefore = await _local.serverRevision();
      revisionAfter = revisionBefore;
      var layoutVersion = await _local.layoutVersion();
      final remoteSlotCount = await _local.remoteSlotCount();
      final historyReady = await _local.historyBootstrapComplete();

      // Chỉ bootstrap full khi local thiếu baseline bắt buộc sau upgrade/fresh install.
      // Offline lâu KHÔNG phải lý do full bootstrap.
      fullBootstrap = remoteSlotCount == 0 || !historyReady || revisionBefore < 0;
      syncMode = fullBootstrap ? 'bootstrap' : 'delta';

      // Missing-layout recovery vẫn đi qua sync-v2. Rewind đúng 1 revision để
      // server có thể trả layout nếu version local bị mất, không dùng legacy
      // SYNC_PULL -1 trong normal runtime.
      var cursor = fullBootstrap
          ? -1
          : recoverLayout
              ? max(-1, revisionBefore - 1)
              : revisionBefore;
      var includeFullInventory = fullBootstrap;
      if (recoverLayout && !fullBootstrap) layoutVersion = '';

      final bufferedSlots = <Map<String, dynamic>>[];
      final bufferedFullInventory = <Map<String, dynamic>>[];
      final canonicalByPin = <String, Map<String, dynamic>>{};
      final removedPins = <String>{};
      final historyByServerId = <String, Map<String, dynamic>>{};
      final historyNoId = <Map<String, dynamic>>[];
      var finished = false;

      while (!finished && pageCount < kMaxDeltaPagesPerSync) {
        if (!_warehouseStillActive) return;
        final snapshot = await _syncPullPage(
          sinceRevision: cursor,
          layoutVersion: layoutVersion,
          includeFullInventory: includeFullInventory,
        );
        if (!_warehouseStillActive) return;
        pageCount++;
        responseBytes += _asInt(snapshot['_responseBytes']);

        final slots = (snapshot['slots'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        final fullInventoryRows =
            (snapshot['inventory'] as List<dynamic>? ?? const [])
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
        final inventoryDelta =
            (snapshot['inventoryDelta'] as List<dynamic>? ?? const [])
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
        final removed = (snapshot['removedPinCodes'] as List<dynamic>? ?? const [])
            .map((e) => '$e'.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        final history = (snapshot['history'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        final nextRevision = _asInt(snapshot['revision']);
        final nextLayoutVersion = '${snapshot['layoutVersion'] ?? ''}'.trim();
        final unchanged = snapshot['unchanged'] == true;
        final hasMore = snapshot['hasMore'] == true;

        if (slots.isNotEmpty) {
          bufferedSlots
            ..clear()
            ..addAll(slots);
          slotsRows = slots.length;
          layoutReloaded = true;
        }
        if (includeFullInventory && fullInventoryRows.isNotEmpty) {
          bufferedFullInventory
            ..clear()
            ..addAll(fullInventoryRows);
        }
        for (final row in inventoryDelta) {
          final code = '${row['code'] ?? row['pin_code'] ?? ''}'.trim();
          if (code.isEmpty) continue;
          canonicalByPin[code] = row;
          removedPins.remove(code);
        }
        for (final code in removed) {
          canonicalByPin.remove(code);
          removedPins.add(code);
        }
        for (final row in history) {
          final id = '${row['id'] ?? ''}'.trim();
          if (id.isEmpty) {
            historyNoId.add(row);
          } else {
            historyByServerId[id] = row;
          }
        }

        revisionAfter = nextRevision;
        if (nextLayoutVersion.isNotEmpty) layoutVersion = nextLayoutVersion;

        if (unchanged || !hasMore) {
          finished = true;
          break;
        }

        // Backend mới đảm bảo không cắt đôi cùng một revision ở biên page,
        // nên page tiếp theo bắt đầu strict > nextRevision, không rewind/loop.
        if (nextRevision <= cursor) {
          throw const ApiException(
            'Server delta cursor không tiến. Đã dừng để tránh request loop.',
            code: 'delta_cursor_stalled',
          );
        }
        cursor = nextRevision;
        includeFullInventory = false;
      }

      if (!finished) {
        throw const ApiException(
          'Delta history vượt giới hạn an toàn trong một lần sync. Đã dừng để tránh loop/egress bất thường.',
          code: 'delta_page_guard',
        );
      }

      final allHistory = <Map<String, dynamic>>[
        ...historyByServerId.values,
        ...historyNoId,
      ]
        ..sort((a, b) {
          final ar = _asInt(a['serverRevision'] ?? a['revision']);
          final br = _asInt(b['serverRevision'] ?? b['revision']);
          if (ar != br) return ar.compareTo(br);
          return _asInt(a['id']).compareTo(_asInt(b['id']));
        });
      final allInventoryDelta = canonicalByPin.values.toList();
      final allRemovedPins = removedPins.toList()..sort();

      // Apply toàn bộ pages đúng một SQLite transaction. UI chỉ nhìn thấy state
      // trước hoặc sau sync, không có trạng thái trung gian giữa page 1/page 2.
      if (fullBootstrap ||
          bufferedSlots.isNotEmpty ||
          bufferedFullInventory.isNotEmpty ||
          allInventoryDelta.isNotEmpty ||
          allRemovedPins.isNotEmpty ||
          allHistory.isNotEmpty ||
          revisionAfter != revisionBefore) {
        final applied = await _local.applyServerSyncBundle(
          slots: bufferedSlots,
          fullInventoryRows: bufferedFullInventory,
          inventoryDelta: allInventoryDelta,
          removedPinCodes: allRemovedPins,
          history: allHistory,
          revision: revisionAfter,
          layoutVersion: layoutVersion,
          fullInventory: fullBootstrap,
        );
        historyRowsDownloaded = applied['history'] ?? 0;
        inventoryDeltaRows = applied['inventory'] ?? 0;
        removedPinRows = applied['removed'] ?? 0;
        slotsRows = applied['slots'] ?? slotsRows;
        rowsDownloaded = historyRowsDownloaded +
            inventoryDeltaRows +
            removedPinRows +
            slotsRows;
        if (bufferedSlots.isNotEmpty) {
          _rememberRemoteSlots(bufferedSlots);
        } else {
          await _ensureRemoteSlotCache();
        }
      } else {
        syncMode = 'unchanged';
      }

      if (fullBootstrap) {
        await _local.markHistoryBootstrapComplete();
        await _local.markFullBootstrapNow();
      }

      // Pin type catalog nhỏ, không tải ở mỗi revision. Manual sync cũng không
      // ép catalog nếu cache còn mới để tránh request không cần thiết.
      final pinTypeLastMs =
          int.tryParse(await _local.getMeta('pin_types_last_sync_ms')) ?? 0;
      final pinTypeStale = DateTime.now().millisecondsSinceEpoch - pinTypeLastMs >
          const Duration(hours: 6).inMilliseconds;
      if (fullBootstrap || pinTypeStale) {
        try {
          final typeData = await _apiAction('LIST_PIN_TYPES');
          responseBytes += _asInt(typeData['_responseBytes']);
          if (typeData['ok'] == true) {
            final pinTypes = <String>[];
            for (final raw in
                (typeData['pinTypes'] as List<dynamic>? ?? const [])
                    .whereType<Map>()) {
              if (raw['active'] == false) continue;
              final code = '${raw['code'] ?? raw['name'] ?? ''}'.trim();
              if (code.isNotEmpty) pinTypes.add(code);
            }
            await _local.setMeta('pin_types_json', jsonEncode(pinTypes));
            await _local.setMeta(
              'pin_types_last_sync_ms',
              '${DateTime.now().millisecondsSinceEpoch}',
            );
            rowsDownloaded += pinTypes.length;
          }
        } catch (_) {
          // Catalog type không được phép làm hỏng inventory/history sync.
        }
      }

      _lastPullAt[warehouseId] = DateTime.now();
      await _local.refreshSyncState(
        online: true,
        syncing: false,
        lastSync: _lastPullAt[warehouseId],
        message: fullBootstrap
            ? 'Đã bootstrap local • Supabase'
            : revisionAfter == revisionBefore
                ? 'Đồng bộ xong • Không có thay đổi mới'
                : 'Đã nhận delta r$revisionBefore → r$revisionAfter',
        authError: '',
      );
    } on ApiException catch (e) {
      syncError = '${e.code ?? 'server'} • ${e.message}';
      final authError = const {
        'session_expired',
        'auth_required',
        'account_disabled',
      }.contains(e.code)
          ? e.message
          : '';
      await _local.refreshSyncState(
        online: false,
        syncing: false,
        message: 'MẤT KẾT NỐI • ${e.message}',
        authError: authError,
      );
    } catch (e) {
      syncError = '$e';
      await _local.refreshSyncState(
        online: false,
        syncing: false,
        message: 'MẤT KẾT NỐI • $e',
        authError: '',
      );
    } finally {
      final durationMs = DateTime.now().millisecondsSinceEpoch - startedMs;
      try {
        await _local.recordSyncLog(
          startedMs: startedMs,
          durationMs: durationMs,
          reason: reason,
          syncMode: syncMode,
          rowsDownloaded: rowsDownloaded,
          rowsUploaded: uploadedRows,
          revisionBefore: revisionBefore,
          revisionAfter: revisionAfter,
          fullBootstrap: fullBootstrap,
          layoutReloaded: layoutReloaded,
          historyRows: historyRowsDownloaded,
          inventoryDeltaRows: inventoryDeltaRows,
          removedPinRows: removedPinRows,
          slotsRows: slotsRows,
          pageCount: pageCount,
          responseBytes: responseBytes,
          error: syncError,
        );
      } catch (_) {}
      _syncingNow = false;
      await _local.refreshSyncState(syncing: false);
    }
  }

  Future<Map<String, dynamic>> uploadPendingTransfers(
    List<String> opIds, {
    void Function(int processed, int total)? onProgress,
  }) async {
    if (!_warehouseStillActive) {
      return {
        'ok': false,
        'uploaded': 0,
        'failed': 0,
        'blocked': <String>[],
        'errors': <String>['Đã chuyển ngăn quản lý. Thao tác được giữ nguyên ở kho cũ.'],
        'fatalCode': 'warehouse_changed',
        'fatalMessage': 'Đã chuyển ngăn quản lý. Thao tác được giữ nguyên ở kho cũ.',
      };
    }
    if (sessionToken.isEmpty) {
      return {
        'ok': false,
        'uploaded': 0,
        'failed': 0,
        'blocked': <String>[],
        'errors': <String>['Phiên đăng nhập không hợp lệ.'],
        'fatalCode': 'auth_required',
        'fatalMessage': 'Phiên đăng nhập không hợp lệ.',
      };
    }

    if (_syncingNow) {
      return {
        'ok': false,
        'uploaded': 0,
        'failed': 0,
        'blocked': <String>[],
        'errors': <String>[
          'Đang có tiến trình đồng bộ khác. Hãy bấm lại sau vài giây.',
        ],
        'fatalCode': 'sync_busy',
        'fatalMessage':
            'Đang có tiến trình đồng bộ khác. Hãy bấm lại sau vài giây.',
      };
    }

    await _local.refreshQueuedActorToken(
      operatorId: operatorId,
      sessionToken: sessionToken,
    );

    final prepared = await _local.pendingTransferOpsForUpload(opIds);
    final blocked =
        (prepared['blocked'] as List<dynamic>? ?? const [])
            .map((e) => '$e')
            .toList();
    final ops = (prepared['ops'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    if (ops.isEmpty) {
      return {
        'ok': blocked.isEmpty,
        'uploaded': 0,
        'failed': 0,
        'blocked': blocked,
        'errors': <String>[],
        'fatalCode': '',
        'fatalMessage': '',
      };
    }

    _syncingNow = true;

    // Manual upload intentionally does not use authError.
    // Home must not navigate away from the queue while upload is running.
    await _local.refreshSyncState(
      syncing: true,
      authError: '',
      message: 'Đang gửi 0/${ops.length} thao tác NHẬP/XUẤT...',
    );

    var uploaded = 0;
    var failed = 0;
    var processed = 0;
    final errors = <String>[];
    String fatalCode = '';
    String fatalMessage = '';

    try {
      for (var start = 0; start < ops.length; start += 10) {
        final end = min(start + 10, ops.length);
        final batch = ops.sublist(start, end).map((op) {
          final safe = Map<String, dynamic>.from(op);
          final payload = Map<String, dynamic>.from(
            safe['payload'] as Map? ?? const {},
          );
          if (payload.containsKey('clientTime')) {
            payload['clientTime'] = _serverDateTime(payload['clientTime']);
          }
          if (payload.containsKey('scannedAt')) {
            payload['scannedAt'] = _serverDateTime(payload['scannedAt']);
          }
          safe['payload'] = payload;
          return safe;
        }).toList();

        Map<String, dynamic> data;
        try {
          data = await _call(
            'syncBatch',
            {
              'ops': jsonEncode(batch),
              // V25: only return per-operation results after confirmation.
              'resultsOnly': '1',
            },
          );
          if (!_warehouseStillActive) {
            fatalCode = 'warehouse_changed';
            fatalMessage = 'Đã chuyển ngăn quản lý. Kết quả cũ bị bỏ qua để tránh ghi chéo dữ liệu.';
            errors.add('[$fatalCode] $fatalMessage');
            break;
          }
        } on ApiException catch (e) {
          fatalCode = e.code ?? 'server';
          fatalMessage = e.message;
          errors.add(
            '[$fatalCode] $fatalMessage',
          );
          await _local.markTransferAttemptsFailed(
            batch.map((op) => '${op['opId']}'),
            '[$fatalCode] $fatalMessage',
          );
          break;
        } catch (e) {
          fatalCode = 'unknown';
          fatalMessage = '$e';
          errors.add('[$fatalCode] $fatalMessage');
          await _local.markTransferAttemptsFailed(
            batch.map((op) => '${op['opId']}'),
            '[$fatalCode] $fatalMessage',
          );
          break;
        }

        final rawResults = data['results'];
        final results = rawResults is List
            ? rawResults.whereType<Map>().toList()
            : const <Map>[];

        final byId = {
          for (final op in batch) '${op['opId']}': op,
        };

        final returnedIds = <String>{};

        for (final raw in results) {
          final result = Map<String, dynamic>.from(raw);
          final opId = '${result['opId'] ?? ''}';
          if (!byId.containsKey(opId) || opId.isEmpty) continue;

          returnedIds.add(opId);

          await _local.markManualTransferUploadResult(
            opId: opId,
            result: result,
          );

          if (result['ok'] == true) {
            uploaded++;
          } else {
            failed++;
            final code = '${result['code'] ?? 'upload_failed'}';
            final message = '${result['message'] ?? code}';
            errors.add('$code • $message');
          }
        }

        // Missing server result is treated as failed, but the outbox row
        // stays untouched so the user can retry safely.
        final missingResultIds = <String>[];
        for (final op in batch) {
          final opId = '${op['opId']}';
          if (!returnedIds.contains(opId)) {
            failed++;
            missingResultIds.add(opId);
            errors.add(
              '$opId • Server không trả kết quả, thao tác vẫn được giữ để thử lại.',
            );
          }
        }
        if (missingResultIds.isNotEmpty) {
          await _local.markTransferAttemptsFailed(
            missingResultIds,
            'Server không trả kết quả; giữ thao tác để manual retry.',
          );
        }

        processed = end;
        onProgress?.call(processed, ops.length);

        await _local.refreshSyncState(
          online: true,
          syncing: true,
          authError: '',
          message:
              'Đang gửi $processed/${ops.length} thao tác NHẬP/XUẤT...',
        );

        // Yield one frame between batches on small rugged devices.
        await Future<void>.delayed(
          const Duration(milliseconds: 80),
        );
      }

      final manualRemaining = await _local.pendingTransferCount();

      await _local.refreshSyncState(
        online: fatalCode.isEmpty,
        syncing: false,
        authError: '',
        message: fatalCode.isNotEmpty
            ? 'GỬI SERVER DỪNG [$fatalCode] • $fatalMessage'
            : manualRemaining > 0
                ? 'CHỜ XÁC NHẬN • $manualRemaining thao tác NHẬP/XUẤT'
                : 'Đã xác nhận hết NHẬP/XUẤT • Server đã nhận',
      );

      return {
        'ok': fatalCode.isEmpty &&
            failed == 0 &&
            blocked.isEmpty,
        'uploaded': uploaded,
        'failed': failed,
        'processed': processed,
        'total': ops.length,
        'blocked': blocked,
        'errors': errors,
        'fatalCode': fatalCode,
        'fatalMessage': fatalMessage,
      };
    } catch (e) {
      // Last-resort containment. Manual upload must never escape to the route.
      fatalCode = 'client_upload_error';
      fatalMessage = '$e';
      errors.add('[$fatalCode] $fatalMessage');
      await _local.markTransferAttemptsFailed(
        ops.skip(processed).map((op) => '${op['opId']}'),
        '[$fatalCode] $fatalMessage',
      );

      await _local.refreshSyncState(
        syncing: false,
        authError: '',
        message: 'LỖI GỬI SERVER • $fatalMessage',
      );

      return {
        'ok': false,
        'uploaded': uploaded,
        'failed': failed,
        'processed': processed,
        'total': ops.length,
        'blocked': blocked,
        'errors': errors,
        'fatalCode': fatalCode,
        'fatalMessage': fatalMessage,
      };
    } finally {
      _syncingNow = false;
      await _local.refreshSyncState(
        syncing: false,
        authError: '',
      );
      if (uploaded > 0 && _warehouseStillActive) {
        await syncNow(
          bypassThrottle: true,
          reason: 'post_upload',
          uploadedRows: uploaded,
        );
      }
    }
  }


  Future<void> changeOwnPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _call(
      'changeOwnPassword',
      {
        'currentPassword': currentPassword,
        'newPassword': newPassword,
      },
      auth: true,
    );
    await _local.updateCachedPassword(operatorId, newPassword);
  }

  Future<HomeData> homeData() async {
    final summaryData = await _local.localSummary();
    final cached = await _local.cachedUser(operatorId) ?? {
      'id': operatorId,
      'role': operatorId == kAdminUser ? 'ADMIN' : 'USER',
      'active': true,
      'permissions': const <String, bool>{},
    };
    final user = UserAccount.fromJson(cached);
    final canSeeWarehouse = user.isAdmin || user.permissions.isNotEmpty;
    return HomeData(
      summary: WarehouseSummary.fromJson(
        canSeeWarehouse
            ? summaryData
            : const {
                'totalPins': 0,
                'totalLocations': 0,
                'fullLocations': 0,
                'emptySlots': 0,
              },
      ),
      user: user,
    );
  }

  Future<List<LocationSummary>> listLocations({bool force = false}) async {
    if (force) unawaited(syncNow(bypassThrottle: true, reason: 'locations_refresh'));
    final rows = await _local.listLocations();
    return rows
        .map(
          (row) => LocationSummary.fromJson(
            row,
            fallbackCapacity: warehouseDefaultCapacity(warehouseId),
          ),
        )
        .toList();
  }

  Future<void> _recoverMissingLocation(String location) async {
    // First try an ordinary revision delta. If the row is still absent, do a
    // controlled layout-only recovery. This may reload slots, but never forces
    // full inventory/history in normal runtime.
    await syncNow(
      bypassThrottle: true,
      reason: 'location_missing_delta',
    );
    if (await _local.getLocation(location) != null) return;
    await syncNow(
      bypassThrottle: true,
      recoverLayout: true,
      reason: 'location_missing_layout_recovery',
    );
  }

  Future<LocationDetail> getLocation(String location) async {
    final data = await _local.getLocation(location);
    if (data == null) {
      unawaited(_recoverMissingLocation(location));
      throw ApiException(
        'Không tìm thấy Dãy số $location trong bộ nhớ máy.',
        code: 'not_found',
      );
    }
    return LocationDetail.fromJson(data, warehouseId: warehouseId);
  }

  bool get _fastMutationOnline =>
      configured &&
      sessionToken.isNotEmpty &&
      _warehouseStillActive &&
      _local.syncState.value.online;

  ScanOutcome _localMutationOutcome(
    Map<String, dynamic> data, {
    required String successPrefix,
    required bool cellMode,
  }) {
    final ok = data['ok'] == true;
    final location = '${data['location'] ?? ''}';
    final slot = _asInt(data['slot']);
    final message = '${data['message'] ?? ''}'.trim();
    if (ok) {
      final position = location.isNotEmpty && slot > 0
          ? _rackPositionLabel(location, slot, warehouseId: warehouseId)
          : '';
      return ScanOutcome.success(
        position.isEmpty
            ? '$successPrefix • CHỜ XÁC NHẬN'
            : '$successPrefix • $position • CHỜ XÁC NHẬN',
        location: location,
        slot: slot,
        full: cellMode ? data['cellFull'] == true : data['full'] == true,
      );
    }

    final code = '${data['code'] ?? ''}'.toLowerCase();
    final text = message.isEmpty ? 'Thao tác không thực hiện được.' : message;
    if (code == 'duplicate') {
      return ScanOutcome.duplicate(text, location: location, slot: slot);
    }
    if (code == 'full' || code == 'cell_full') {
      return ScanOutcome.full(text);
    }
    return ScanOutcome.error(text);
  }

  Future<ScanOutcome> importPin(
    String location,
    String code, {
    int? exactSlot,
    String pinType = '',
  }) async {
    if (!_fastMutationOnline) {
      return ScanOutcome.error(
        'MẤT KẾT NỐI • Không nhận mã mới khi chưa online.',
      );
    }

    final data = await _local.importPin(
      location: location,
      code: code.trim(),
      deviceId: deviceId,
      operatorId: operatorId,
      sessionToken: sessionToken,
      pinType: pinType,
      exactSlot: exactSlot,
    );
    return _localMutationOutcome(
      data,
      successPrefix: 'ĐÃ NHẬN TRÊN MÁY',
      cellMode: false,
    );
  }

  Future<ScanOutcome> importPinToCell(
    String location,
    int aisle,
    int row,
    int cell,
    String code, {
    String pinType = '',
  }) async {
    if (!_fastMutationOnline) {
      return ScanOutcome.error(
        'MẤT KẾT NỐI • Không nhận mã mới khi chưa online.',
      );
    }

    final data = await _local.importPinToCell(
      location: location,
      aisle: aisle,
      row: row,
      cell: cell,
      code: code.trim(),
      deviceId: deviceId,
      operatorId: operatorId,
      sessionToken: sessionToken,
      pinType: pinType,
    );
    return _localMutationOutcome(
      data,
      successPrefix: 'ĐÃ NHẬN TRÊN MÁY',
      cellMode: true,
    );
  }

  Future<ScanOutcome> replacePin(
    String location,
    int slot,
    String newCode,
  ) async {
    final local = await _local.getLocation(location);
    String oldCode = '';
    if (local != null) {
      for (final raw in (local['slots'] as List<dynamic>? ?? const []).whereType<Map>()) {
        if (_asInt(raw['slot']) == slot) { oldCode = '${raw['pinCode'] ?? ''}'; break; }
      }
    }
    final data = await _call('replacePin', {
      'location': location, 'slot': slot, 'newCode': newCode.trim(), 'expectedOldCode': oldCode,
      'clientTime': DateTime.now().toIso8601String(),
    });
    await _local.applyConfirmedReplace(
      oldCode: oldCode, newCode: newCode.trim(), location: location, slot: slot,
      deviceId: deviceId, operatorId: operatorId,
    );
    return ScanOutcome.success(
      'Đã thay pin • ${_rackPositionLabel(location, slot, warehouseId: warehouseId)}',
      location: location, slot: slot,
    );
  }

  Future<PinSearchResult> searchPin(String code) async {
    final clean = code.trim();
    final localData = await _local.searchPin(clean);
    final localResult = PinSearchResult.fromJson(
      localData,
      warehouseId: warehouseId,
    );
    if (localResult.found) return localResult;

    // Sau bootstrap history, tra PIN tuyệt đối local-first và không query cloud.
    // Fallback cloud chỉ tồn tại cho đúng giai đoạn upgrade chưa bootstrap xong.
    if (await _local.historyBootstrapComplete()) return localResult;
    try {
      final data = await _call('searchPin', {'code': clean});
      return PinSearchResult.fromJson(data, warehouseId: warehouseId);
    } catch (_) {
      return localResult;
    }
  }

  Future<List<String>> listPinTypes() => _local.listPinTypes();

  Future<ScanOutcome> exportPin(String code) async {
    if (!_fastMutationOnline) {
      return ScanOutcome.error(
        'MẤT KẾT NỐI • Không xuất PIN khi chưa online.',
      );
    }

    final data = await _local.exportPin(
      code: code.trim(),
      deviceId: deviceId,
      operatorId: operatorId,
      sessionToken: sessionToken,
    );
    return _localMutationOutcome(
      data,
      successPrefix: 'ĐÃ XUẤT TRÊN MÁY',
      cellMode: false,
    );
  }

  Future<ScanOutcome> exportSlot(String location, int slot) async {
    final detail = await _local.getLocation(location);
    if (detail == null) return ScanOutcome.error('Không tìm thấy Dãy số $location.');
    final slots = detail['slots'] as List<dynamic>? ?? const [];
    final match = slots.whereType<Map>().cast<Map>().where(
      (e) => _asInt(e['slot']) == slot && '${e['pinCode'] ?? ''}'.isNotEmpty,
    );
    if (match.isEmpty) return ScanOutcome.error('Ô đang trống.');
    return exportPin('${match.first['pinCode']}');
  }

  Future<List<HistoryEntry>> recentHistory({int limit = 200}) async {
    final safeLimit = limit.clamp(1, 3000).toInt();
    final localRows = await _local.historyPage(limit: min(safeLimit, 500), offset: 0);
    return localRows.map(HistoryEntry.fromJson).toList();
  }

  Future<Map<String, dynamic>> historyPage({
    int limit = 200,
    int offset = 0,
    String query = '',
  }) async {
    final rows = await _local.historyPage(
      limit: limit.clamp(1, 500).toInt(),
      offset: max(0, offset),
      query: query,
    );
    final total = await _local.historyCount(query: query);
    return {
      'rows': rows.map(HistoryEntry.fromJson).toList(),
      'total': total,
      'offset': max(0, offset),
      'limit': limit.clamp(1, 500).toInt(),
    };
  }

  Future<void> saveAudit({
    required String sessionId,
    required String location,
    required List<String> scanned,
    required int expected,
    required int matched,
    required List<String> missing,
    required List<String> wrongLocation,
    required List<String> unknown,
    required int duplicateScans,
  }) async {
    await _call('saveAudit', {
      'sessionId': sessionId, 'location': location, 'scanned': scanned,
      'expected': expected, 'matched': matched, 'missing': missing,
      'wrongLocation': wrongLocation, 'unknown': unknown,
      'duplicateScans': duplicateScans, 'clientTime': DateTime.now().toIso8601String(),
    });
    await _local.applyConfirmedAudit(
      sessionId: sessionId, location: location, scannedCodes: scanned,
      expected: expected, matched: matched, missing: missing,
      wrongLocation: wrongLocation, unknown: unknown, duplicateScans: duplicateScans,
      operatorId: operatorId,
    );
  }

  Future<Map<String, dynamic>> inventoryData() async {
    return _local.inventoryData();
  }
}

int _asInt(dynamic value) => int.tryParse('$value') ?? 0;

String _displayShelf(String value) {
  final n = int.tryParse(value.trim());
  return n == null ? value.trim() : '$n';
}

int _baseAisleFromPosition(int position) {
  if (position < 1) return 0;

  if (position <= kLegacySlotsPerLocation) {
    return ((position - 1) ~/ kLegacyPinsPerAisle) + 1;
  }

  final extendedRowsEnd =
      kLegacySlotsPerLocation + kExtendedRowsSlots;
  if (position <= extendedRowsEnd) {
    final offset = position - kLegacySlotsPerLocation - 1;
    final pinsPerExtendedAisle =
        (kRowsPerAisle - kLegacyRowsPerAisle) *
        kCellsPerRow *
        kBasePinsPerCell;
    return (offset ~/ pinsPerExtendedAisle) + 1;
  }

  final offset = position - extendedRowsEnd - 1;
  final pinsPerFullAisle =
      kRowsPerAisle * kCellsPerRow * kBasePinsPerCell;
  return kLegacyAislesPerShelf + (offset ~/ pinsPerFullAisle) + 1;
}

int _baseRowFromPosition(int position) {
  if (position < 1) return 0;

  if (position <= kLegacySlotsPerLocation) {
    final withinAisle = (position - 1) % kLegacyPinsPerAisle;
    return (withinAisle ~/ (kCellsPerRow * kBasePinsPerCell)) + 1;
  }

  final extendedRowsEnd =
      kLegacySlotsPerLocation + kExtendedRowsSlots;
  if (position <= extendedRowsEnd) {
    final offset = position - kLegacySlotsPerLocation - 1;
    final pinsPerExtendedAisle =
        (kRowsPerAisle - kLegacyRowsPerAisle) *
        kCellsPerRow *
        kBasePinsPerCell;
    final withinAisle = offset % pinsPerExtendedAisle;
    return kLegacyRowsPerAisle +
        (withinAisle ~/ (kCellsPerRow * kBasePinsPerCell)) +
        1;
  }

  final offset = position - extendedRowsEnd - 1;
  final pinsPerFullAisle =
      kRowsPerAisle * kCellsPerRow * kBasePinsPerCell;
  final withinAisle = offset % pinsPerFullAisle;
  return (withinAisle ~/ (kCellsPerRow * kBasePinsPerCell)) + 1;
}

int _baseCellFromPosition(int position) {
  if (position < 1) return 0;
  return ((position - 1) %
              (kCellsPerRow * kBasePinsPerCell) ~/
          kBasePinsPerCell) +
      1;
}

int _basePinInCell(int position) {
  if (position < 1) return 0;
  return ((position - 1) % kBasePinsPerCell) + 1;
}

int _baseSlotFromParts(int aisle, int row, int cell, int pinNo) {
  if (aisle <= kLegacyAislesPerShelf && row <= kLegacyRowsPerAisle) {
    return (((aisle - 1) * kLegacyRowsPerAisle + (row - 1)) *
                kCellsPerRow +
            (cell - 1)) *
        kBasePinsPerCell +
        pinNo;
  }

  if (aisle <= kLegacyAislesPerShelf) {
    final rowsBeyondLegacy = row - kLegacyRowsPerAisle - 1;
    final pinsPerExtendedAisle =
        (kRowsPerAisle - kLegacyRowsPerAisle) *
        kCellsPerRow *
        kBasePinsPerCell;
    return kLegacySlotsPerLocation +
        (aisle - 1) * pinsPerExtendedAisle +
        rowsBeyondLegacy * kCellsPerRow * kBasePinsPerCell +
        (cell - 1) * kBasePinsPerCell +
        pinNo;
  }

  final extendedRowsEnd =
      kLegacySlotsPerLocation + kExtendedRowsSlots;
  final pinsPerFullAisle =
      kRowsPerAisle * kCellsPerRow * kBasePinsPerCell;
  return extendedRowsEnd +
      (aisle - kLegacyAislesPerShelf - 1) * pinsPerFullAisle +
      (row - 1) * kCellsPerRow * kBasePinsPerCell +
      (cell - 1) * kBasePinsPerCell +
      pinNo;
}

int _extraCellOrdinal(int aisle, int row, int cell) =>
    ((aisle - 1) * kRowsPerAisle + (row - 1)) * kCellsPerRow +
    (cell - 1);

int _aisleFromPosition(int position) {
  if (position < 1) return 0;
  if (position <= kBaseSlotsPerLocation) {
    return _baseAisleFromPosition(position);
  }
  final extra = position - kBaseSlotsPerLocation - 1;
  final cellOrdinal = extra ~/ kExtraPinsPerCell;
  return (cellOrdinal ~/ (kRowsPerAisle * kCellsPerRow)) + 1;
}

int _rowFromPosition(int position) {
  if (position < 1) return 0;
  if (position <= kBaseSlotsPerLocation) {
    return _baseRowFromPosition(position);
  }
  final extra = position - kBaseSlotsPerLocation - 1;
  final cellOrdinal = extra ~/ kExtraPinsPerCell;
  final withinAisle = cellOrdinal % (kRowsPerAisle * kCellsPerRow);
  return (withinAisle ~/ kCellsPerRow) + 1;
}

int _cellFromPosition(int position) {
  if (position < 1) return 0;
  if (position <= kBaseSlotsPerLocation) {
    return _baseCellFromPosition(position);
  }
  final extra = position - kBaseSlotsPerLocation - 1;
  final cellOrdinal = extra ~/ kExtraPinsPerCell;
  return (cellOrdinal % kCellsPerRow) + 1;
}

int _flatCellNumber(int row, int cell) =>
    ((row - 1) * kCellsPerRow) + cell;

int _flatCellFromPosition(int position) {
  if (position < 1) return 0;
  return _flatCellNumber(
    _rowFromPosition(position),
    _cellFromPosition(position),
  );
}

int _rowFromFlatCell(int flatCell) =>
    ((flatCell - 1) ~/ kCellsPerRow) + 1;

int _innerCellFromFlatCell(int flatCell) =>
    ((flatCell - 1) % kCellsPerRow) + 1;

int _pinInCell(int position) {
  if (position < 1) return 0;
  if (position <= kBaseSlotsPerLocation) {
    return _basePinInCell(position);
  }
  final extra = position - kBaseSlotsPerLocation - 1;
  return kBasePinsPerCell + (extra % kExtraPinsPerCell) + 1;
}

int _slotFromParts(int aisle, int row, int cell, int pinNo) {
  if (pinNo <= kBasePinsPerCell) {
    return _baseSlotFromParts(aisle, row, cell, pinNo);
  }
  final ordinal = _extraCellOrdinal(aisle, row, cell);
  return kBaseSlotsPerLocation +
      ordinal * kExtraPinsPerCell +
      (pinNo - kBasePinsPerCell);
}

String _positionLabel(
  int position, {
  String warehouseId = kWarehouseVf,
}) {
  if (position < 1) return '-';
  return 'Kệ ${_aisleFromPosition(position)} • '
      '${warehouseCellTerm(warehouseId)} ${_flatCellFromPosition(position)} • '
      'Slot ${_pinInCell(position).toString().padLeft(2, '0')}';
}

String _rackPositionLabel(
  String shelf,
  int position, {
  String warehouseId = kWarehouseVf,
}) {
  if (position < 1) return 'Dãy số ${_displayShelf(shelf)}';
  return 'Dãy số ${_displayShelf(shelf)} • '
      '${_positionLabel(position, warehouseId: warehouseId)}';
}

class LoginResult {
  const LoginResult({
    required this.valid,
    required this.message,
    required this.sessionToken,
    required this.user,
  });

  final bool valid;
  final String message;
  final String sessionToken;
  final UserAccount? user;

  factory LoginResult.fromJson(Map<String, dynamic> json) {
    final rawUser = json['user'];
    return LoginResult(
      valid: json['valid'] == true,
      message: '${json['message'] ?? ''}',
      sessionToken: '${json['sessionToken'] ?? ''}',
      user: rawUser is Map
          ? UserAccount.fromJson(Map<String, dynamic>.from(rawUser))
          : null,
    );
  }
}

class UserAccount {
  const UserAccount({
    required this.id,
    required this.role,
    required this.active,
    required this.permissions,
    required this.createdAt,
    required this.createdBy,
    required this.updatedAt,
  });

  final String id;
  final String role;
  final bool active;
  final Set<String> permissions;
  final String createdAt;
  final String createdBy;
  final String updatedAt;

  bool get isAdmin => role == 'ADMIN';
  bool has(String permission) => isAdmin || permissions.contains(permission);

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'active': active,
        'permissions': {
          for (final permission in permissions) permission: true,
        },
        'createdAt': createdAt,
        'createdBy': createdBy,
        'updatedAt': updatedAt,
      };

  factory UserAccount.fromJson(Map<String, dynamic> json) {
    final p = json['permissions'];
    final enabled = <String>{};
    if (p is Map) {
      for (final entry in p.entries) {
        if (entry.value == true) enabled.add('${entry.key}');
      }
    }
    return UserAccount(
      id: '${json['id'] ?? ''}',
      role: '${json['role'] ?? 'USER'}'.toUpperCase(),
      active: json['active'] == true,
      permissions: enabled,
      createdAt: '${json['createdAt'] ?? ''}',
      createdBy: '${json['createdBy'] ?? ''}',
      updatedAt: '${json['updatedAt'] ?? ''}',
    );
  }
}

class HomeData {
  const HomeData({
    required this.summary,
    required this.user,
  });

  final WarehouseSummary summary;
  final UserAccount user;

  factory HomeData.fromJson(Map<String, dynamic> json) {
    return HomeData(
      summary: WarehouseSummary.fromJson(
        Map<String, dynamic>.from(json['summary'] as Map? ?? const {}),
      ),
      user: UserAccount.fromJson(
        Map<String, dynamic>.from(json['user'] as Map? ?? const {}),
      ),
    );
  }
}

class WarehouseSummary {
  const WarehouseSummary({
    required this.totalPins,
    required this.totalLocations,
    required this.fullLocations,
    required this.emptySlots,
  });

  final int totalPins;
  final int totalLocations;
  final int fullLocations;
  final int emptySlots;

  factory WarehouseSummary.fromJson(Map<String, dynamic> json) {
    return WarehouseSummary(
      totalPins: _asInt(json['totalPins']),
      totalLocations: _asInt(json['totalLocations']),
      fullLocations: _asInt(json['fullLocations']),
      emptySlots: _asInt(json['emptySlots']),
    );
  }
}

class LocationSummary {
  const LocationSummary({
    required this.id,
    required this.occupied,
    required this.capacity,
  });

  final String id;
  final int occupied;
  final int capacity;

  int get empty => max(0, capacity - occupied);
  bool get isFull => occupied >= capacity;

  factory LocationSummary.fromJson(
    Map<String, dynamic> json, {
    required int fallbackCapacity,
  }) {
    final parsedCapacity = _asInt(json['capacity']);
    return LocationSummary(
      id: '${json['location'] ?? ''}',
      occupied: _asInt(json['occupied']),
      capacity: parsedCapacity > 0 ? parsedCapacity : fallbackCapacity,
    );
  }
}

class SlotInfo {
  const SlotInfo({
    required this.slot,
    this.pinCode,
    this.storedAt,
  });

  final int slot;
  final String? pinCode;
  final String? storedAt;

  bool get isEmpty => pinCode == null || pinCode!.trim().isEmpty;
  int get aisle => _aisleFromPosition(slot);
  int get row => _rowFromPosition(slot);
  int get cell => _cellFromPosition(slot);
  int get pinInCell => _pinInCell(slot);

  factory SlotInfo.fromJson(Map<String, dynamic> json) {
    return SlotInfo(
      slot: _asInt(json['slot']),
      pinCode: json['pinCode']?.toString(),
      storedAt: json['storedAt']?.toString(),
    );
  }
}

class RackLabelSet {
  RackLabelSet(
    List<dynamic> rows, {
    required this.warehouseId,
  }) {
    for (final raw in rows.whereType<Map>()) {
      final item = Map<String, dynamic>.from(raw);
      final kind = '${item['kind'] ?? ''}'.toUpperCase();
      final aisle = _asInt(item['aisle']);
      final row = _asInt(item['row']);
      final cell = _asInt(item['cell']);
      final label = '${item['label'] ?? ''}'.trim();
      if (label.isNotEmpty) {
        _labels['$kind:$aisle:$row:$cell'] = label;
      }
    }
  }

  final String warehouseId;
  final Map<String, String> _labels = {};

  String get cellTerm => warehouseCellTerm(warehouseId);

  String shelfName(String location) =>
      _labels['KE:0:0:0'] ?? 'Dãy số ${_displayShelf(location)}';

  int get aisleCount {
    final value = int.tryParse(_labels['SO_DAY:0:0:0'] ?? '');
    return (value ?? kAislesPerShelf).clamp(1, kAislesPerShelf).toInt();
  }

  int get cellCount {
    if (warehouseId == kWarehouseVf) return kVfCellsPerAisle;
    final direct = int.tryParse(_labels['SO_O:0:0:0'] ?? '');
    return (direct ?? kAutoDefaultPositionsPerAisle)
        .clamp(1, kAutoMaxPositionsPerAisle)
        .toInt();
  }

  int get slotsPerCell {
    final value = int.tryParse(_labels['SO_PIN_O:0:0:0'] ?? '');
    return (value ?? kPinsPerCell).clamp(1, kPinsPerCell).toInt();
  }

  int get rowCount =>
      (cellCount / kCellsPerRow).ceil().clamp(1, kRowsPerAisle).toInt();

  int get capacity => aisleCount * cellCount * slotsPerCell;

  String aisleName(int aisle) =>
      _labels['DAY:$aisle:0:0'] ?? 'Kệ $aisle';

  String rowName(int aisle, int row) =>
      _labels['HANG:$aisle:$row:0'] ?? '';

  String cellName(int aisle, int row, int cell) =>
      _labels['O:$aisle:$row:$cell'] ??
      '$cellTerm ${_flatCellNumber(row, cell)}';
}

class LocationDetail {
  LocationDetail({
    required this.location,
    required this.occupied,
    required this.slots,
    required this.labels,
  });

  final String location;
  final int occupied;
  final List<SlotInfo> slots;
  final RackLabelSet labels;

  bool get isFull => occupied >= labels.capacity;

  List<SlotInfo> cellSlots(int aisle, int row, int cell) {
    final flat = _flatCellNumber(row, cell);
    if (aisle < 1 || aisle > labels.aisleCount || flat < 1 || flat > labels.cellCount) {
      return <SlotInfo>[];
    }
    return slots
        .where((e) =>
            e.aisle == aisle &&
            e.row == row &&
            e.cell == cell &&
            e.pinInCell <= labels.slotsPerCell)
        .toList()
      ..sort((a, b) => a.pinInCell.compareTo(b.pinInCell));
  }

  int cellOccupied(int aisle, int row, int cell) =>
      cellSlots(aisle, row, cell).where((e) => !e.isEmpty).length;

  factory LocationDetail.fromJson(
    Map<String, dynamic> json, {
    required String warehouseId,
  }) {
    final rows = json['slots'] as List<dynamic>? ?? const [];
    return LocationDetail(
      location: '${json['location'] ?? ''}',
      occupied: _asInt(json['occupied']),
      slots: rows
          .whereType<Map>()
          .map((e) => SlotInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      labels: RackLabelSet(
        json['labels'] as List<dynamic>? ?? const [],
        warehouseId: warehouseId,
      ),
    );
  }
}

class PinSearchResult {
  const PinSearchResult({
    required this.found,
    required this.active,
    required this.code,
    required this.location,
    required this.slot,
    required this.storedAt,
    required this.exportedAt,
    required this.pinType,
    required this.aisleName,
    required this.rowName,
    required this.cellName,
  });

  final bool found;
  final bool active;
  final String code;
  final String location;
  final int slot;
  final String storedAt;
  final String exportedAt;
  final String pinType;
  final String aisleName;
  final String rowName;
  final String cellName;

  int get aisle => _aisleFromPosition(slot);
  int get row => _rowFromPosition(slot);
  int get cell => _cellFromPosition(slot);
  int get pinInCell => _pinInCell(slot);

  factory PinSearchResult.fromJson(
    Map<String, dynamic> json, {
    required String warehouseId,
  }) {
    return PinSearchResult(
      found: json['found'] == true,
      active: json['active'] == true,
      code: '${json['code'] ?? ''}',
      location: '${json['location'] ?? ''}',
      slot: _asInt(json['slot']),
      storedAt: '${json['storedAt'] ?? ''}',
      exportedAt: '${json['exportedAt'] ?? ''}',
      pinType: '${json['pinType'] ?? json['batteryType'] ?? ''}',
      aisleName: '${json['aisleName'] ?? ''}'.trim().isEmpty
          ? 'Kệ ${_aisleFromPosition(_asInt(json['slot']))}'
          : '${json['aisleName']}',
      rowName: '',
      cellName: '${json['cellName'] ?? ''}'.trim().isEmpty
          ? '${warehouseCellTerm(warehouseId)} '
              '${_flatCellFromPosition(_asInt(json['slot']))}'
          : '${json['cellName']}',
    );
  }
}

class HistoryEntry {
  const HistoryEntry({
    required this.timestamp,
    required this.pinCode,
    required this.action,
    required this.location,
    required this.slot,
    required this.operatorId,
    required this.note,
    required this.deviceId,
    this.pinType = '',
  });

  final String timestamp;
  final String pinCode;
  final String action;
  final String location;
  final int slot;
  final String operatorId;
  final String note;
  final String deviceId;
  final String pinType;

  bool get isInbound => action == 'NHAP' || action == 'THAY_NHAP';
  bool get isOutbound => action == 'XUAT' || action == 'THAY_XUAT';
  bool get isSystem => !isInbound && !isOutbound;

  int get aisle => _aisleFromPosition(slot);
  int get row => _rowFromPosition(slot);
  int get cell => _cellFromPosition(slot);
  int get pinInCell => _pinInCell(slot);

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      timestamp: '${json['timestamp'] ?? ''}',
      pinCode: '${json['pinCode'] ?? ''}',
      action: '${json['action'] ?? ''}',
      location: '${json['location'] ?? ''}',
      slot: _asInt(json['slot']),
      operatorId: '${json['operatorId'] ?? ''}',
      note: '${json['note'] ?? ''}',
      deviceId: '${json['deviceId'] ?? ''}',
      pinType: '${json['pinType'] ?? json['batteryType'] ?? ''}',
    );
  }
}

enum OutcomeType { success, duplicate, full, error }

class ScanDuplicateTracker {
  final Set<String> _seen = <String>{};

  bool contains(String code) => _seen.contains(code.trim());

  bool markIfNew(String code) {
    final clean = code.trim();
    if (clean.isEmpty) return false;
    return _seen.add(clean);
  }

  void mark(String code) {
    final clean = code.trim();
    if (clean.isNotEmpty) _seen.add(clean);
  }

  void unmark(String code) {
    _seen.remove(code.trim());
  }

  void clear() => _seen.clear();
}

class ScanOutcome {
  const ScanOutcome({
    required this.type,
    required this.message,
    this.location,
    this.slot,
    this.full = false,
  });

  final OutcomeType type;
  final String message;
  final String? location;
  final int? slot;
  final bool full;

  factory ScanOutcome.success(
    String message, {
    String? location,
    int? slot,
    bool full = false,
  }) {
    return ScanOutcome(
      type: OutcomeType.success,
      message: message,
      location: location,
      slot: slot,
      full: full,
    );
  }

  factory ScanOutcome.duplicate(
    String message, {
    String? location,
    int? slot,
  }) {
    return ScanOutcome(
      type: OutcomeType.duplicate,
      message: message,
      location: location,
      slot: slot,
    );
  }

  factory ScanOutcome.full(String message) =>
      ScanOutcome(type: OutcomeType.full, message: message);

  factory ScanOutcome.error(String message) =>
      ScanOutcome(type: OutcomeType.error, message: message);
}

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.serverUrl,
    required this.autoServerUrl,
    required this.deviceId,
    required this.onSessionAuthenticated,
    required this.onSessionCleared,
  });

  final String serverUrl;
  final String autoServerUrl;
  final String deviceId;
  final Future<int> Function(UserAccount user, String sessionToken)
      onSessionAuthenticated;
  final Future<void> Function() onSessionCleared;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _id = TextEditingController(text: kDefaultUser);
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  Future<void> _login() async {
    final id = _id.text.trim().toUpperCase();
    final password = _password.text;

    if (id.isEmpty || password.isEmpty) {
      _snack(context, 'Nhập ID và mật khẩu.', error: true);
      return;
    }

    setState(() => _busy = true);
    try {
      await LocalWarehouseStore.instance.switchWarehouse(kWarehouseVf);
      final api = WarehouseApi(
        widget.serverUrl,
        widget.deviceId,
        operatorId: id,
        warehouseId: kWarehouseVf,
        authBaseUrl: widget.serverUrl,
      );

      final result = await api.login(id, password);

      if (!mounted) return;
      if (!result.valid) {
        _snack(
          context,
          result.message.isEmpty ? 'Sai ID hoặc mật khẩu.' : result.message,
          error: true,
        );
        return;
      }
      if (result.user == null || result.sessionToken.isEmpty) {
        _snack(
          context,
          'Backend chưa hỗ trợ OFFLINE V4.',
          error: true,
        );
        return;
      }

      final sessionExpiresAtMs = await widget.onSessionAuthenticated(
        result.user!,
        result.sessionToken,
      );
      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => HomePage(
            serverUrl: widget.serverUrl,
            autoServerUrl: widget.autoServerUrl,
            deviceId: widget.deviceId,
            operatorId: result.user!.id,
            isAdmin: result.user!.isAdmin,
            sessionToken: result.sessionToken,
            sessionExpiresAtMs: sessionExpiresAtMs,
            initialPermissions: result.user!.permissions,
            onSessionAuthenticated: widget.onSessionAuthenticated,
            onSessionCleared: widget.onSessionCleared,
          ),
        ),
      );
    } catch (e) {
      if (mounted) _snack(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _id.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    children: [
                      const CircleAvatar(
                        radius: 34,
                        backgroundColor: Color(0xffb71c1c),
                        foregroundColor: Colors.white,
                        child: Icon(Icons.inventory_2, size: 36),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'N07 HUBDNI',
                        style: TextStyle(
                          fontSize: 27,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const Text('KHO PIN VINFAST • XE MÁY ĐIỆN / Ô TÔ ĐIỆN'),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _id,
                        decoration: const InputDecoration(
                          labelText: 'ID',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        obscureText: _obscure,
                        onSubmitted: (_) => _login(),
                        decoration: InputDecoration(
                          labelText: 'Mật khẩu',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _login,
                          icon: _busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.login),
                          label: const Text('ĐĂNG NHẬP'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Đăng nhập một lần • dùng chung tài khoản cho 2 kho.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.serverUrl,
    required this.autoServerUrl,
    required this.deviceId,
    required this.operatorId,
    required this.isAdmin,
    required this.sessionToken,
    required this.sessionExpiresAtMs,
    required this.initialPermissions,
    required this.onSessionAuthenticated,
    required this.onSessionCleared,
  });

  final String serverUrl;
  final String autoServerUrl;
  final String deviceId;
  final String operatorId;
  final bool isAdmin;
  final String sessionToken;
  final int sessionExpiresAtMs;
  final Set<String> initialPermissions;
  final Future<int> Function(UserAccount user, String sessionToken)
      onSessionAuthenticated;
  final Future<void> Function() onSessionCleared;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  WarehouseSummary? _summary;
  String? _error;
  Timer? _timer;
  Timer? _syncRetryTimer;
  Timer? _autoUploadTimer;
  bool _autoUploadCheckRunning = false;
  int _syncRetryFailures = 0;
  bool _appActive = true;
  bool _forcingLogout = false;
  bool _switchingWarehouse = false;
  bool _revisionChecking = false;
  String _warehouseId = kWarehouseVf;
  String _lastRevision = '';
  late Set<String> _permissions;

  String get _warehouseUrl =>
      _warehouseId == kWarehouseAuto ? widget.autoServerUrl : widget.serverUrl;

  WarehouseApi get api => WarehouseApi(
        _warehouseUrl,
        widget.deviceId,
        operatorId: widget.operatorId,
        sessionToken: widget.sessionToken,
        warehouseId: _warehouseId,
        authBaseUrl: widget.serverUrl,
      );

  bool get _sessionExpired =>
      widget.sessionExpiresAtMs > 0 &&
      DateTime.now().millisecondsSinceEpoch >= widget.sessionExpiresAtMs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _permissions = Set<String>.from(widget.initialPermissions);
    LocalWarehouseStore.instance.syncState.addListener(_syncChanged);
    _refresh();
    _timer = Timer.periodic(
      kForegroundSyncInterval,
      (_) => unawaited(_checkRevision()),
    );

    // Retry sync quickly only while there is something to recover.
    // When fully synced this timer does no network work.
    _syncRetryTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(_retrySyncIfNeeded()),
    );

    _autoUploadTimer = Timer.periodic(
      kAutoUploadPollInterval,
      (_) => unawaited(_autoUploadExpiredTransfers()),
    );
    unawaited(_autoUploadExpiredTransfers());
  }

  Future<void> _retrySyncIfNeeded() async {
    if (!mounted || !_appActive || _sessionExpired || _switchingWarehouse) return;
    final state = LocalWarehouseStore.instance.syncState.value;
    if (state.autoPending <= 0 && state.online) {
      _syncRetryFailures = 0;
      return;
    }
    if (_syncRetryFailures >= 3) return;
    await api.syncNow(reason: 'retry');
    final after = LocalWarehouseStore.instance.syncState.value;
    if (after.online) {
      _syncRetryFailures = 0;
    } else {
      _syncRetryFailures++;
    }
  }

  Future<void> _checkRevision() async {
    if (!mounted ||
        !_appActive ||
        _revisionChecking ||
        _switchingWarehouse ||
        _sessionExpired) {
      return;
    }
    _revisionChecking = true;
    try {
      final revisionText = await api.revision();
      final serverRevision = int.tryParse(revisionText) ?? 0;
      final localRevision = await LocalWarehouseStore.instance.serverRevision();
      _lastRevision = revisionText;
      if (serverRevision > localRevision) {
        await api.syncNow(bypassThrottle: true, reason: 'revision_change');
        if (mounted) await _refresh(silent: true, skipSync: true);
      }
    } catch (_) {
      // Probe cực nhỏ, không retry ngay trong cùng tick.
    } finally {
      _revisionChecking = false;
    }
  }

  Future<void> _switchWarehouse(String warehouseId) async {
    final next = warehouseId == kWarehouseAuto ? kWarehouseAuto : kWarehouseVf;
    if (_switchingWarehouse || next == _warehouseId) return;
    final previous = _warehouseId;
    final currentSync = LocalWarehouseStore.instance.syncState.value;
    if (currentSync.syncing) {
      _snack(
        context,
        'Đang đồng bộ ${warehouseLabel(_warehouseId)}. Hãy đợi hoàn tất rồi chuyển hạng mục.',
        error: true,
      );
      return;
    }
    if (currentSync.pending > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('CÒN THAO TÁC CHƯA ĐỒNG BỘ'),
          content: Text(
            '${warehouseLabel(_warehouseId)} còn '
            '${currentSync.pending} thao tác trên máy. Dữ liệu sẽ không bị '
            'xóa hay chuyển sang kho khác; hãy quay lại đúng hạng mục để '
            'xác nhận/đồng bộ.\n\nVẫn chuyển hạng mục?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Ở LẠI'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('CHUYỂN'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      _switchingWarehouse = true;
      _error = null;
    });
    try {
      // Đổi DB vật lý trước để mọi snapshot chỉ có thể ghi vào đúng kho.
      await LocalWarehouseStore.instance.switchWarehouse(next);
      await LocalWarehouseStore.instance.cacheUser({
        'id': widget.operatorId,
        'role': widget.isAdmin ? 'ADMIN' : 'USER',
        'active': true,
        'permissions': {for (final p in _permissions) p: true},
      });
      final targetApi = WarehouseApi(
        next == kWarehouseAuto ? widget.autoServerUrl : widget.serverUrl,
        widget.deviceId,
        operatorId: widget.operatorId,
        sessionToken: widget.sessionToken,
        warehouseId: next,
        authBaseUrl: widget.serverUrl,
      );

      // Không cho thao tác trên các Dãy mặc định/không đầy đủ khi hạng mục này
      // chưa từng tải snapshot. Lần mở đầu bắt buộc có mạng và đúng Backend.
      final needsFirstSnapshot =
          !await LocalWarehouseStore.instance.hasSnapshot();
      if (needsFirstSnapshot) {
        await targetApi.syncNow(bypassThrottle: true, reason: 'warehouse_first_open');
        if (!await LocalWarehouseStore.instance.hasSnapshot()) {
          final state = LocalWarehouseStore.instance.syncState.value;
          throw ApiException(
            state.message.isEmpty
                ? 'Chưa tải được dữ liệu lần đầu cho ${warehouseLabel(next)}.'
                : 'Chưa tải được dữ liệu lần đầu: ${state.message}',
            code: 'first_sync_required',
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _warehouseId = next;
        _lastRevision = '';
      });
      await _refresh(silent: true, skipSync: true);
      if (!mounted) return;
      setState(() => _switchingWarehouse = false);

      // Khi đã có snapshot local, đồng bộ mới chạy nền để chuyển hạng mục nhanh.
      if (!needsFirstSnapshot) {
        unawaited(_syncAfterWarehouseSwitch(next, targetApi));
      } else {
        unawaited(_autoUploadExpiredTransfers());
      }
    } catch (e) {
      try {
        await LocalWarehouseStore.instance.switchWarehouse(previous);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _warehouseId = previous;
          _switchingWarehouse = false;
          _error = 'Không chuyển được ${warehouseLabel(next)}: $e';
        });
      }
    }
  }

  Future<void> _syncAfterWarehouseSwitch(
    String warehouseId,
    WarehouseApi targetApi,
  ) async {
    try {
      // Nếu request kho cũ còn đang kết thúc, chờ ngắn thay vì bỏ luôn lần
      // sync đầu của kho mới. UI đã đổi bằng cache local nên người dùng không chờ.
      for (var i = 0; i < 24 && WarehouseApi._syncingNow; i++) {
        if (!mounted || _warehouseId != warehouseId) return;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (!mounted || _warehouseId != warehouseId) return;
      await targetApi.syncNow(bypassThrottle: true, reason: 'warehouse_switch');
      if (!mounted || _warehouseId != warehouseId) return;
      await _refresh(silent: true, skipSync: true);
      if (!mounted || _warehouseId != warehouseId) return;
      await _autoUploadExpiredTransfers();
    } catch (_) {
      // Cache local vẫn dùng được. Revision foreground sẽ tự thử lại.
    }
  }

  Future<void> _autoUploadExpiredTransfers() async {
    if (!mounted ||
        !_appActive ||
        _autoUploadCheckRunning ||
        _sessionExpired ||
        widget.sessionToken.isEmpty) {
      return;
    }

    final sync = LocalWarehouseStore.instance.syncState.value;
    if (sync.syncing) return;

    _autoUploadCheckRunning = true;
    try {
      final opIds = await LocalWarehouseStore.instance
          .pendingTransferOpIdsOlderThan(
        age: kManualAutoUploadDelay,
        onlyUnattempted: true,
        limit: kAutoUploadMaxOpsPerPass,
      );

      if (opIds.isEmpty || !mounted) return;

      final result = await api.uploadPendingTransfers(opIds);
      final uploaded = _asInt(result['uploaded']);

      // If rows were actually uploaded, refresh Home immediately.
      // If the app was backgrounded/killed, the same check runs on resume.
      if (uploaded > 0 && mounted) {
        await _refresh(silent: true);
      }
    } catch (_) {
      // Automatic upload is best-effort. Failed selected rows are marked with
      // attempts>0 by uploadPendingTransfers, so the 5s local poll cannot
      // become a 5s network retry loop. Manual retry remains available.
    } finally {
      _autoUploadCheckRunning = false;
    }
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverUrl != widget.serverUrl ||
        oldWidget.autoServerUrl != widget.autoServerUrl) {
      _refresh();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _syncRetryTimer?.cancel();
    _autoUploadTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    LocalWarehouseStore.instance.syncState.removeListener(_syncChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      if (_sessionExpired) {
        unawaited(_forceLogout('Phiên đăng nhập 24 giờ đã hết. Vui lòng đăng nhập lại.'));
        return;
      }
      _syncRetryFailures = 0;
      _refresh(silent: true, skipSync: true);
      unawaited(_autoUploadExpiredTransfers());
      unawaited(api.syncNow(bypassThrottle: true, reason: 'resume'));
    }
  }

  void _syncChanged() {
    final state = LocalWarehouseStore.instance.syncState.value;
    if (state.authError.isNotEmpty) {
      unawaited(_forceLogout(state.authError));
      return;
    }
    if (mounted) setState(() {});
  }

  Future<void> _refresh({bool silent = false, bool skipSync = false}) async {
    try {
      final data = await api.homeData();
      if (!mounted) return;
      setState(() {
        _summary = data.summary;
        _permissions = Set<String>.from(data.user.permissions);
        _error = null;
      });
      if (!skipSync) unawaited(api.syncNow());
    } on ApiException catch (e) {
      if (!mounted) return;

      if (const {
        'session_expired',
        'auth_required',
        'account_disabled',
        'user_not_found',
      }.contains(e.code)) {
        await _forceLogout(e.message);
        return;
      }

      if (!silent || _summary == null) {
        setState(() => _error = e.toString());
      }
    } catch (e) {
      if (!mounted) return;
      if (!silent || _summary == null) setState(() => _error = e.toString());
    }
  }

  Future<void> _forceLogout(String message) async {
    if (!mounted || _forcingLogout) return;
    _forcingLogout = true;
    await widget.onSessionCleared();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red.shade700),
    );
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => LoginPage(
          serverUrl: widget.serverUrl,
          autoServerUrl: widget.autoServerUrl,
          deviceId: widget.deviceId,
          onSessionAuthenticated: widget.onSessionAuthenticated,
          onSessionCleared: widget.onSessionCleared,
        ),
      ),
      (_) => false,
    );
  }

  Future<void> _open(Widget page) async {
    try {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => page),
      );
    } catch (e) {
      if (mounted) {
        _snack(
          context,
          'Không mở được màn hình: $e',
          error: true,
        );
      }
    } finally {
      if (mounted) _refresh();
    }
  }

  bool _has(String permission) => widget.isAdmin || _permissions.contains(permission);

  void _locked(String label) {
    _snack(context, 'Tài khoản chưa được ADMIN cấp quyền $label.', error: true);
  }

  Future<void> _logoutServerQuietly() async {
    try {
      await api.logout();
    } catch (_) {}
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ĐĂNG XUẤT'),
        content: Text('Đăng xuất tài khoản ${widget.operatorId}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Đăng xuất'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    unawaited(_logoutServerQuietly());
    await widget.onSessionCleared();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => LoginPage(
          serverUrl: widget.serverUrl,
          autoServerUrl: widget.autoServerUrl,
          deviceId: widget.deviceId,
          onSessionAuthenticated: widget.onSessionAuthenticated,
          onSessionCleared: widget.onSessionCleared,
        ),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'N07 HUBDNI',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            Text(
              'ANDROID • ${warehouseLabel(_warehouseId)}',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Cài đặt',
            onPressed: () => _open(
              SettingsPage(
                serverUrl: widget.serverUrl,
                autoServerUrl: widget.autoServerUrl,
                activeWarehouseId: _warehouseId,
                deviceId: widget.deviceId,
                operatorId: widget.operatorId,
                isAdmin: widget.isAdmin,
                sessionToken: widget.sessionToken,
              ),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: 'Tài khoản',
            icon: const Icon(Icons.account_circle_outlined),
            onSelected: (value) {
              if (value == 'logout') _logout();
            },
            itemBuilder: (_) => [
              PopupMenuItem<String>(
                enabled: false,
                child: Text(
                  '${widget.operatorId}${widget.isAdmin ? ' • ADMIN' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout),
                    SizedBox(width: 10),
                    Text('Đăng xuất'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'CHỌN HẠNG MỤC PIN',
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _warehouseId == kWarehouseVf
                              ? FilledButton.icon(
                                  onPressed: null,
                                  icon: const Icon(Icons.two_wheeler),
                                  label: const Text('XE MÁY ĐIỆN'),
                                )
                              : OutlinedButton.icon(
                                  onPressed: _switchingWarehouse
                                      ? null
                                      : () => _switchWarehouse(kWarehouseVf),
                                  icon: const Icon(Icons.two_wheeler),
                                  label: const Text('XE MÁY ĐIỆN'),
                                ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _warehouseId == kWarehouseAuto
                              ? FilledButton.icon(
                                  onPressed: null,
                                  icon: const Icon(Icons.directions_car_filled_outlined),
                                  label: const Text('Ô TÔ ĐIỆN'),
                                )
                              : OutlinedButton.icon(
                                  onPressed: _switchingWarehouse
                                      ? null
                                      : () => _switchWarehouse(kWarehouseAuto),
                                  icon: const Icon(Icons.directions_car_filled_outlined),
                                  label: const Text('Ô TÔ ĐIỆN'),
                                ),
                        ),
                      ],
                    ),
                    if (_switchingWarehouse) ...[
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<LocalSyncState>(
              valueListenable: LocalWarehouseStore.instance.syncState,
              builder: (_, state, _) => _SyncStatusCard(
                state: state,
                onRetry: () => api.syncNow(bypassThrottle: true, reason: 'manual'),
                onManualPendingTap: () => _open(
                  PendingTransfersPage(
                    inbound: true,
                    api: api,
                    showAll: true,
                    selectAllInitially: true,
                    onUploadFinished: () async {
                      if (mounted) {
                        await _refresh(silent: true);
                      }
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (_error != null)
              _NoticeCard(
                message: _error!,
                color: Colors.orange,
                icon: Icons.cloud_off,
              ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const CircleAvatar(
                          radius: 24,
                          backgroundColor: Color(0xffb71c1c),
                          foregroundColor: Colors.white,
                          child: Icon(Icons.battery_charging_full, size: 27),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'PIN ĐANG TỒN',
                                maxLines: 1,
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: Colors.black54,
                                ),
                              ),
                              Text(
                                '${s?.totalPins ?? 0}',
                                maxLines: 1,
                                style: const TextStyle(
                                  fontSize: 30,
                                  height: 1.05,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _MiniStat(
                            label: 'Dãy số',
                            value: '${s?.totalLocations ?? 0}',
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _MiniStat(
                            label: 'Vị trí trống',
                            value: '${s?.emptySlots ?? 0}',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _QuickHomeAction(
                    icon: Icons.download_rounded,
                    label: 'NHẬP',
                    color: Colors.green,
                    enabled: _has('NHAP_PIN'),
                    onTap: () => _has('NHAP_PIN')
                        ? _open(InboundPage(api: api))
                        : _locked('NHẬP PIN'),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: _QuickHomeAction(
                    icon: Icons.upload_rounded,
                    label: 'XUẤT',
                    color: Colors.orange,
                    enabled: _has('XUAT_PIN'),
                    onTap: () => _has('XUAT_PIN')
                        ? _open(OutboundPage(api: api))
                        : _locked('XUẤT PIN'),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: _QuickHomeAction(
                    icon: Icons.inventory_2_outlined,
                    label: 'TỒN KHO',
                    color: Colors.teal,
                    enabled: _has('TIM_PIN') || _has('VI_TRI'),
                    onTap: () => (_has('TIM_PIN') || _has('VI_TRI'))
                        ? _open(
                            InventoryPage(
                              api: api,
                            ),
                          )
                        : _locked('TỒN KHO'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _HomeAction(
              icon: Icons.grid_view_rounded,
              title: 'VỊ TRÍ DÃY',
              subtitle: _warehouseId == kWarehouseAuto
                  ? 'Dãy → Kệ → Vị trí 1–6; chỉ xem, cấu hình trên PC.'
                  : 'Dãy → Kệ → 4 Ô cố định; chỉ xem, cấu hình trên PC.',
              color: Colors.blue,
              enabled: _has('VI_TRI'),
              onTap: () => _has('VI_TRI')
                  ? _open(LocationsPage(api: api))
                  : _locked('VỊ TRÍ DÃY'),
            ),
            const SizedBox(height: 10),
            _HomeAction(
              icon: Icons.search,
              title: 'TÌM PIN',
              subtitle: 'Tìm bằng text, QR camera hoặc QR từ album',
              color: Colors.purple,
              enabled: _has('TIM_PIN'),
              onTap: () => _has('TIM_PIN')
                  ? _open(SearchPage(api: api, canExportPin: false))
                  : _locked('TÌM PIN'),
            ),
            const SizedBox(height: 10),
            if (_warehouseId == kWarehouseVf) ...[
              _HomeAction(
                icon: Icons.qr_code_2_rounded,
                title: 'ĐỐI CHIẾU QR THÙNG / PIN',
                subtitle: 'Dùng cho PIN XE MÁY ĐIỆN VINFAST tại hiện trường',
                color: Colors.cyan,
                onTap: () => _open(const QrPairCheckPage()),
              ),
              const SizedBox(height: 10),
            ],
            _HomeAction(
              icon: Icons.fact_check_outlined,
              title: 'KIỂM KÊ',
              subtitle: 'Quét thực tế và đối chiếu với dữ liệu hệ thống',
              color: Colors.teal,
              enabled: _has('KIEM_KE'),
              onTap: () => _has('KIEM_KE')
                  ? _open(AuditPage(api: api))
                  : _locked('KIỂM KÊ'),
            ),
            const SizedBox(height: 10),
            _HomeAction(
              icon: Icons.history,
              title: 'LỊCH SỬ GẦN ĐÂY',
              subtitle: 'NHẬP / XUẤT / THAY PIN của đúng hạng mục đang mở',
              color: Colors.brown,
              enabled: _has('LICH_SU'),
              onTap: () => _has('LICH_SU')
                  ? _open(
                      HistoryPage(
                        api: api,
                      ),
                    )
                  : _locked('LỊCH SỬ'),
            ),
            const SizedBox(height: 10),
            const _MobileScopeNote(),
          ],
        ),
      ),
    );
  }
}

class _MobileScopeNote extends StatelessWidget {
  const _MobileScopeNote();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.blueGrey.withValues(alpha: 0.055),
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.computer_outlined, size: 19, color: Colors.blueGrey),
            SizedBox(width: 9),
            Expanded(
              child: Text(
                'Android chỉ dùng cho hiện trường. Thêm/Xóa/đổi tên Dãy, sửa layout, xuất Excel, quản trị User và Backend đều thực hiện trên N07 HUBDNI PC.',
                style: TextStyle(fontSize: 11.5, color: Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Colors.black54),
          ),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickHomeAction extends StatelessWidget {
  const _QuickHomeAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final MaterialColor color;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
          child: Column(
            children: [
              Icon(
                enabled ? icon : Icons.lock_outline,
                size: 26,
                color: enabled ? color.shade700 : Colors.grey,
              ),
              const SizedBox(height: 5),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    color: enabled ? null : Colors.grey,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeAction extends StatelessWidget {
  const _HomeAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final MaterialColor color;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  enabled ? icon : Icons.lock_outline,
                  color: enabled ? color.shade700 : Colors.grey,
                  size: 30,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                        color: enabled ? null : Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: enabled ? Colors.black54 : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(enabled ? Icons.chevron_right : Icons.lock_outline),
            ],
          ),
        ),
      ),
    );
  }
}

class InboundPage extends StatefulWidget {
  const InboundPage({super.key, required this.api});
  final WarehouseApi api;

  @override
  State<InboundPage> createState() => _InboundPageState();
}

class InboundTarget {
  const InboundTarget({
    required this.location,
    required this.aisle,
    required this.row,
    required this.cell,
    required this.aisleName,
    required this.rowName,
    required this.cellName,
    required this.occupied,
    required this.slotCapacity,
  });

  final String location;
  final int aisle;
  final int row;
  final int cell;
  final String aisleName;
  final String rowName;
  final String cellName;
  final int occupied;
  final int slotCapacity;

  bool get isFull => occupied >= slotCapacity;

  String get label =>
      'Dãy số ${_displayShelf(location)} • $aisleName • $cellName';

  InboundTarget copyWith({int? occupied}) => InboundTarget(
        location: location,
        aisle: aisle,
        row: row,
        cell: cell,
        aisleName: aisleName,
        rowName: rowName,
        cellName: cellName,
        occupied: occupied ?? this.occupied,
        slotCapacity: slotCapacity,
      );
}

class _InboundPageState extends State<InboundPage> {
  final _manual = TextEditingController();
  final _pinType = TextEditingController();
  final _manualFocus = FocusNode();
  List<String> _pinTypeSuggestions = const [];
  String _fastStatus = 'Bắt buộc chọn vị trí trước khi bắn nhập';
  bool _fastStatusOk = true;
  final List<String> _recentScans = [];
  List<LocationSummary> _locations = const [];
  InboundTarget? _target;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
    unawaited(_loadPinTypes());
  }

  Future<void> _loadPinTypes() async {
    try {
      final rows = await widget.api.listPinTypes();
      if (mounted) setState(() => _pinTypeSuggestions = rows);
    } catch (_) {}
  }

  @override
  void dispose() {
    _manual.dispose();
    _pinType.dispose();
    _manualFocus.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    try {
      final rows = await widget.api.listLocations();
      if (!mounted) return;
      setState(() {
        _locations = rows;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectTarget() async {
    if (_locations.isEmpty) {
      _snack(context, 'Chưa có Dãy. Hãy tạo Dãy trên PC trước.', error: true);
      return;
    }
    final target = await showDialog<InboundTarget>(
      context: context,
      builder: (_) => _CellPickerDialog(
        api: widget.api,
        locations: _locations,
        initial: _target,
      ),
    );
    if (target == null || !mounted) return;
    setState(() {
      _target = target;
      _fastStatus = target.isFull
          ? '${target.label} đã đầy ${target.slotCapacity}/${target.slotCapacity}'
          : 'Đã khóa nơi nhập • ${target.label} • '
              '${target.occupied}/${target.slotCapacity}';
      _fastStatusOk = !target.isFull;
    });
    _keepManualFocus();
  }

  Future<ContinuousScanFeedback> _importQuick(String raw) async {
    final code = raw.trim();
    if (code.isEmpty) {
      return const ContinuousScanFeedback(false, 'Mã trống.');
    }
    unawaited(_vibrateScan());
    final target = _target;
    final term = warehouseCellTerm(widget.api.warehouseId);
    if (target == null) {
      return ContinuousScanFeedback(
        false,
        'BẮT BUỘC chọn Dãy số / Kệ / $term trước khi nhập.',
      );
    }
    if (target.isFull) {
      return ContinuousScanFeedback(
        false,
        '$term đã đầy ${target.slotCapacity}/${target.slotCapacity}. '
            'Hãy chọn $term khác.',
      );
    }

    final selectedPinType = _pinType.text.trim();
    final outcome = await widget.api.importPinToCell(
      target.location,
      target.aisle,
      target.row,
      target.cell,
      code,
      pinType: selectedPinType,
    );

    if (mounted && outcome.type == OutcomeType.success) {
      setState(() {
        if (selectedPinType.isNotEmpty &&
            !_pinTypeSuggestions.any((e) => e.toLowerCase() == selectedPinType.toLowerCase())) {
          _pinTypeSuggestions = [..._pinTypeSuggestions, selectedPinType]..sort();
        }
        _target = target.copyWith(
          occupied: min(target.slotCapacity, target.occupied + 1),
        );
        _locations = _locations.map((e) {
          if (e.id != target.location) return e;
          return LocationSummary(
            id: e.id,
            occupied: min(e.capacity, e.occupied + 1),
            capacity: e.capacity,
          );
        }).toList();
      });
    }

    return ContinuousScanFeedback(
      outcome.type == OutcomeType.success,
      outcome.message,
      duplicate: outcome.type == OutcomeType.duplicate,
    );
  }

  void _keepManualFocus() {
    if (!mounted || _target == null || _target!.isFull) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _target != null && !_target!.isFull) {
        _focusScannerInput(_manualFocus);
      }
    });
  }

  Future<void> _manualSubmit(String value) async {
    final term = warehouseCellTerm(widget.api.warehouseId);
    final code = value.trim();
    if (code.isEmpty) {
      _keepManualFocus();
      return;
    }
    if (_target == null || _target!.isFull) {
      setState(() {
        _fastStatus = _target == null
            ? 'BẮT BUỘC chọn $term trước khi bắn nhập'
            : '$term đã đầy. Hãy chọn $term khác.';
        _fastStatusOk = false;
      });
      return;
    }

    // iData gửi mã + Enter. Xóa ngay và trả focus ngay, không đợi Google.
    _manual.clear();
    _focusScannerInput(_manualFocus);

    final feedback = await _importQuick(code);
    if (!mounted) return;

    setState(() {
      _fastStatus = feedback.message;
      _fastStatusOk = feedback.success;
      _recentScans.insert(
        0,
        '${feedback.success ? '✓' : '✕'} $code • ${feedback.message}',
      );
      if (_recentScans.length > 8) _recentScans.removeLast();
    });

    if (feedback.duplicate) {
      await _showDuplicateWarning(
        context,
        code: code,
        message: feedback.message,
      );
      if (!mounted) return;
    }

    _keepManualFocus();
  }

  Future<void> _continuousCamera() async {
    final term = warehouseCellTerm(widget.api.warehouseId);
    final target = _target;
    if (target == null) {
      _snack(context, 'Bắt buộc chọn $term nhập trước.', error: true);
      return;
    }
    if (target.isFull) {
      _snack(context, '$term đã đầy. Hãy chọn $term khác.', error: true);
      return;
    }

    await _scanContinuous(
      context,
      title: 'NHẬP • ${target.label}',
      onCode: _importQuick,
    );
    await _refresh();
    _keepManualFocus();
  }

  Future<void> _genericAlbum() async {
    final term = warehouseCellTerm(widget.api.warehouseId);
    if (_target == null) {
      _snack(context, 'Bắt buộc chọn $term nhập trước.', error: true);
      return;
    }
    final codes = await _pickQrCodesFromAlbum(context, multi: true);
    var success = 0;
    var failed = 0;
    for (final code in codes) {
      final result = await _importQuick(code);
      result.success ? success++ : failed++;
      if (result.duplicate && mounted) {
        await _showDuplicateWarning(
          context,
          code: code,
          message: result.message,
        );
        if (!mounted) return;
      }
      if (_target?.isFull == true) break;
    }
    if (mounted && codes.isNotEmpty) {
      setState(() {
        _fastStatus =
            'Album • Thành công $success • Lỗi $failed'
            '${_target?.isFull == true ? ' • $term đã đầy' : ''}';
        _fastStatusOk = failed == 0;
      });
    }
    _keepManualFocus();
  }

  Future<void> _openLocation(LocationSummary location) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LocationDetailPage(
          api: widget.api,
          location: location.id,
        ),
      ),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final target = _target;
    final canScan = target != null && !target.isFull;
    final term = warehouseCellTerm(widget.api.warehouseId);
    return Scaffold(
      appBar: AppBar(
        title: const Text('NHẬP PIN'),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PendingTransfersPage(
                    inbound: true,
                    api: widget.api,
                    selectAllInitially: true,
                  ),
                ),
              );
              if (mounted) _refresh();
            },
            icon: const Icon(Icons.task_alt, size: 18),
            label: const Text('XÁC NHẬN'),
          ),
          IconButton(
            tooltip: 'Làm mới',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
          children: [
            ValueListenableBuilder<LocalSyncState>(
              valueListenable: LocalWarehouseStore.instance.syncState,
              builder: (_, state, _) => _SyncStatusCard(
                state: state,
                onRetry: () => widget.api.syncNow(bypassThrottle: true, reason: 'manual'),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _selectTarget,
              icon: const Icon(Icons.my_location),
              label: Text(
                target == null ? 'CHỌN ${term.toUpperCase()} NHẬP' : 'ĐỔI ${term.toUpperCase()} NHẬP',
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: target == null
                    ? Colors.orange.withValues(alpha: 0.08)
                    : Colors.blue.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: target == null
                      ? Colors.orange.withValues(alpha: 0.35)
                      : Colors.blue.withValues(alpha: 0.35),
                ),
              ),
              child: target == null
                  ? Text(
                      'CHƯA CHỌN ${term.toUpperCase()} • Không thể bắn nhập',
                      style: const TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.w900,
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          target.label,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 12.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Trong $term: ${target.occupied}/${target.slotCapacity} • '
                          'Còn ${max(0, target.slotCapacity - target.occupied)}',
                          style: TextStyle(
                            color: target.isFull
                                ? Colors.red.shade700
                                : Colors.green.shade800,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _pinType,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Loại pin (chọn / tự nhập)',
                hintText: 'Ví dụ: LFP, NMC, 72V...',
                prefixIcon: const Icon(Icons.battery_6_bar_outlined),
                suffixIcon: _pinTypeSuggestions.isEmpty
                    ? null
                    : PopupMenuButton<String>(
                        tooltip: 'Chọn loại pin đã dùng',
                        icon: const Icon(Icons.arrow_drop_down),
                        onSelected: (value) {
                          _pinType.text = value;
                          _pinType.selection = TextSelection.collapsed(offset: value.length);
                          _keepManualFocus();
                        },
                        itemBuilder: (_) => _pinTypeSuggestions
                            .map((value) => PopupMenuItem<String>(
                                  value: value,
                                  child: Text(value),
                                ))
                            .toList(),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            _ScannerTextField(
              controller: _manual,
              focusNode: _manualFocus,
              enabled: canScan,
              onSubmitted: _manualSubmit,
              decoration: InputDecoration(
                labelText: canScan
                    ? 'Nhập / bắn mã pin'
                    : 'Chọn $term trước để mở nhập',
                hintText: canScan ? 'Bắn mã rồi Enter' : null,
                prefixIcon: const Icon(Icons.keyboard),
                suffixIcon: IconButton(
                  tooltip: 'Nhập ngay',
                  onPressed: canScan ? () => _manualSubmit(_manual.text) : null,
                  icon: const Icon(Icons.arrow_forward_rounded),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: (_fastStatusOk ? Colors.green : Colors.red)
                    .withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _fastStatus,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _fastStatusOk
                      ? Colors.green.shade800
                      : Colors.red.shade800,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (_recentScans.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                _recentScans.first,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9.5, color: Colors.black54),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canScan ? _continuousCamera : null,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('QUÉT LIÊN TỤC'),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canScan ? _genericAlbum : null,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('ALBUM'),
                  ),
                ),
              ],
            ),
            if (_loading) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              _NoticeCard(
                message: _error!,
                color: Colors.red,
                icon: Icons.error_outline,
              ),
            ],
            const SizedBox(height: 14),
            const Text(
              'VỊ TRÍ DÃY',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _locations.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
                childAspectRatio: 2.05,
              ),
              itemBuilder: (_, index) {
                final location = _locations[index];
                return _LocationListCard(
                  location: location,
                  onTap: () => _openLocation(location),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _CellPickerDialog extends StatefulWidget {
  const _CellPickerDialog({
    required this.api,
    required this.locations,
    this.initial,
  });

  final WarehouseApi api;
  final List<LocationSummary> locations;
  final InboundTarget? initial;

  @override
  State<_CellPickerDialog> createState() => _CellPickerDialogState();
}

class _CellPickerDialogState extends State<_CellPickerDialog> {
  String? _location;
  int _aisle = 1;
  int _row = 1;
  int _cell = 1;
  LocationDetail? _detail;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _location = widget.initial?.location ??
        (widget.locations.isEmpty ? null : widget.locations.first.id);
    _aisle = widget.initial?.aisle ?? 1;
    _row = widget.initial?.row ?? 1;
    _cell = widget.initial?.cell ?? 1;
    _load();
  }

  Future<void> _load() async {
    final location = _location;
    if (location == null) return;
    setState(() => _loading = true);
    try {
      final detail = await widget.api.getLocation(location);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _occupied => _detail?.cellOccupied(_aisle, _row, _cell) ?? 0;
  int get _flatCell => _flatCellNumber(_row, _cell);

  @override
  Widget build(BuildContext context) {
    final labels = _detail?.labels;
    final term =
        labels?.cellTerm ?? warehouseCellTerm(widget.api.warehouseId);
    final slotCapacity = labels?.slotsPerCell ?? kPinsPerCell;
    return AlertDialog(
      title: Text('CHỌN ${term.toUpperCase()} NHẬP'),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                key: ValueKey('pick-location-${_location ?? ''}'),
                initialValue: _location,
                decoration: const InputDecoration(labelText: 'Dãy số'),
                items: widget.locations
                    .map(
                      (e) => DropdownMenuItem(
                        value: e.id,
                        child: Text(
                          'Dãy số ${_displayShelf(e.id)} • ${e.occupied} PIN',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _location = value;
                    _aisle = 1;
                    _row = 1;
                    _cell = 1;
                  });
                  _load();
                },
              ),
              const SizedBox(height: 10),
              if (_loading)
                const LinearProgressIndicator()
              else ...[
                DropdownButtonFormField<int>(
                  key: ValueKey('pick-aisle-$_location-$_aisle'),
                  initialValue: _aisle,
                  decoration: const InputDecoration(labelText: 'Kệ'),
                  items: List.generate(
                    labels?.aisleCount ?? kAislesPerShelf,
                    (i) {
                      final n = i + 1;
                      return DropdownMenuItem(
                        value: n,
                        child: Text(labels?.aisleName(n) ?? 'Kệ $n'),
                      );
                    },
                  ),
                  onChanged: (value) => setState(() {
                    _aisle = value ?? 1;
                    _row = 1;
                    _cell = 1;
                  }),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  key: ValueKey(
                    'pick-flat-cell-$_location-$_aisle-$_flatCell',
                  ),
                  initialValue: _flatCell,
                  decoration: InputDecoration(
                    labelText: term,
                  ),
                  items: List.generate(
                    (labels?.cellCount ?? (kRowsPerAisle * kCellsPerRow)),
                    (i) {
                      final flat = i + 1;
                      final r = _rowFromFlatCell(flat);
                      final c = _innerCellFromFlatCell(flat);
                      final count =
                          _detail?.cellOccupied(_aisle, r, c) ?? 0;
                      return DropdownMenuItem(
                        value: flat,
                        child: Text(
                          '${labels?.cellName(_aisle, r, c) ?? '$term $flat'} '
                          '• $count/$slotCapacity',
                        ),
                      );
                    },
                  ),
                  onChanged: (value) => setState(() {
                    final flat = value ?? 1;
                    _row = _rowFromFlatCell(flat);
                    _cell = _innerCellFromFlatCell(flat);
                  }),
                ),
                const SizedBox(height: 10),
                Text(
                  _occupied >= slotCapacity
                      ? '$term này đã đầy $slotCapacity/$slotCapacity. '
                          'Chọn $term khác.'
                      : '$term đang có $_occupied/$slotCapacity • '
                          'còn ${slotCapacity - _occupied}',
                  style: TextStyle(
                    color: _occupied >= slotCapacity
                        ? Colors.red.shade700
                        : Colors.green.shade800,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('HỦY'),
        ),
        FilledButton(
          onPressed: _loading ||
                  _location == null ||
                  _occupied >= slotCapacity
              ? null
              : () => Navigator.pop(
                    context,
                    InboundTarget(
                      location: _location!,
                      aisle: _aisle,
                      row: _row,
                      cell: _cell,
                      aisleName:
                          labels?.aisleName(_aisle) ?? 'Kệ $_aisle',
                      rowName: '',
                      cellName: labels?.cellName(_aisle, _row, _cell) ??
                          '$term $_flatCell',
                      occupied: _occupied,
                      slotCapacity: slotCapacity,
                    ),
                  ),
          child: Text('CHỌN ${term.toUpperCase()} NÀY'),
        ),
      ],
    );
  }
}

class LocationsPage extends StatefulWidget {
  const LocationsPage({super.key, required this.api});
  final WarehouseApi api;

  @override
  State<LocationsPage> createState() => _LocationsPageState();
}

class _LocationsPageState extends State<LocationsPage> {
  List<LocationSummary> _locations = const [];
  bool _loading = true;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _refresh(silent: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false, bool force = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final rows = await widget.api.listLocations(force: force);
      if (!mounted) return;
      setState(() {
        _locations = rows;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!silent || _locations.isEmpty) setState(() => _error = e.toString());
    } finally {
      if (!silent && mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('VỊ TRÍ DÃY'),
        actions: [
          IconButton(onPressed: () => _refresh(force: true), icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: null,
      body: RefreshIndicator(
        onRefresh: () => _refresh(force: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          children: [
            const _NoticeCard(
              message:
                  'Android chỉ xem cấu trúc vị trí và PIN. Thêm/Xóa/đổi tên Dãy, sửa số Kệ/Ô/Vị trí/Slot thực hiện trên N07 HUBDNI PC.',
              color: Colors.blue,
              icon: Icons.grid_view,
            ),
            if (_loading) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              _NoticeCard(
                message: _error!,
                color: Colors.red,
                icon: Icons.error_outline,
              ),
            ],
            const SizedBox(height: 10),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _locations.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
                childAspectRatio: 2.05,
              ),
              itemBuilder: (_, index) {
                final location = _locations[index];
                return _LocationListCard(
                  location: location,
                  onDelete: null,
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LocationDetailPage(
                          api: widget.api,
                          location: location.id,
                        ),
                      ),
                    );
                    _refresh(force: true);
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationListCard extends StatelessWidget {
  const _LocationListCard({
    required this.location,
    required this.onTap,
    this.onDelete,
  });

  final LocationSummary location;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final MaterialColor color = location.isFull
        ? Colors.red
        : location.empty <= 3
            ? Colors.orange
            : Colors.green;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  _displayShelf(location.id),
                  style: TextStyle(
                    color: color.shade700,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Dãy số ${_displayShelf(location.id)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${location.occupied}/${location.capacity} • '
                      'trống ${location.empty}',
                      style: TextStyle(
                        color: color.shade700,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              if (onDelete != null) ...[
                const SizedBox(width: 2),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    tooltip: location.occupied == 0
                        ? 'Xóa Dãy'
                        : 'Dãy đang có pin',
                    onPressed: onDelete,
                    icon: Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: location.occupied == 0
                          ? Colors.red.shade600
                          : Colors.grey.shade400,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class LocationDetailPage extends StatefulWidget {
  const LocationDetailPage({
    super.key,
    required this.api,
    required this.location,
  });

  final WarehouseApi api;
  final String location;

  @override
  State<LocationDetailPage> createState() => _LocationDetailPageState();
}

class _LocationDetailPageState extends State<LocationDetailPage> {
  LocationDetail? _detail;
  bool _loading = true;
  bool _syncingStatus = false;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _refresh(silent: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final detail = await widget.api.getLocation(widget.location);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!silent || _detail == null) setState(() => _error = e.toString());
    } finally {
      if (!silent && mounted) setState(() => _loading = false);
    }
  }

  Future<void> _syncStatus() async {
    if (_syncingStatus) return;
    setState(() => _syncingStatus = true);
    try {
      await widget.api.syncNow(bypassThrottle: true, reason: 'manual');
      await _refresh();
      if (!mounted) return;
      final state = LocalWarehouseStore.instance.syncState.value;
      _snack(
        context,
        state.message.isNotEmpty
            ? state.message
            : 'Đã cập nhật trạng thái đồng bộ.',
        error: !state.online || state.message.startsWith('LỖI'),
      );
    } catch (e) {
      if (mounted) {
        _snack(context, 'Không cập nhật được trạng thái: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _syncingStatus = false);
    }
  }

  Future<void> _openCell(
    int aisle,
    int row,
    int cell,
  ) async {
    final detail = _detail;
    if (detail == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CellDetailPage(
          api: widget.api,
          location: widget.location,
          aisle: aisle,
          row: row,
          cell: cell,
        ),
      ),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(
        title: Text(detail?.labels.shelfName(widget.location) ??
            'Dãy số ${_displayShelf(widget.location)}'),
        actions: [
          IconButton(
            tooltip: 'Cập nhật trạng thái / đồng bộ',
            onPressed: _syncingStatus ? null : _syncStatus,
            icon: _syncingStatus
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
          ),
        ],
      ),
      body: _loading && detail == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null && detail == null
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: _NoticeCard(
                    message: _error!,
                    color: Colors.red,
                    icon: Icons.error_outline,
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 28),
                  children: [
                    _NoticeCard(
                      message: widget.api.warehouseId == kWarehouseAuto
                          ? 'Chế độ chỉ xem • Ô tô dùng Vị trí 1–6/Kệ theo cấu hình trên PC.'
                          : 'Chế độ chỉ xem • Xe máy điện cố định 4 Ô/Kệ.',
                      color: Colors.blue,
                      icon: Icons.visibility_outlined,
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${detail!.occupied} / ${detail.labels.capacity} PIN',
                              style: const TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w900,
                              ),
                            ),

                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...List.generate(detail.labels.aisleCount, (aisleIndex) {
                      final aisle = aisleIndex + 1;
                      final aisleSlots =
                          detail.slots.where((e) => e.aisle == aisle);
                      final aisleOccupied =
                          aisleSlots.where((e) => !e.isEmpty).length;
                      final aisleCapacity =
                          detail.labels.cellCount * detail.labels.slotsPerCell;
                      final aisleName = detail.labels.aisleName(aisle);
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        clipBehavior: Clip.antiAlias,
                        child: ExpansionTile(
                          initiallyExpanded: aisle == 1,
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  aisleName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              Text(
                                '$aisleOccupied/$aisleCapacity',
                                style: const TextStyle(
                                  color: Colors.black54,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                          childrenPadding:
                              const EdgeInsets.fromLTRB(8, 0, 8, 8),
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                              child: GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: detail.labels.cellCount,
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount:
                                      widget.api.warehouseId == kWarehouseAuto
                                          ? 3
                                          : 4,
                                  crossAxisSpacing: 5,
                                  mainAxisSpacing: 5,
                                  childAspectRatio: 1.25,
                                ),
                                itemBuilder: (_, flatIndex) {
                                  final flatCell = flatIndex + 1;
                                  final row = _rowFromFlatCell(flatCell);
                                  final cell =
                                      _innerCellFromFlatCell(flatCell);
                                  final cellName = detail.labels
                                      .cellName(aisle, row, cell);
                                  final occupied = detail.cellOccupied(
                                    aisle,
                                    row,
                                    cell,
                                  );
                                  return _RackCellCard(
                                    label: cellName,
                                    occupied: occupied,
                                    capacity: detail.labels.slotsPerCell,
                                    onTap: () =>
                                        _openCell(aisle, row, cell),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
    );
  }
}

class _RackCellCard extends StatelessWidget {
  const _RackCellCard({
    required this.label,
    required this.occupied,
    required this.capacity,
    required this.onTap,
  });

  final String label;
  final int occupied;
  final int capacity;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final full = occupied >= capacity;
    return Material(
      color: full
          ? Colors.red.withValues(alpha: 0.07)
          : Colors.green.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(5, 4, 2, 5),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                '$occupied/$capacity',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: full ? Colors.red.shade700 : Colors.green.shade800,
                ),
              ),
              Text(
                full ? 'ĐẦY' : 'Còn ${capacity - occupied}',
                style: const TextStyle(
                  fontSize: 8,
                  color: Colors.black54,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CellDetailPage extends StatefulWidget {
  const CellDetailPage({
    super.key,
    required this.api,
    required this.location,
    required this.aisle,
    required this.row,
    required this.cell,
  });

  final WarehouseApi api;
  final String location;
  final int aisle;
  final int row;
  final int cell;

  @override
  State<CellDetailPage> createState() => _CellDetailPageState();
}

class _CellDetailPageState extends State<CellDetailPage> {
  final _manual = TextEditingController();
  final _manualFocus = FocusNode();
  LocationDetail? _detail;
  String _status = 'Sẵn sàng bắn vào vị trí đã chọn';
  bool _statusOk = true;
  bool _loading = true;
  bool _queueBusy = false;
  String? _loadError;
  final Set<int> _selectedSlots = <int>{};
  Map<int, String> _pendingInboundOpBySlot = <int, String>{};
  List<String> _pendingCellOpIds = const [];
  int? _preferredEmptySlot;
  int? _revealedDeleteSlot;
  final Map<int, GlobalKey> _slotKeys = <int, GlobalKey>{};

  GlobalKey _slotKey(int slot) =>
      _slotKeys.putIfAbsent(slot, () => GlobalKey());

  void _scrollToSlot(int slot) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetContext = _slotKeys[slot]?.currentContext;
      if (targetContext == null) return;
      // Mã vừa bắn phải nằm gần đầu viewport để người vận hành nhìn thấy
      // ngay và tiếp tục bắn theo luồng từ trên xuống. Không kéo mã mới
      // xuống gần đáy màn hình như các bản 16.0.3/16.0.4.
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        alignment: 0.08,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _manual.dispose();
    _manualFocus.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final detail = await widget.api.getLocation(widget.location);
      final pendingGroups = await Future.wait([
        LocalWarehouseStore.instance.listPendingTransfers(
          inbound: true,
        ),
        LocalWarehouseStore.instance.listPendingTransfers(
          inbound: false,
        ),
      ]);
      final pending = <Map<String, dynamic>>[
        ...pendingGroups[0],
        ...pendingGroups[1],
      ];

      final pendingBySlot = <int, String>{};
      final pendingCellOpIds = <String>[];
      final slotCapacity = detail.labels.slotsPerCell;
      final validCellSlots = <int>{
        for (var pinNo = 1; pinNo <= slotCapacity; pinNo++)
          _slotFromParts(
            widget.aisle,
            widget.row,
            widget.cell,
            pinNo,
          ),
      };

      for (final item in pending) {
        if ('${item['location'] ?? ''}' != widget.location) continue;
        final slot = _asInt(item['slot']);
        final opId = '${item['opId'] ?? ''}'.trim();
        final action = '${item['action'] ?? ''}';
        if (opId.isEmpty || !validCellSlots.contains(slot)) continue;

        pendingCellOpIds.add(opId);
        if (action == 'importPinToCell' ||
            action == 'importPinAtSlot') {
          pendingBySlot[slot] = opId;
        }
      }

      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loadError = null;
        _pendingInboundOpBySlot = pendingBySlot;
        _pendingCellOpIds = pendingCellOpIds;
        final occupiedSlotIds = detail
            .cellSlots(widget.aisle, widget.row, widget.cell)
            .where((item) => !item.isEmpty)
            .map((item) => item.slot)
            .toSet();
        _selectedSlots.removeWhere(
          (slot) => !occupiedSlotIds.contains(slot),
        );

        if (_preferredEmptySlot != null &&
            (!validCellSlots.contains(_preferredEmptySlot) ||
                occupiedSlotIds.contains(_preferredEmptySlot))) {
          _preferredEmptySlot = null;
        }

        if (_revealedDeleteSlot != null &&
            !detail.slots.any(
              (s) => s.slot == _revealedDeleteSlot && !s.isEmpty,
            )) {
          _revealedDeleteSlot = null;
        }
        _loading = false;
      });
      _keepFocus();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = e.toString();
          _status = e.toString();
          _statusOk = false;
          _loading = false;
        });
      }
    }
  }

  List<SlotInfo> get _cellSlots =>
      _detail?.cellSlots(widget.aisle, widget.row, widget.cell) ?? const [];

  int get _occupied => _cellSlots.where((e) => !e.isEmpty).length;
  int get _slotCapacity => _detail?.labels.slotsPerCell ?? kPinsPerCell;
  bool get _full => _occupied >= _slotCapacity;

  Set<int> get _occupiedSlotIds => _cellSlots
      .where((item) => !item.isEmpty)
      .map((item) => item.slot)
      .toSet();

  List<SlotInfo> get _selectedPins => _cellSlots
      .where(
        (item) =>
            !item.isEmpty && _selectedSlots.contains(item.slot),
      )
      .toList();

  bool get _allOccupiedSelected {
    final occupied = _occupiedSlotIds;
    return occupied.isNotEmpty &&
        _selectedSlots.length == occupied.length &&
        _selectedSlots.containsAll(occupied);
  }

  void _toggleSelectAllOccupied() {
    final occupied = _occupiedSlotIds;
    setState(() {
      if (_allOccupiedSelected) {
        _selectedSlots.clear();
      } else {
        _selectedSlots
          ..clear()
          ..addAll(occupied);
      }
    });
  }

  void _toggleSlotSelection(int slot, bool selected) {
    if (!_occupiedSlotIds.contains(slot)) return;
    setState(() {
      if (selected) {
        _selectedSlots.add(slot);
      } else {
        _selectedSlots.remove(slot);
      }
    });
  }

  Future<void> _uploadCellPending() async {
    final ids = List<String>.from(_pendingCellOpIds);
    if (_queueBusy || ids.isEmpty) return;

    setState(() => _queueBusy = true);
    try {
      final result = await widget.api.uploadPendingTransfers(ids);
      if (!mounted) return;

      final uploaded = _asInt(result['uploaded']);
      final failed = _asInt(result['failed']);
      final blocked =
          (result['blocked'] as List<dynamic>? ?? const []).length;
      final fatalCode = '${result['fatalCode'] ?? ''}'.trim();

      setState(() {
        _status = fatalCode.isEmpty && failed == 0 && blocked == 0
            ? 'Đã tải $uploaded thao tác của vị trí lên hệ thống.'
            : 'Đã tải $uploaded • còn lỗi'
                '${fatalCode.isNotEmpty ? ' [$fatalCode]' : ''}.';
        _statusOk =
            fatalCode.isEmpty && failed == 0 && blocked == 0;
        if (_statusOk) {
          _selectedSlots.clear();
        }
      });
      await _refresh();
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Tải lên thất bại: $e';
          _statusOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _queueBusy = false);
    }
  }

  Future<bool> _deletePinCore(SlotInfo slot) async {
    if (slot.isEmpty) return false;

    final pendingOpId = _pendingInboundOpBySlot[slot.slot];
    if (pendingOpId != null) {
      final result =
          await LocalWarehouseStore.instance.cancelPendingTransfers(
        [pendingOpId],
      );
      return _asInt(result['deleted']) > 0;
    }

    final outcome =
        await widget.api.exportSlot(widget.location, slot.slot);
    return outcome.type == OutcomeType.success;
  }

  Future<void> _deleteSelectedPins() async {
    final pins = List<SlotInfo>.from(_selectedPins);
    if (_queueBusy || pins.isEmpty) return;

    final pendingCount = pins
        .where(
          (slot) => _pendingInboundOpBySlot.containsKey(slot.slot),
        )
        .length;
    final syncedCount = pins.length - pendingCount;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text('XÓA ${pins.length} PIN ĐÃ CHỌN?'),
        content: Text(
          '• $pendingCount pin chưa xác nhận: hủy NHẬP chờ.\n'
          '• $syncedCount pin đã đồng bộ: tạo XUẤT chờ xác nhận.\n\n'
          'Dữ liệu sẽ được cập nhật trên máy ngay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('HỦY'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.delete_forever),
            label: const Text('XÓA TẤT CẢ ĐÃ CHỌN'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _queueBusy = true);
    var deleted = 0;
    final failedCodes = <String>[];

    try {
      for (final slot in pins) {
        try {
          final success = await _deletePinCore(slot);
          if (success) {
            deleted++;
          } else {
            failedCodes.add(slot.pinCode ?? 'Slot ${slot.slot}');
          }
        } catch (_) {
          failedCodes.add(slot.pinCode ?? 'Slot ${slot.slot}');
        }
      }

      if (!mounted) return;
      setState(() {
        _selectedSlots.clear();
        _revealedDeleteSlot = null;
        _status = failedCodes.isEmpty
            ? syncedCount > 0
                ? 'Đã xóa $deleted/${pins.length} pin • bấm ☁ để tải XUẤT.'
                : 'Đã xóa $deleted/${pins.length} pin.'
            : 'Đã xóa $deleted/${pins.length} • '
                '${failedCodes.length} pin lỗi.';
        _statusOk = failedCodes.isEmpty;
      });
      await _refresh();
    } finally {
      if (mounted) setState(() => _queueBusy = false);
    }
  }

  Future<void> _deletePinFromSlot(SlotInfo slot) async {
    if (slot.isEmpty || _queueBusy) return;

    final pending =
        _pendingInboundOpBySlot.containsKey(slot.slot);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('XÓA PIN?'),
        content: Text(
          pending
              ? 'Pin ${slot.pinCode} chưa xác nhận gửi Server. '
                  'Xóa sẽ hủy thao tác NHẬP đang chờ.'
              : 'Xóa pin ${slot.pinCode} khỏi '
                  '${_rackPositionLabel(widget.location, slot.slot, warehouseId: widget.api.warehouseId)}? '
                  'Pin sẽ được tạo thành XUẤT chờ xác nhận.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('HỦY'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.delete_forever),
            label: const Text('XÓA PIN'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _queueBusy = true);
    try {
      final success = await _deletePinCore(slot);
      if (!mounted) return;
      setState(() {
        _selectedSlots.remove(slot.slot);
        _revealedDeleteSlot = null;
        _status = success
            ? pending
                ? 'Đã xóa pin chưa xác nhận.'
                : 'Đã xóa pin • bấm ☁ để tải XUẤT lên hệ thống'
            : 'Không xóa được pin.';
        _statusOk = success;
      });
      await _refresh();
    } finally {
      if (mounted) setState(() => _queueBusy = false);
    }
  }

  void _keepFocus() {
    if (!mounted || _full) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_full) _focusScannerInput(_manualFocus);
    });
  }

  Future<ContinuousScanFeedback> _process(String raw) async {
    final code = raw.trim();
    if (code.isEmpty) {
      return const ContinuousScanFeedback(false, 'Mã trống.');
    }

    unawaited(_vibrateScan());

    if (_full) {
      return ContinuousScanFeedback(
        false,
        '${warehouseCellTerm(widget.api.warehouseId)} đã đầy '
        '$_slotCapacity/$_slotCapacity.',
      );
    }

    final preferredSlot = _preferredEmptySlot;

    if (preferredSlot != null) {
      final belongsToCell = <int>{
        for (var pinNo = 1; pinNo <= kPinsPerCell; pinNo++)
          _slotFromParts(
            widget.aisle,
            widget.row,
            widget.cell,
            pinNo,
          ),
      }.contains(preferredSlot);

      final occupiedNow = _cellSlots.any(
        (slot) => slot.slot == preferredSlot && !slot.isEmpty,
      );

      if (!belongsToCell || occupiedNow) {
        if (mounted) {
          setState(() {
            _preferredEmptySlot = null;
            _status =
                'Slot đã chọn không còn trống. Hãy chọn lại Slot muốn nhập.';
            _statusOk = false;
          });
        }

        return const ContinuousScanFeedback(
          false,
          'Slot đã chọn không còn trống. Hãy chọn lại.',
        );
      }
    }

    final outcome = preferredSlot != null
        ? await widget.api.importPin(
            widget.location,
            code,
            exactSlot: preferredSlot,
          )
        : await widget.api.importPinToCell(
            widget.location,
            widget.aisle,
            widget.row,
            widget.cell,
            code,
          );

    // Cập nhật UI ngay từ kết quả SQLite local, không reload cả Kệ sau mỗi lần bắn.
    if (mounted &&
        outcome.type == OutcomeType.success &&
        outcome.slot != null &&
        _detail != null) {
      final current = _detail!;
      final slots = List<SlotInfo>.from(current.slots);
      final index = slots.indexWhere((item) => item.slot == outcome.slot);

      if (index >= 0 && index < slots.length) {
        slots[index] = SlotInfo(
          slot: outcome.slot!,
          pinCode: code,
          storedAt: DateTime.now().toIso8601String(),
        );

        setState(() {
          // Chọn Slot chỉ áp dụng cho đúng mã pin kế tiếp.
          _preferredEmptySlot = null;
          _detail = LocationDetail(
            location: current.location,
            occupied: min(current.labels.capacity, current.occupied + 1),
            slots: slots,
            labels: current.labels,
          );
        });

        _scrollToSlot(outcome.slot!);
        unawaited(_refresh());
      }
    }

    return ContinuousScanFeedback(
      outcome.type == OutcomeType.success,
      outcome.message,
      duplicate: outcome.type == OutcomeType.duplicate,
    );
  }

  Future<void> _submit(String value) async {
    final code = value.trim();
    if (code.isEmpty) {
      _keepFocus();
      return;
    }
    _manual.clear();
    _focusScannerInput(_manualFocus);
    final result = await _process(code);
    if (!mounted) return;
    setState(() {
      _status = result.message;
      _statusOk = result.success;
    });

    if (result.duplicate) {
      await _showDuplicateWarning(
        context,
        code: code,
        message: result.message,
      );
      if (!mounted) return;
    }

    _keepFocus();
  }

  Future<void> _camera() async {
    if (_full) return;
    final fallbackCellName =
        '${warehouseCellTerm(widget.api.warehouseId)} ${widget.cell}';
    final cellName = _detail?.labels.cellName(
          widget.aisle,
          widget.row,
          widget.cell,
        ) ??
        fallbackCellName;
    await _scanContinuous(
      context,
      title: 'NHẬP • $cellName',
      onCode: _process,
    );
    _refresh();
  }

  Future<void> _album() async {
    if (_full) return;
    final codes = await _pickQrCodesFromAlbum(context, multi: true);
    for (final code in codes) {
      final result = await _process(code);
      if (result.duplicate && mounted) {
        await _showDuplicateWarning(
          context,
          code: code,
          message: result.message,
        );
        if (!mounted) return;
      }
      if (!result.success || _full) break;
    }
    _keepFocus();
  }

  Future<void> _pinTap(SlotInfo slot) async {
    if (slot.isEmpty) {
      final sameSlot = _preferredEmptySlot == slot.slot;
      final slotText =
          slot.pinInCell.toString().padLeft(2, '0');

      setState(() {
        if (sameSlot) {
          _preferredEmptySlot = null;
          _status =
              'Đã bỏ chọn Slot $slotText. Mã tiếp theo sẽ tự vào Slot trống đầu tiên.';
        } else {
          _preferredEmptySlot = slot.slot;
          _status =
              'ĐÃ CHỌN SLOT $slotText • Bắn mã pin, pin sẽ vào đúng Slot này.';
        }
        _statusOk = true;
      });

      _keepFocus();
      return;
    }

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                _rackPositionLabel(
                  widget.location,
                  slot.slot,
                  warehouseId: widget.api.warehouseId,
                ),
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: SelectableText(slot.pinCode!),
            ),
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('Thay bằng pin khác'),
              onTap: () => Navigator.pop(context, 'replace'),
            ),
            ListTile(
              leading: const Icon(Icons.upload, color: Colors.orange),
              title: const Text('Xuất pin'),
              onTap: () => Navigator.pop(context, 'export'),
            ),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;
    if (action == 'replace') {
      final code = await _scanOneQr(context);
      if (code == null) return;
      final outcome =
          await widget.api.replacePin(widget.location, slot.slot, code);
      if (mounted) {
        setState(() {
          _status = outcome.message;
          _statusOk = outcome.type == OutcomeType.success;
        });
        _refresh();
      }
    } else if (action == 'export') {
      final outcome = await widget.api.exportSlot(widget.location, slot.slot);
      if (mounted) {
        setState(() {
          _status = outcome.message;
          _statusOk = outcome.type == OutcomeType.success;
        });
        _refresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final labels = detail?.labels;
    final term = warehouseCellTerm(widget.api.warehouseId);
    final flatCell = _flatCellNumber(widget.row, widget.cell);
    final title =
        '${labels?.aisleName(widget.aisle) ?? 'Kệ ${widget.aisle}'} • '
        '${labels?.cellName(widget.aisle, widget.row, widget.cell) ?? '$term $flatCell'}';

    final byPin = {for (final slot in _cellSlots) slot.pinInCell: slot};
    // V10.2: hiển thị 18 vị trí pin theo dạng danh sách 01 -> 18.

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'DÃY SỐ ${_displayShelf(widget.location)} • $title',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          IconButton(
            tooltip: _allOccupiedSelected
                ? 'Bỏ chọn tất cả'
                : 'Chọn tất cả pin trong $term',
            visualDensity: VisualDensity.compact,
            onPressed: _queueBusy || _occupiedSlotIds.isEmpty
                ? null
                : _toggleSelectAllOccupied,
            icon: Icon(
              _allOccupiedSelected
                  ? Icons.check_box
                  : Icons.select_all,
            ),
          ),
          IconButton(
            tooltip: _pendingCellOpIds.isEmpty
                ? '$term này không có thao tác chờ xác nhận'
                : 'Tải ${_pendingCellOpIds.length} thao tác của $term lên hệ thống',
            visualDensity: VisualDensity.compact,
            onPressed: _queueBusy || _pendingCellOpIds.isEmpty
                ? null
                : _uploadCellPending,
            icon: Icon(
              Icons.cloud_upload_outlined,
              color: _pendingCellOpIds.isEmpty
                  ? null
                  : Colors.orange.shade700,
            ),
          ),
          IconButton(
            tooltip: 'Xóa tất cả pin đã chọn',
            visualDensity: VisualDensity.compact,
            onPressed: _queueBusy || _selectedPins.isEmpty
                ? null
                : _deleteSelectedPins,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_detail == null && _loadError != null)
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Colors.red,
                          size: 34,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'KHÔNG TẢI ĐƯỢC DỮ LIỆU ${term.toUpperCase()}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _loadError!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 11),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: _refresh,
                          icon: const Icon(Icons.refresh),
                          label: const Text('THỬ LẠI'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 28),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          '$_occupied/$_slotCapacity pin • ${_full ? 'ĐẦY' : 'Còn ${_slotCapacity - _occupied}'}',
                          style: TextStyle(
                            color: _full
                                ? Colors.red.shade700
                                : Colors.green.shade800,
                            fontWeight: FontWeight.w800,
                          ),
                        ),

                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                _ScannerTextField(
                  controller: _manual,
                  focusNode: _manualFocus,
                  enabled: !_full,
                  onSubmitted: _submit,
                  decoration: InputDecoration(
                    labelText: _full
                        ? '$term đã đầy'
                        : _preferredEmptySlot != null
                            ? 'Bắn mã vào Slot ${_pinInCell(_preferredEmptySlot!).toString().padLeft(2, '0')}'
                            : 'Nhập / bắn mã vào $term này',
                    prefixIcon: Icon(
                      _preferredEmptySlot != null
                          ? Icons.place_outlined
                          : Icons.keyboard,
                    ),
                    suffixIcon: IconButton(
                      onPressed: _full ? null : () => _submit(_manual.text),
                      icon: const Icon(Icons.arrow_forward),
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  _status,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _statusOk
                        ? Colors.green.shade800
                        : Colors.red.shade800,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _full ? null : _camera,
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('QUÉT LIÊN TỤC'),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _full ? null : _album,
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('ALBUM'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '$_slotCapacity SLOT TRONG ${term.toUpperCase()}',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 5),
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _slotCapacity,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (_, index) {
                    final pinNo = index + 1;
                    final slot = byPin[pinNo] ??
                        SlotInfo(
                          slot: _slotFromParts(
                            widget.aisle,
                            widget.row,
                            widget.cell,
                            pinNo,
                          ),
                        );
                    final empty = slot.isEmpty;

                    final pending =
                        _pendingInboundOpBySlot.containsKey(slot.slot);
                    final selected =
                        _selectedSlots.contains(slot.slot);
                    final preferred =
                        empty && _preferredEmptySlot == slot.slot;
                    final revealed =
                        _revealedDeleteSlot == slot.slot && !empty;

                    const slotRowHeight = 52.0;

                    Widget fixedCheckbox() {
                      return SizedBox(
                        width: 42,
                        height: slotRowHeight,
                        child: Center(
                          child: empty
                              ? Icon(
                                  preferred
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                                  color: preferred
                                      ? Colors.blue.shade700
                                      : Colors.green.shade500,
                                  size: 22,
                                )
                              : Checkbox(
                                  value: selected,
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  onChanged: !_queueBusy
                                      ? (value) => _toggleSlotSelection(
                                            slot.slot,
                                            value == true,
                                          )
                                      : null,
                                ),
                        ),
                      );
                    }

                    Widget slotBody({
                      required bool allowTap,
                    }) {
                      final tint = preferred
                          ? Colors.blue.withValues(alpha: 0.16)
                          : empty
                              ? Colors.green.withValues(alpha: 0.055)
                              : pending
                                  ? Colors.red.withValues(alpha: 0.055)
                                  : Colors.blue.withValues(alpha: 0.075);
                      final opaqueBackground = Color.alphaBlend(
                        tint,
                        Theme.of(context).colorScheme.surface,
                      );

                      final body = Material(
                        color: opaqueBackground,
                        child: SizedBox(
                          height: slotRowHeight,
                          child: Padding(
                            padding: const EdgeInsets.only(
                              left: 4,
                              right: 4,
                            ),
                            child: Row(
                              crossAxisAlignment:
                                  CrossAxisAlignment.center,
                              children: [
                                Text(
                                  'Slot ${pinNo.toString().padLeft(2, '0')}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 13,
                                  ),
                                ),
                                const Padding(
                                  padding:
                                      EdgeInsets.symmetric(horizontal: 6),
                                  child: Text(
                                    '-',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    empty
                                        ? preferred
                                            ? 'Trống • ĐÃ CHỌN'
                                            : 'Trống'
                                        : slot.pinCode!,
                                    softWrap: true,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: preferred
                                          ? Colors.blue.shade800
                                          : empty
                                              ? Colors.green.shade700
                                              : Colors.blue.shade800,
                                      fontSize: 12.2,
                                      fontWeight: empty
                                          ? FontWeight.w700
                                          : FontWeight.w800,
                                    ),
                                  ),
                                ),
                                if (pending)
                                  const Padding(
                                    padding: EdgeInsets.only(left: 3),
                                    child: Icon(
                                      Icons.cloud_upload_outlined,
                                      size: 15,
                                      color: Colors.orange,
                                    ),
                                  ),
                                const SizedBox(width: 3),
                                Icon(
                                  empty
                                      ? preferred
                                          ? Icons.check_circle
                                          : Icons.add_circle_outline
                                      : Icons.chevron_left,
                                  size: 18,
                                  color: preferred
                                      ? Colors.blue.shade700
                                      : empty
                                          ? Colors.green.shade500
                                          : Colors.blueGrey.shade500,
                                ),
                                const SizedBox(width: 5),
                              ],
                            ),
                          ),
                        ),
                      );

                      if (!allowTap) return body;
                      return InkWell(
                        onTap: () => _pinTap(slot),
                        child: body,
                      );
                    }

                    if (empty) {
                      return ClipRRect(
                        key: _slotKey(slot.slot),
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          height: slotRowHeight,
                          child: Row(
                            crossAxisAlignment:
                                CrossAxisAlignment.center,
                            children: [
                              fixedCheckbox(),
                              Expanded(
                                child: slotBody(allowTap: true),
                              ),
                            ],
                          ),
                        ),
                      );
                    }

                    return ClipRRect(
                      key: _slotKey(slot.slot),
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: slotRowHeight,
                        child: Row(
                          crossAxisAlignment:
                              CrossAxisAlignment.center,
                          children: [
                            // Checkbox luôn cố định bên trái.
                            fixedCheckbox(),
                            Expanded(
                              child: _SwipeDeleteSlotRow(
                                revealed: revealed,
                                busy: _queueBusy,
                                onRevealChanged: (value) {
                                  setState(() {
                                    _revealedDeleteSlot =
                                        value ? slot.slot : null;
                                  });
                                },
                                onDelete: () => _deletePinFromSlot(slot),
                                child: slotBody(allowTap: false),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
    );
  }
}


class _SwipeDeleteSlotRow extends StatefulWidget {
  const _SwipeDeleteSlotRow({
    required this.child,
    required this.revealed,
    required this.busy,
    required this.onRevealChanged,
    required this.onDelete,
  });

  final Widget child;
  final bool revealed;
  final bool busy;
  final ValueChanged<bool> onRevealChanged;
  final VoidCallback onDelete;

  @override
  State<_SwipeDeleteSlotRow> createState() =>
      _SwipeDeleteSlotRowState();
}

class _SwipeDeleteSlotRowState extends State<_SwipeDeleteSlotRow> {
  double _dragDx = 0;

  void _toggle() {
    if (widget.busy) return;
    widget.onRevealChanged(!widget.revealed);
  }

  void _onDragStart(DragStartDetails details) {
    _dragDx = 0;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _dragDx += details.delta.dx;
  }

  void _onDragEnd(DragEndDetails details) {
    if (widget.busy) return;

    final velocity = details.primaryVelocity ?? 0;
    if (_dragDx <= -18 || velocity <= -220) {
      widget.onRevealChanged(true);
    } else if (_dragDx >= 18 || velocity >= 220) {
      widget.onRevealChanged(false);
    }
    _dragDx = 0;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.busy ? null : _toggle,
            onHorizontalDragStart:
                widget.busy ? null : _onDragStart,
            onHorizontalDragUpdate:
                widget.busy ? null : _onDragUpdate,
            onHorizontalDragEnd:
                widget.busy ? null : _onDragEnd,
            child: widget.child,
          ),
        ),
        if (widget.revealed)
          SizedBox(
            width: 88,
            height: 52,
            child: Material(
              color: Colors.red.shade700,
              child: InkWell(
                onTap: widget.busy ? null : widget.onDelete,
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.delete_forever,
                      color: Colors.white,
                      size: 19,
                    ),
                    SizedBox(height: 1),
                    Text(
                      'Xóa pin',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}


class OutboundPage extends StatefulWidget {
  const OutboundPage({super.key, required this.api});
  final WarehouseApi api;

  @override
  State<OutboundPage> createState() => _OutboundPageState();
}

class _OutboundPageState extends State<OutboundPage> {
  final _manual = TextEditingController();
  final _manualFocus = FocusNode();
  final List<String> _recent = [];
  String _fastStatus = 'Sẵn sàng bắn mã xuất';
  bool _fastStatusOk = true;
  final bool _busy = false;
  Timer? _bannerTimer;
  String _bannerCode = '';
  String _bannerMessage = '';
  bool _bannerOk = true;
  int _exportScanSeq = 0;
  final ScanDuplicateTracker _exportedThisSession = ScanDuplicateTracker();
  final ScanDuplicateTracker _exportInFlight = ScanDuplicateTracker();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusScannerInput(_manualFocus);
    });
  }

  void _showExportBanner(String code, bool ok, String message) {
    _bannerTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _bannerCode = code;
      _bannerMessage = message;
      _bannerOk = ok;
    });
    _bannerTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _bannerCode = '';
        _bannerMessage = '';
      });
    });
  }

  Future<ContinuousScanFeedback> _processExport(String raw) async {
    final code = raw.trim();
    final scanSeq = ++_exportScanSeq;

    // Mã mới đến thì bỏ banner cũ ngay. Kết quả của mã cũ hoàn thành trễ
    // cũng không được ghi đè lên kết quả của mã mới hơn.
    _bannerTimer?.cancel();
    if (mounted && _bannerCode.isNotEmpty) {
      setState(() {
        _bannerCode = '';
        _bannerMessage = '';
      });
    }

    if (code.isEmpty) {
      const message = 'Mã trống.';
      if (mounted && scanSeq == _exportScanSeq) {
        _showExportBanner('-', false, message);
      }
      return const ContinuousScanFeedback(false, message);
    }

    unawaited(_vibrateScan());

    if (_exportedThisSession.contains(code) ||
        !_exportInFlight.markIfNew(code)) {
      const message = 'MÃ ĐÃ QUÉT XUẤT TRÙNG TRONG PHIÊN NÀY.';
      if (mounted && scanSeq == _exportScanSeq) {
        _showExportBanner(code, false, message);
      }
      return const ContinuousScanFeedback(
        false,
        message,
        duplicate: true,
      );
    }

    try {
      final outcome = await widget.api.exportPin(code);
      final ok = outcome.type == OutcomeType.success;
      if (ok) {
        _exportedThisSession.mark(code);
      }
      if (mounted) {
        if (scanSeq == _exportScanSeq) {
          _showExportBanner(code, ok, outcome.message);
        }
        setState(() {
          _recent.insert(0, '${ok ? '✓' : '✕'} $code • ${outcome.message}');
          if (_recent.length > 12) _recent.removeLast();
        });
      }
      return ContinuousScanFeedback(ok, outcome.message);
    } catch (e) {
      final message = e.toString();
      if (mounted) {
        if (scanSeq == _exportScanSeq) {
          _showExportBanner(code, false, message);
        }
        setState(() {
          _recent.insert(0, '✕ $code • $message');
          if (_recent.length > 12) _recent.removeLast();
        });
      }
      return ContinuousScanFeedback(false, message);
    } finally {
      _exportInFlight.unmark(code);
    }
  }

  void _keepManualFocus() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusScannerInput(_manualFocus);
    });
  }

  Future<void> _manualExport(String value) async {
    final code = value.trim();
    if (code.isEmpty) {
      _keepManualFocus();
      return;
    }

    _manual.clear();
    _focusScannerInput(_manualFocus);

    final result = await _processExport(code);
    if (!mounted) return;
    setState(() {
      _fastStatus = result.message;
      _fastStatusOk = result.success;
    });

    if (result.duplicate) {
      await _showDuplicateWarning(
        context,
        code: code,
        message: result.message,
      );
      if (!mounted) return;
    }

    _keepManualFocus();
  }

  Future<void> _scanCamera() async {
    await _scanContinuous(
      context,
      title: 'XUẤT PIN LIÊN TỤC',
      onCode: _processExport,
    );
    _keepManualFocus();
  }

  Future<void> _scanAlbum() async {
    final codes = await _pickQrCodesFromAlbum(context, multi: true);
    var success = 0;
    var failed = 0;
    for (final code in codes) {
      final result = await _processExport(code);
      if (result.success) {
        success++;
      } else {
        failed++;
      }
      if (result.duplicate && mounted) {
        await _showDuplicateWarning(
          context,
          code: code,
          message: result.message,
        );
        if (!mounted) return;
      }
    }
    if (mounted && codes.isNotEmpty) {
      setState(() {
        _fastStatus = 'Đã xử lý ${codes.length} mã • Chờ xác nhận $success • Lỗi $failed';
        _fastStatusOk = failed == 0;
      });
    }
    _keepManualFocus();
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _manual.dispose();
    _manualFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('XUẤT PIN'),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PendingTransfersPage(
                    inbound: false,
                    api: widget.api,
                    selectAllInitially: true,
                  ),
                ),
              );
            },
            icon: const Icon(Icons.task_alt, size: 18),
            label: const Text('XÁC NHẬN'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 120),
            child: _bannerCode.isEmpty
                ? const SizedBox.shrink()
                : Container(
                    key: ValueKey('$_bannerCode|$_bannerMessage'),
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: (_bannerOk ? Colors.green : Colors.red)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: (_bannerOk ? Colors.green : Colors.red)
                            .withValues(alpha: 0.55),
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _bannerOk
                              ? Icons.check_circle_rounded
                              : Icons.error_rounded,
                          color: _bannerOk
                              ? Colors.green.shade800
                              : Colors.red.shade800,
                          size: 29,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _bannerOk ? 'ĐÃ LƯU CHỜ XÁC NHẬN' : 'XUẤT THẤT BẠI',
                                style: TextStyle(
                                  color: _bannerOk
                                      ? Colors.green.shade900
                                      : Colors.red.shade900,
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _bannerCode,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              Text(
                                _bannerMessage,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          ValueListenableBuilder<LocalSyncState>(
            valueListenable: LocalWarehouseStore.instance.syncState,
            builder: (_, state, _) => _SyncStatusCard(
              state: state,
              onRetry: () => widget.api.syncNow(bypassThrottle: true, reason: 'manual'),
            ),
          ),
          const SizedBox(height: 8),
          _ScannerTextField(
            controller: _manual,
            focusNode: _manualFocus,
            onSubmitted: _manualExport,
            decoration: InputDecoration(
              labelText: 'Nhập / dán mã để xuất nhanh',
              hintText: 'Nhập mã rồi Enter',
              prefixIcon: const Icon(Icons.keyboard),
              suffixIcon: IconButton(
                onPressed: _busy ? null : () => _manualExport(_manual.text),
                icon: const Icon(Icons.upload_rounded),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: (_fastStatusOk ? Colors.green : Colors.red)
                  .withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _fastStatus,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _fastStatusOk
                    ? Colors.green.shade800
                    : Colors.red.shade800,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _scanCamera,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('QUÉT LIÊN TỤC'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _scanAlbum,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('ALBUM'),
                ),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
          if (_recent.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text(
              'VỪA XỬ LÝ',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 5),
            ..._recent.map((e) {
              final ok = e.startsWith('✓');
              final text = e.length > 2 ? e.substring(2) : e;
              final tone = ok ? Colors.green : Colors.red;
              return Container(
                margin: const EdgeInsets.only(bottom: 5),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: tone.withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      ok ? Icons.check_circle : Icons.error,
                      size: 18,
                      color: ok
                          ? Colors.green.shade800
                          : Colors.red.shade700,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}


class QrPairCheckPage extends StatefulWidget {
  const QrPairCheckPage({super.key});

  @override
  State<QrPairCheckPage> createState() => _QrPairCheckPageState();
}

class _QrPairCheckPageState extends State<QrPairCheckPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();

  final List<String> _scanQueue = <String>[];

  String _cartonQr = '';
  String _batteryQr = '';
  String _lastMatchedCartonQr = '';

  int _pairNumber = 1;
  int _lastMatchedPairNumber = 0;

  bool _cameraBusy = false;
  bool _drainingQueue = false;
  bool _mismatchDialogOpen = false;

  bool get _waitingCarton => _cartonQr.isEmpty;
  bool get _waitingBattery =>
      _cartonQr.isNotEmpty && _batteryQr.isEmpty;

  bool get _scannerEnabled =>
      !_cameraBusy && !_mismatchDialogOpen;

  String get _inputLabel => _waitingCarton
      ? 'Bắn QR NGOÀI THÙNG • Cặp $_pairNumber'
      : 'Bắn QR TRÊN PIN • Cặp $_pairNumber';

  String get _stepText => _waitingCarton
      ? 'CẶP $_pairNumber • QR NGOÀI THÙNG'
      : 'CẶP $_pairNumber • QR TRÊN PIN';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreScannerFocus();
    });
  }

  @override
  void dispose() {
    _scanQueue.clear();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _restoreScannerFocus() {
    if (!mounted || !_scannerEnabled) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scannerEnabled) return;
      _focusScannerInput(_focus);
    });
  }

  Future<void> _matchedFeedback() async {
    await _vibrateScan();
  }

  Future<void> _mismatchFeedback() async {
    await _vibrateScan();
    await Future<void>.delayed(
      const Duration(milliseconds: 120),
    );
    await _vibrateScan();
  }

  void _enqueueCode(String raw) {
    if (!_scannerEnabled) return;

    final code = normalizeQrForComparison(raw);
    _input.clear();

    if (code.isEmpty) {
      _restoreScannerFocus();
      return;
    }

    _scanQueue.add(code);
    unawaited(_drainScanQueue());
  }

  Future<void> _drainScanQueue() async {
    if (_drainingQueue) return;

    _drainingQueue = true;
    try {
      while (mounted &&
          _scanQueue.isNotEmpty &&
          !_mismatchDialogOpen) {
        final code = _scanQueue.removeAt(0);
        await _processCode(code);
      }
    } finally {
      _drainingQueue = false;
    }
  }

  Future<void> _processCode(String code) async {
    if (!mounted || _mismatchDialogOpen) return;

    if (_waitingCarton) {
      setState(() {
        _cartonQr = code;
        _batteryQr = '';
      });

      await _vibrateScan();
      _restoreScannerFocus();
      return;
    }

    if (!_waitingBattery) return;

    final cartonQr = _cartonQr;
    final batteryQr = code;
    final matched = qrCodesMatchExact(cartonQr, batteryQr);

    if (matched) {
      final completedPair = _pairNumber;

      // Reset IMMEDIATELY after a successful pair.
      // Any scan arriving while vibration runs is queued and becomes
      // the carton QR of the next pair instead of being dropped.
      setState(() {
        _lastMatchedPairNumber = completedPair;
        _lastMatchedCartonQr = cartonQr;

        _cartonQr = '';
        _batteryQr = '';
        _pairNumber = completedPair + 1;
      });

      await _matchedFeedback();
      _restoreScannerFocus();
      return;
    }

    // Mismatch is the only state that blocks continuous scanning.
    setState(() {
      _batteryQr = batteryQr;
      _mismatchDialogOpen = true;
    });

    // Drop anything accidentally scanned behind the warning.
    // The next QR is accepted only after the operator confirms.
    _scanQueue.clear();

    _focus.unfocus();
    await SystemChannels.textInput.invokeMethod<void>(
      'TextInput.hide',
    );
    await _mismatchFeedback();

    if (!mounted) return;
    await _showMismatchWarning(
      pairNumber: _pairNumber,
      cartonQr: cartonQr,
      batteryQr: batteryQr,
    );

    if (!mounted) return;

    setState(() {
      _cartonQr = '';
      _batteryQr = '';
      _mismatchDialogOpen = false;
      _pairNumber++;
    });

    _restoreScannerFocus();
  }

  Future<void> _showMismatchWarning({
    required int pairNumber,
    required String cartonQr,
    required String batteryQr,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          icon: const Icon(
            Icons.error_rounded,
            color: Colors.red,
            size: 48,
          ),
          title: Text(
            'CẢNH BÁO • CẶP $pairNumber KHÔNG KHỚP',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.red,
              fontWeight: FontWeight.w900,
            ),
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'QR NGOÀI THÙNG',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  SelectableText(
                    cartonQr,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'QR TRÊN PIN',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  SelectableText(
                    batteryQr,
                    style: const TextStyle(
                      color: Colors.red,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Hai mã khác nhau. Giữ riêng cục pin này để kiểm tra.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            FilledButton.icon(
              onPressed: () => Navigator.pop(dialogContext),
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('XÁC NHẬN'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _camera() async {
    if (!_scannerEnabled) return;

    setState(() => _cameraBusy = true);
    try {
      final code = await _scanOneQr(context);
      if (code != null && mounted) {
        _enqueueCode(code);
      }
    } catch (e) {
      if (mounted) {
        _snack(
          context,
          'Không quét được QR: $e',
          error: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _cameraBusy = false);
        _restoreScannerFocus();
      }
    }
  }

  Future<void> _album() async {
    if (!_scannerEnabled) return;

    setState(() => _cameraBusy = true);
    try {
      final codes = await _pickQrCodesFromAlbum(
        context,
        multi: false,
      );
      if (codes.isNotEmpty && mounted) {
        _enqueueCode(codes.first);
      }
    } catch (e) {
      if (mounted) {
        _snack(
          context,
          'Không đọc được QR từ ảnh: $e',
          error: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _cameraBusy = false);
        _restoreScannerFocus();
      }
    }
  }

  Widget _currentValueCard({
    required String title,
    required String value,
    required int step,
    required bool active,
  }) {
    final hasValue = value.isNotEmpty;

    return Card(
      margin: EdgeInsets.zero,
      color: active
          ? Colors.blue.withValues(alpha: 0.075)
          : hasValue
              ? Colors.green.withValues(alpha: 0.055)
              : Colors.black.withValues(alpha: 0.025),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Row(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: active
                  ? Colors.blue.shade700
                  : hasValue
                      ? Colors.green.shade700
                      : Colors.grey.shade400,
              foregroundColor: Colors.white,
              child: Text(
                '$step',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasValue
                        ? value
                        : active
                            ? 'Đang chờ quét...'
                            : 'Chưa quét',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: hasValue
                          ? Colors.black87
                          : active
                              ? Colors.blue.shade700
                              : Colors.black45,
                      fontSize: 11.2,
                      fontWeight: hasValue || active
                          ? FontWeight.w800
                          : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lastMatchCard() {
    if (_lastMatchedPairNumber <= 0) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: EdgeInsets.zero,
      color: Colors.green.withValues(alpha: 0.085),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
        child: Row(
          children: [
            Icon(
              Icons.check_circle_rounded,
              color: Colors.green.shade700,
              size: 24,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'CẶP $_lastMatchedPairNumber • KHỚP MÃ',
                    style: TextStyle(
                      color: Colors.green.shade800,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _lastMatchedCartonQr,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 9.8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ĐỐI CHIẾU QR THÙNG / PIN',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.qr_code_scanner,
                    size: 21,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      _stepText,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  if (_drainingQueue)
                    const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 7),
          _ScannerTextField(
            controller: _input,
            focusNode: _focus,
            enabled: _scannerEnabled,
            onSubmitted: _enqueueCode,
            decoration: InputDecoration(
              labelText: _inputLabel,
              prefixIcon: const Icon(Icons.qr_code_2),
            ),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed:
                      _scannerEnabled ? _camera : null,
                  icon: _cameraBusy
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.qr_code_scanner),
                  label: const Text('CAMERA'),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      _scannerEnabled ? _album : null,
                  icon: const Icon(
                    Icons.photo_library_outlined,
                  ),
                  label: const Text('ALBUM'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          _currentValueCard(
            title: 'QR NGOÀI THÙNG',
            value: _cartonQr,
            step: 1,
            active: _waitingCarton,
          ),
          const SizedBox(height: 5),
          _currentValueCard(
            title: 'QR TRÊN PIN',
            value: _batteryQr,
            step: 2,
            active: _waitingBattery,
          ),
          if (_lastMatchedPairNumber > 0) ...[
            const SizedBox(height: 8),
            _lastMatchCard(),
          ],
          const SizedBox(height: 9),
          const Text(
            'Quét liên tục: 1–2, 3–4, 5–6... '
            'Cặp khớp sẽ tự chuyển sang cặp kế tiếp. '
            'Chỉ khi không khớp mới dừng và yêu cầu XÁC NHẬN.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.black54,
              fontSize: 9.8,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.api,
    required this.canExportPin,
  });
  final WarehouseApi api;
  final bool canExportPin;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String get _historyKey =>
      'n07_search_pin_recent_v1_${widget.api.warehouseId}';

  final _text = TextEditingController();
  final _searchFocus = FocusNode();
  PinSearchResult? _result;
  bool _loading = false;
  bool _exporting = false;
  List<String> _recentSearches = const [];

  @override
  void initState() {
    super.initState();
    _loadRecentSearches();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keepSearchFocus(selectAll: false);
    });
  }

  Future<void> _loadRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    final rows = prefs.getStringList(_historyKey) ?? const <String>[];
    final clean = <String>[];
    for (final raw in rows) {
      final value = raw.trim();
      if (value.isEmpty || clean.contains(value)) continue;
      clean.add(value);
      if (clean.length >= 20) break;
    }
    if (!mounted) return;
    setState(() => _recentSearches = clean);
  }

  Future<void> _rememberSearch(String code) async {
    final value = code.trim();
    if (value.isEmpty) return;
    final next = <String>[
      value,
      ..._recentSearches.where((e) => e != value),
    ];
    if (next.length > 20) next.removeRange(20, next.length);

    if (mounted) {
      setState(() => _recentSearches = next);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_historyKey, next);
  }

  void _keepSearchFocus({bool selectAll = true}) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (selectAll && _text.text.isNotEmpty) {
        _text.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _text.text.length,
        );
      }
      _focusScannerInput(_searchFocus);
    });
  }

  Future<void> _search(String code) async {
    final value = code.trim();
    if (value.isEmpty) {
      _keepSearchFocus();
      return;
    }

    _text.text = value;
    setState(() => _loading = true);
    try {
      final result = await widget.api.searchPin(value);
      if (!mounted) return;
      setState(() => _result = result);
      unawaited(_rememberSearch(value));
    } catch (e) {
      if (mounted) _snack(context, e.toString(), error: true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _keepSearchFocus();
      }
    }
  }

  Future<void> _camera() async {
    final code = await _scanOneQr(context);
    if (code != null) {
      await _search(code);
    } else {
      _keepSearchFocus();
    }
  }

  Future<void> _album() async {
    final codes = await _pickQrCodesFromAlbum(context, multi: false);
    if (codes.isNotEmpty) {
      await _search(codes.first);
    } else {
      _keepSearchFocus();
    }
  }

  Future<void> _showPinHistory() async {
    final result = _result;
    if (result == null || !result.found) {
      _keepSearchFocus();
      return;
    }

    final rows = await widget.api.recentHistory(limit: 3000);
    final matches = rows
        .where((item) => item.pinCode.trim() == result.code.trim())
        .toList();

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final height = MediaQuery.of(sheetContext).size.height * 0.62;
        return SafeArea(
          child: SizedBox(
            height: height,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.history),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'LỊCH SỬ PIN',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      Text(
                        '${matches.length} lần',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SelectableText(
                    result.code,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ),
                const Divider(),
                Expanded(
                  child: matches.isEmpty
                      ? const Center(
                          child: Text('Chưa có lịch sử NHẬP/XUẤT cho mã này.'),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(10, 4, 10, 20),
                          itemCount: matches.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1),
                          itemBuilder: (_, index) {
                            final item = matches[index];
                            final isIn = item.isInbound;
                            final isOut = item.isOutbound;
                            final action = isIn
                                ? 'NHẬP'
                                : isOut
                                    ? 'XUẤT'
                                    : item.action;
                            final location = item.location.trim().isEmpty
                                ? '-'
                                : 'Dãy số ${_displayShelf(item.location)}';
                            final position = item.slot > 0
                                ? 'Kệ ${item.aisle} • '
                                    '${warehouseCellTerm(widget.api.warehouseId)} '
                                    '${_flatCellNumber(item.row, item.cell)} • '
                                    'Slot ${item.pinInCell.toString().padLeft(2, '0')}'
                                : '-';

                            return ListTile(
                              dense: true,
                              leading: Icon(
                                isIn
                                    ? Icons.south_rounded
                                    : isOut
                                        ? Icons.north_rounded
                                        : Icons.history,
                                color: isIn
                                    ? Colors.green
                                    : isOut
                                        ? Colors.orange
                                        : Colors.blueGrey,
                              ),
                              title: Text(
                                '$action • ${item.timestamp}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 12,
                                ),
                              ),
                              subtitle: Text(
                                '$location • $position'
                                '${item.pinType.trim().isNotEmpty ? '\nLoại pin: ${item.pinType}' : ''}'
                                '${item.operatorId.trim().isNotEmpty ? '\nNgười thao tác: ${item.operatorId}' : ''}',
                                style: const TextStyle(fontSize: 10.5),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
    _keepSearchFocus();
  }

  Future<void> _exportFoundPin() async {
    final result = _result;
    if (!widget.canExportPin) {
      _snack(context, 'Tài khoản chưa được cấp quyền XUẤT PIN.', error: true);
      _keepSearchFocus();
      return;
    }
    if (result == null || !result.found || !result.active || _exporting) {
      _keepSearchFocus();
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('XUẤT KHO PIN NÀY?'),
        content: SelectableText(
          '${result.code}\n\n${_rackPositionLabel(result.location, result.slot, warehouseId: widget.api.warehouseId)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('HỦY'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.upload_rounded),
            label: const Text('XUẤT KHO'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      _keepSearchFocus();
      return;
    }

    setState(() => _exporting = true);
    try {
      unawaited(_vibrateScan());
      final outcome = await widget.api.exportPin(result.code);
      if (!mounted) return;
      _snack(
        context,
        outcome.message,
        error: outcome.type != OutcomeType.success,
      );
      await _search(result.code);
    } catch (e) {
      if (mounted) _snack(context, e.toString(), error: true);
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
        _keepSearchFocus();
      }
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TÌM PIN')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _ScannerTextField(
            controller: _text,
            focusNode: _searchFocus,
            onSubmitted: _search,
            decoration: InputDecoration(
              labelText: 'Mã pin',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                onPressed: () => _search(_text.text),
                icon: const Icon(Icons.search),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _camera,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('QUÉT QR'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _album,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('ALBUM'),
                ),
              ),
            ],
          ),
          if (_loading) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 2),
          ],
          if (_result != null) ...[
            const SizedBox(height: 10),
            _PinResultCard(
              result: _result!,
              onHistory: _showPinHistory,
            ),
            if (_result!.found && _result!.active && widget.canExportPin) ...[
              const SizedBox(height: 7),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _exporting ? null : _exportFoundPin,
                  icon: _exporting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_rounded),
                  label: const Text('XUẤT KHO'),
                ),
              ),
            ],
          ],
          if (_recentSearches.isNotEmpty) ...[
            const SizedBox(height: 8),
            Card(
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                title: Text(
                  'LỊCH SỬ TÌM GẦN ĐÂY (${_recentSearches.length})',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
                children: [
                  for (final code in _recentSearches.take(10))
                    ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: const Icon(Icons.history, size: 18),
                      title: Text(
                        code,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 11.5,
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                      onTap: () => _search(code),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PinResultCard extends StatelessWidget {
  const _PinResultCard({
    required this.result,
    required this.onHistory,
  });

  final PinSearchResult result;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    if (!result.found) {
      return Card(
        color: Colors.red.withValues(alpha: 0.055),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.search_off, color: Colors.red),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Không tìm thấy mã pin này.',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final statusColor = result.active ? Colors.green : Colors.orange;
    final location = result.slot > 0
        ? 'Dãy ${_displayShelf(result.location)} • '
            '${result.aisleName} • ${result.cellName} • '
            'S${result.pinInCell.toString().padLeft(2, '0')}'
        : '-';
    final time = result.active
        ? (result.storedAt.isEmpty ? '-' : result.storedAt)
        : (result.exportedAt.isEmpty
            ? (result.storedAt.isEmpty ? '-' : result.storedAt)
            : result.exportedAt);

    return Card(
      color: statusColor.withValues(alpha: 0.065),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              flex: 11,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.active ? 'ĐANG TỒN' : 'ĐÃ XUẤT',
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 3),
                  SelectableText(
                    result.code,
                    maxLines: 2,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 11.5,
                    ),
                  ),
                  if (result.pinType.trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      'Loại pin: ${result.pinType}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.black54,
                        fontWeight: FontWeight.w700,
                        fontSize: 9.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              width: 1,
              height: 58,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              color: Colors.black12,
            ),
            Expanded(
              flex: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    location,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 10.5,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    time,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.black54,
                      fontSize: 9.5,
                    ),
                  ),
                  const SizedBox(height: 1),
                  InkWell(
                    onTap: onHistory,
                    borderRadius: BorderRadius.circular(6),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 3,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.history, size: 14),
                          SizedBox(width: 3),
                          Text(
                            'LỊCH SỬ PIN',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 9.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AuditLookupItem {
  const AuditLookupItem({
    required this.code,
    required this.result,
    required this.scannedAt,
  });

  final String code;
  final PinSearchResult result;
  final DateTime scannedAt;
}

class AuditPage extends StatefulWidget {
  const AuditPage({super.key, required this.api});
  final WarehouseApi api;

  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  final _manual = TextEditingController();
  final _manualFocus = FocusNode();
  final List<AuditLookupItem> _items = [];
  List<LocationSummary> _locations = const [];
  String? _selectedLocation;
  Set<String> _expectedCodes = <String>{};
  String _status = 'Chọn Dãy cần kiểm kê';
  bool _statusOk = true;
  bool _loadingLocation = true;
  bool _saving = false;
  bool _saved = false;
  int _duplicateScans = 0;
  final ScanDuplicateTracker _auditedThisSession = ScanDuplicateTracker();

  @override
  void initState() {
    super.initState();
    unawaited(_loadLocations());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _selectedLocation != null) {
        _focusScannerInput(_manualFocus);
      }
    });
  }

  @override
  void dispose() {
    _manual.dispose();
    _manualFocus.dispose();
    super.dispose();
  }

  void _keepFocus() {
    if (!mounted || _selectedLocation == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusScannerInput(_manualFocus);
    });
  }

  Future<void> _loadLocations() async {
    try {
      final locations = await widget.api.listLocations(force: true);
      if (!mounted) return;
      final selected = _selectedLocation != null &&
              locations.any((item) => item.id == _selectedLocation)
          ? _selectedLocation
          : (locations.isEmpty ? null : locations.first.id);
      setState(() {
        _locations = locations;
        _selectedLocation = selected;
      });
      await _loadExpected(clearSession: false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Không tải được Dãy kiểm kê: $e';
          _statusOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _loadingLocation = false);
    }
  }

  Future<void> _loadExpected({required bool clearSession}) async {
    final location = _selectedLocation;
    if (location == null) {
      if (mounted) setState(() => _expectedCodes = <String>{});
      return;
    }
    setState(() => _loadingLocation = true);
    try {
      final detail = await widget.api.getLocation(location);
      final expected = detail.slots
          .where((slot) => !slot.isEmpty)
          .map((slot) => slot.pinCode!.trim())
          .where((code) => code.isNotEmpty)
          .toSet();
      if (!mounted) return;
      setState(() {
        _expectedCodes = expected;
        if (clearSession) {
          _items.clear();
          _auditedThisSession.clear();
          _duplicateScans = 0;
          _saved = false;
        }
        _status = 'Dãy số ${_displayShelf(location)} • '
            '${expected.length} PIN cần kiểm kê';
        _statusOk = true;
      });
      _keepFocus();
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Không tải được tồn Dãy $location: $e';
          _statusOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _loadingLocation = false);
    }
  }

  Future<void> _changeLocation(String? location) async {
    if (location == null || location == _selectedLocation) return;
    if (_items.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('ĐỔI DÃY KIỂM KÊ?'),
          content: const Text(
            'Danh sách quét hiện tại sẽ được xóa.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('HỦY'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('ĐỔI DÃY'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _selectedLocation = location);
    await _loadExpected(clearSession: true);
  }

  List<AuditLookupItem> get _matchedItems => _items
      .where(
        (item) =>
            item.result.found &&
            item.result.active &&
            item.result.location == _selectedLocation,
      )
      .toList();

  List<AuditLookupItem> get _wrongLocationItems => _items
      .where(
        (item) =>
            item.result.found &&
            item.result.active &&
            item.result.location != _selectedLocation,
      )
      .toList();

  List<AuditLookupItem> get _unknownItems => _items
      .where((item) => !item.result.found || !item.result.active)
      .toList();

  Set<String> get _scannedCodes =>
      _items.map((item) => item.code).toSet();

  List<String> get _missingCodes {
    final missing = _expectedCodes.difference(_scannedCodes).toList()..sort();
    return missing;
  }

  Future<void> _saveAudit() async {
    final location = _selectedLocation;
    if (location == null || _items.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final scanned = _items.reversed.map((item) => item.code).toList();
      await widget.api.saveAudit(
        sessionId: 'ANDROID-${widget.api.warehouseId}-'
            '${DateTime.now().millisecondsSinceEpoch}',
        location: location,
        scanned: scanned,
        expected: _expectedCodes.length,
        matched: _matchedItems.length,
        missing: _missingCodes,
        wrongLocation:
            _wrongLocationItems.map((item) => item.code).toList(),
        unknown: _unknownItems.map((item) => item.code).toList(),
        duplicateScans: _duplicateScans,
      );
      if (!mounted) return;
      setState(() {
        _status = 'ĐÃ LƯU KIỂM KÊ • Khớp ${_matchedItems.length} • '
            'Thiếu ${_missingCodes.length} • '
            'Sai vị trí ${_wrongLocationItems.length} • '
            'Ngoài hệ thống ${_unknownItems.length}';
        _statusOk = true;
        _saved = true;
      });
      _snack(context, 'Đã lưu kiểm kê và đưa vào hàng chờ đồng bộ.');
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Không lưu được kiểm kê: $e';
          _statusOk = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        _keepFocus();
      }
    }
  }

  Future<ContinuousScanFeedback> _lookupCode(String raw) async {
    final code = raw.trim();
    if (code.isEmpty) {
      return const ContinuousScanFeedback(false, 'Mã trống.');
    }

    final selectedLocation = _selectedLocation;
    if (selectedLocation == null) {
      return const ContinuousScanFeedback(
        false,
        'Chưa chọn Dãy cần kiểm kê.',
      );
    }

    unawaited(_vibrateScan());

    if (!_auditedThisSession.markIfNew(code)) {
      const message = 'MÃ ĐÃ QUÉT KIỂM KÊ TRÙNG TRONG PHIÊN NÀY.';
      if (mounted) {
        setState(() {
          _duplicateScans++;
          _saved = false;
          _status = '$code • $message';
          _statusOk = false;
        });
      }
      return const ContinuousScanFeedback(
        false,
        message,
        duplicate: true,
      );
    }

    PinSearchResult result;
    try {
      result = await widget.api.searchPin(code);
    } catch (_) {
      _auditedThisSession.unmark(code);
      rethrow;
    }
    if (!mounted) {
      return const ContinuousScanFeedback(false, 'Màn hình đã đóng.');
    }

    final item = AuditLookupItem(
      code: code,
      result: result,
      scannedAt: DateTime.now(),
    );

    final matched = result.found &&
        result.active &&
        result.location == selectedLocation;
    final wrongLocation = result.found &&
        result.active &&
        result.location != selectedLocation;
    final message = matched
        ? 'KHỚP • ${result.aisleName} • ${result.cellName} • '
            'Slot ${result.pinInCell.toString().padLeft(2, '0')}'
        : wrongLocation
            ? 'SAI VỊ TRÍ • đang ở Dãy số '
                '${_displayShelf(result.location)} • ${result.aisleName} • '
                '${result.cellName}'
            : result.found
                ? 'NGOÀI HỆ THỐNG • mã đã xuất / không còn tồn'
                : 'NGOÀI HỆ THỐNG • không tìm thấy';

    setState(() {
      _items.insert(0, item);
      _saved = false;
      _status = '$code • $message';
      _statusOk = matched;
    });

    return ContinuousScanFeedback(matched, message);
  }

  Future<void> _manualSubmit(String value) async {
    final code = value.trim();
    if (code.isEmpty) {
      _keepFocus();
      return;
    }

    _manual.clear();
    _focusScannerInput(_manualFocus);
    final result = await _lookupCode(code);
    if (!mounted) return;

    if (result.duplicate) {
      await _showDuplicateWarning(
        context,
        code: code,
        message: result.message,
      );
      if (!mounted) return;
    }

    _keepFocus();
  }

  Future<void> _scanQr() async {
    await _scanContinuous(
      context,
      title: 'KIỂM KÊ • QUÉT LIÊN TỤC',
      onCode: _lookupCode,
    );
    _keepFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('KIỂM KÊ'),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              tooltip: 'Xóa danh sách hiện tại',
              onPressed: () {
                setState(() {
                  _items.clear();
                  _auditedThisSession.clear();
                  _duplicateScans = 0;
                  _saved = false;
                  _status = 'Đã xóa danh sách kiểm kê';
                  _statusOk = true;
                });
                _keepFocus();
              },
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: DropdownButtonFormField<String>(
              key: ValueKey('audit-location-${_selectedLocation ?? ''}'),
              initialValue: _selectedLocation,
              decoration: const InputDecoration(
                labelText: 'Dãy cần kiểm kê',
                prefixIcon: Icon(Icons.warehouse_outlined),
              ),
              items: _locations
                  .map(
                    (location) => DropdownMenuItem<String>(
                      value: location.id,
                      child: Text(
                        'Dãy số ${_displayShelf(location.id)} • '
                        '${location.occupied} PIN',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _loadingLocation ? null : _changeLocation,
            ),
          ),
          if (_loadingLocation)
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: LinearProgressIndicator(),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: _ScannerTextField(
              controller: _manual,
              focusNode: _manualFocus,
              enabled: _selectedLocation != null && !_loadingLocation,
              onSubmitted: _manualSubmit,
              decoration: InputDecoration(
                labelText: 'Nhập / bắn mã PIN',
                hintText: 'Bắn mã rồi Enter',
                prefixIcon: const Icon(Icons.keyboard),
                suffixIcon: IconButton(
                  tooltip: 'Quét QR liên tục',
                  onPressed:
                      _selectedLocation != null && !_loadingLocation
                          ? _scanQr
                          : null,
                  icon: const Icon(Icons.qr_code_scanner),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _statusOk
                          ? Colors.green.shade800
                          : Colors.red.shade800,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Đã quét ${_items.length} • trùng $_duplicateScans',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.black54,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _items.isEmpty
                ? const Center(
                    child: Text(
                      'Bắn mã để bắt đầu kiểm kê.',
                      style: TextStyle(color: Colors.black45),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 90),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final item = _items[index];
                      final r = item.result;
                      final active = r.found && r.active;
                      final itemMatched =
                          active && r.location == _selectedLocation;
                      final itemWrong =
                          active && r.location != _selectedLocation;
                      final subtitle = itemMatched
                          ? 'KHỚP • ${r.aisleName} • ${r.cellName} • '
                              'Slot ${r.pinInCell.toString().padLeft(2, '0')}'
                          : itemWrong
                              ? 'SAI VỊ TRÍ • Dãy số '
                                  '${_displayShelf(r.location)} • '
                                  '${r.aisleName} • ${r.cellName}'
                              : r.found
                                  ? 'NGOÀI HỆ THỐNG • ĐÃ XUẤT'
                                  : 'NGOÀI HỆ THỐNG • KHÔNG TÌM THẤY';
                      final tone = itemMatched
                          ? Colors.green
                          : itemWrong
                              ? Colors.orange
                              : Colors.red;
                      return Container(
                        margin: const EdgeInsets.symmetric(vertical: 2),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: tone.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                            color: tone.withValues(alpha: 0.28),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 28,
                              child: Text(
                                '${_items.length - index}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.code,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 13.5,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    subtitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: itemMatched
                                          ? Colors.green.shade800
                                          : itemWrong
                                              ? Colors.orange.shade900
                                              : Colors.red.shade700,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class InventoryPage extends StatefulWidget {
  const InventoryPage({
    super.key,
    required this.api,
  });

  final WarehouseApi api;

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  List<Map<String, dynamic>> _items = const [];
  Map<String, String> _labels = const {};
  bool _loading = true;
  String _query = '';

  String _labelKey(
    String location,
    String kind,
    int aisle,
    int row,
    int cell,
  ) =>
      '$location|$kind|$aisle|$row|$cell';

  String _rackName(
    String location,
    String kind,
    int aisle,
    int row,
    int cell,
    String fallback,
  ) =>
      _labels[_labelKey(location, kind, aisle, row, cell)] ?? fallback;

  String _positionOf(Map<String, dynamic> item) {
    final location = '${item['location'] ?? ''}';
    final slot = _asInt(item['slot']);
    if (location.isEmpty || slot < 1) return '-';
    final aisle = _aisleFromPosition(slot);
    final row = _rowFromPosition(slot);
    final cell = _cellFromPosition(slot);
    final pin = _pinInCell(slot);
    final top = _rackName(
      location,
      'KE',
      0,
      0,
      0,
      'Dãy số ${_displayShelf(location)}',
    );
    final aisleName = _rackName(
      location,
      'DAY',
      aisle,
      0,
      0,
      'Kệ $aisle',
    );
    final cellName = _rackName(
      location,
      'O',
      aisle,
      row,
      cell,
      '${warehouseCellTerm(widget.api.warehouseId)} '
          '${_flatCellNumber(row, cell)}',
    );
    return '$top • $aisleName • $cellName • '
        'Slot ${pin.toString().padLeft(2, '0')}';
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _query.trim().toUpperCase();
    if (q.isEmpty) return _items;
    return _items.where((item) {
      final code = '${item['code'] ?? ''}'.toUpperCase();
      final location = '${item['location'] ?? ''}'.toUpperCase();
      return code.contains(q) || location.contains(q) ||
          _positionOf(item).toUpperCase().contains(q);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusInventorySearch();
    });
  }

  void _focusInventorySearch() {
    if (!mounted) return;
    _focusScannerInput(_searchFocus);
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
  }

  void _submitInventorySearch(String value) {
    final code = value.trim();
    if (code.isNotEmpty) {
      setState(() => _query = code);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusInventorySearch();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    try {
      final data = await widget.api.inventoryData();
      final inventory = (data['inventory'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final labels = <String, String>{};
      for (final raw in (data['rackLabels'] as List<dynamic>? ?? const [])) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final location = '${item['location'] ?? ''}';
        final kind = '${item['kind'] ?? ''}'.toUpperCase();
        final aisle = _asInt(item['aisle']);
        final row = _asInt(item['row']);
        final cell = _asInt(item['cell']);
        final label = '${item['label'] ?? ''}'.trim();
        if (location.isEmpty || kind.isEmpty || label.isEmpty) continue;
        labels[_labelKey(location, kind, aisle, row, cell)] = label;
      }
      if (!mounted) return;
      setState(() {
        _items = inventory;
        _labels = labels;
      });
    } catch (e) {
      if (mounted) _snack(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _scanSearch() async {
    final code = await _scanOneQr(context);
    if (code == null || !mounted) return;
    _search.text = code;
    setState(() => _query = code);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusInventorySearch();
    });
  }

  Future<void> _detail(Map<String, dynamic> item) async {
    final code = '${item['code'] ?? ''}';
    final location = '${item['location'] ?? ''}';
    final slot = _asInt(item['slot']);
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('CHI TIẾT TỒN KHO'),
        content: SizedBox(
          width: 430,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _InfoRow(label: 'Mã PIN', value: code),
                _InfoRow(label: 'Vị trí', value: _positionOf(item)),
                _InfoRow(
                  label: 'Nhập lúc',
                  value: '${item['storedAt'] ?? ''}'.isEmpty
                      ? '-'
                      : '${item['storedAt']}',
                ),
                _InfoRow(
                  label: 'Người nhập',
                  value: '${item['operatorId'] ?? ''}'.isEmpty
                      ? '-'
                      : '${item['operatorId']}',
                ),
                _InfoRow(
                  label: 'Thiết bị',
                  value: '${item['deviceId'] ?? ''}'.isEmpty
                      ? '-'
                      : '${item['deviceId']}',
                ),
                _InfoRow(
                  label: 'Slot nội bộ',
                  value: location.isEmpty || slot < 1 ? '-' : '$slot',
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ĐÓNG'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('TỒN KHO'),
        actions: [
          IconButton(
            tooltip: 'Làm mới',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() => _query = value),
              onSubmitted: _submitInventorySearch,
              decoration: InputDecoration(
                labelText: 'Tìm mã PIN / vị trí',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: 'Quét QR',
                  onPressed: _scanSearch,
                  icon: const Icon(Icons.qr_code_scanner),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${rows.length} pin đang tồn',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading && rows.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: rows.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: const [
                              SizedBox(height: 120),
                              Center(child: Text('Không có dữ liệu tồn')),
                            ],
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(10, 4, 10, 24),
                            itemCount: rows.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 3),
                            itemBuilder: (_, index) {
                              final item = rows[index];
                              return Card(
                                child: ListTile(
                                  dense: true,
                                  onTap: () => _detail(item),
                                  leading: const CircleAvatar(
                                    radius: 18,
                                    child: Icon(Icons.battery_full, size: 18),
                                  ),
                                  title: Text(
                                    '${item['code'] ?? ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  subtitle: Text(
                                    _positionOf(item),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                ),
                              );
                            },
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}


class PendingTransfersPage extends StatefulWidget {
  const PendingTransfersPage({
    super.key,
    required this.inbound,
    required this.api,
    this.showAll = false,
    this.selectAllInitially = false,
    this.onUploadFinished,
  });

  // inbound=true: NHẬP, inbound=false: XUẤT.
  // showAll=true: tải riêng 2 danh sách rồi gộp, KHÔNG dùng null.
  final bool inbound;
  final WarehouseApi api;
  final bool showAll;
  final bool selectAllInitially;
  final Future<void> Function()? onUploadFinished;

  @override
  State<PendingTransfersPage> createState() => _PendingTransfersPageState();
}

class _PendingTransfersPageState extends State<PendingTransfersPage> {
  List<Map<String, dynamic>> _rows = const [];
  final Set<String> _selected = <String>{};
  bool _loading = true;
  bool _deleting = false;
  bool _uploading = false;
  bool _didInitialSelect = false;
  int _uploadDone = 0;
  int _uploadTotal = 0;
  String? _loadError;

  bool get _busy => _deleting || _uploading;

  String get _type => widget.showAll
      ? 'NHẬP / XUẤT'
      : widget.inbound
          ? 'NHẬP'
          : 'XUẤT';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }

    try {
      final List<Map<String, dynamic>> rows;
      if (widget.showAll) {
        final groups = await Future.wait([
          LocalWarehouseStore.instance.listPendingTransfers(
            inbound: true,
          ),
          LocalWarehouseStore.instance.listPendingTransfers(
            inbound: false,
          ),
        ]);
        rows = <Map<String, dynamic>>[
          ...groups[0],
          ...groups[1],
        ]..sort(
            (a, b) => _asInt(a['createdMs'])
                .compareTo(_asInt(b['createdMs'])),
          );
      } else {
        rows = await LocalWarehouseStore.instance.listPendingTransfers(
          inbound: widget.inbound,
        );
      }

      final normalized = <Map<String, dynamic>>[];
      final seenOpIds = <String>{};
      for (final row in rows) {
        final opId = '${row['opId'] ?? ''}'.trim();
        if (opId.isEmpty || !seenOpIds.add(opId)) continue;
        normalized.add(row);
      }

      if (!mounted) return;
      setState(() {
        _rows = normalized;
        _loadError = null;
        _selected.removeWhere(
          (id) => !_rows.any((row) => '${row['opId']}' == id),
        );
        if (!_didInitialSelect && widget.selectAllInitially) {
          _selected
            ..clear()
            ..addAll(_rows.map((row) => '${row['opId']}'));
          _didInitialSelect = true;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _rows = const [];
        _selected.clear();
        _loadError = e.toString();
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _timeText(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/${d.year} '
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }

  String _positionText(Map<String, dynamic> row) {
    final location = '${row['location'] ?? ''}';
    final slot = _asInt(row['slot']);
    if (location.isEmpty || slot < 1) return '-';
    return 'Dãy số ${_displayShelf(location)} • '
        '${_positionLabel(slot, warehouseId: widget.api.warehouseId)}';
  }

  Future<bool> _confirmDelete(int count) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text(count == 1 ? 'XÓA KHỎI CHỜ XÁC NHẬN?' : 'XÓA $count THAO TÁC?'),
        content: Text(
          'Thao tác chưa được xác nhận gửi Server sẽ bị HỦY. '
          'App sẽ hoàn tác dữ liệu local tương ứng để không làm lệch tồn kho.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('HỦY'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.delete_forever),
            label: const Text('XÓA'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _uploadIds(List<String> ids) async {
    if (_busy || ids.isEmpty) return;

    final onUploadFinished = widget.onUploadFinished;
    final uniqueIds = ids
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (uniqueIds.isEmpty) return;

    setState(() {
      _uploading = true;
      _uploadDone = 0;
      _uploadTotal = uniqueIds.length;
    });

    try {
      final result = await widget.api.uploadPendingTransfers(
        uniqueIds,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _uploadDone = done;
            _uploadTotal = total;
          });
        },
      );

      if (!mounted) return;

      final uploaded = _asInt(result['uploaded']);
      final failed = _asInt(result['failed']);
      final fatalCode = '${result['fatalCode'] ?? ''}'.trim();
      final fatalMessage =
          '${result['fatalMessage'] ?? ''}'.trim();
      final blocked =
          (result['blocked'] as List<dynamic>? ?? const [])
              .map((e) => '$e')
              .toList();
      final errors =
          (result['errors'] as List<dynamic>? ?? const [])
              .map((e) => '$e')
              .toList();

      if (fatalCode.isEmpty && failed == 0 && blocked.isEmpty) {
        _snack(
          context,
          uploaded > 0
              ? 'Đã xác nhận $uploaded thao tác • Server đã nhận.'
              : 'Không có thao tác nào cần xác nhận.',
        );
      } else {
        final first = fatalMessage.isNotEmpty
            ? '[$fatalCode] $fatalMessage'
            : blocked.isNotEmpty
                ? blocked.first
                : errors.isNotEmpty
                    ? errors.first
                    : 'Có thao tác chưa gửi được.';
        _snack(
          context,
          'Đã gửi $uploaded • còn lỗi. $first',
          error: true,
        );
      }

      // Only successful rows have been removed from outbox.
      // Reloading here shows exactly what still needs retry.
      await _load();
    } catch (e) {
      // UI-level containment. This should be unreachable because the API
      // already returns a structured error, but it prevents route loss.
      if (mounted) {
        _snack(
          context,
          'Lỗi giao diện khi xác nhận: $e',
          error: true,
        );
        await _load();
      }
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadDone = 0;
          _uploadTotal = 0;
        });
      }

      if (onUploadFinished != null) {
        try {
          await onUploadFinished();
        } catch (_) {
          // Upload already completed. Home refresh failure must not
          // turn a successful upload into a UI/runtime failure.
        }
      }
    }
  }

  Future<void> _deleteIds(List<String> ids) async {
    if (_busy || ids.isEmpty) return;

    bool confirmed;
    try {
      confirmed = await _confirmDelete(ids.length);
    } catch (e) {
      if (mounted) {
        _snack(
          context,
          'Không mở được xác nhận xóa: $e',
          error: true,
        );
      }
      return;
    }

    if (!confirmed || !mounted) return;

    setState(() => _deleting = true);
    try {
      final result =
          await LocalWarehouseStore.instance.cancelPendingTransfers(ids);
      if (!mounted) return;

      final deleted = _asInt(result['deleted']);
      final failed = result['failed'];
      final failedCount = failed is List ? failed.length : 0;

      if (failedCount == 0) {
        _snack(
          context,
          'Đã xóa $deleted thao tác chờ xác nhận.',
        );
      } else {
        final firstError =
            failed is List && failed.isNotEmpty
                ? '${failed.first}'
                : '';
        _snack(
          context,
          'Đã xóa $deleted • Không xóa được $failedCount.'
          '${firstError.isNotEmpty ? ' $firstError' : ''}',
          error: true,
        );
      }

      _selected.clear();
    } catch (e) {
      if (mounted) {
        _snack(
          context,
          'Không xóa được hàng chờ: $e',
          error: true,
        );
      }
    } finally {
      if (mounted) {
        try {
          await _load();
        } catch (_) {
          // _load already owns its own visible error state.
        }
        if (mounted) setState(() => _deleting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rowIds = _rows
        .map((row) => '${row['opId']}'.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    final allSelected = rowIds.isNotEmpty &&
        _selected.length == rowIds.length &&
        _selected.containsAll(rowIds);

    return PopScope(
      canPop: true,
      child: Scaffold(
      appBar: AppBar(
        title: Text('CHỜ XÁC NHẬN • $_type'),
        actions: [
          IconButton(
            tooltip: 'Làm mới',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 5, 8, 7),
              child: Column(
                children: [
                  Row(
                    children: [
                      Checkbox(
                        value: allSelected,
                        onChanged: _rows.isEmpty || _busy
                            ? null
                            : (value) {
                                setState(() {
                                  if (value == true) {
                                    _selected
                                      ..clear()
                                      ..addAll(
                                        rowIds,
                                      );
                                  } else {
                                    _selected.clear();
                                  }
                                });
                              },
                      ),
                      Expanded(
                        child: Text(
                          'CHỌN TẤT CẢ • ${_rows.length}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_uploading && _uploadTotal > 0) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: LinearProgressIndicator(
                            value: _uploadTotal <= 0
                                ? null
                                : _uploadDone / _uploadTotal,
                            minHeight: 3,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$_uploadDone/$_uploadTotal',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _selected.isEmpty || _busy
                              ? null
                              : () => _uploadIds(_selected.toList()),
                          icon: _uploading
                              ? const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.cloud_upload, size: 18),
                          label: Text(
                            _selected.isEmpty
                                ? 'XÁC NHẬN'
                                : 'XÁC NHẬN (${_selected.length})',
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red,
                          ),
                          onPressed: _selected.isEmpty || _busy
                              ? null
                              : () => _deleteIds(_selected.toList()),
                          icon: _deleting
                              ? const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.delete_sweep, size: 18),
                          label: Text(
                            _selected.isEmpty
                                ? 'XÓA'
                                : 'XÓA (${_selected.length})',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _loadError != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.error_outline,
                                color: Colors.red,
                                size: 34,
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'KHÔNG MỞ ĐƯỢC HÀNG CHỜ',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                _loadError!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 11),
                              ),
                              const SizedBox(height: 10),
                              FilledButton.icon(
                                onPressed: _load,
                                icon: const Icon(Icons.refresh),
                                label: const Text('THỬ LẠI'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _rows.isEmpty
                        ? const Center(
                            child: Text(
                              'Không có thao tác chờ xác nhận.',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          )
                        : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                        itemCount: _rows.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: 4),
                        itemBuilder: (_, index) {
                          final row = _rows[index];
                          final opId = '${row['opId']}';
                          final code = '${row['code'] ?? ''}';
                          final action = '${row['action'] ?? ''}';
                          final actionText =
                              action == 'exportPin' ? 'XUẤT' : 'NHẬP';
                          final lastError =
                              '${row['lastError'] ?? ''}'.trim();
                          final attempts = _asInt(row['attempts']);
                          final checked = _selected.contains(opId);

                          return Card(
                            clipBehavior: Clip.antiAlias,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                6,
                                5,
                                4,
                                5,
                              ),
                              child: Row(
                                crossAxisAlignment:
                                    CrossAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 38,
                                    child: Center(
                                      child: Checkbox(
                                        value: checked,
                                        visualDensity:
                                            VisualDensity.compact,
                                        materialTapTargetSize:
                                            MaterialTapTargetSize
                                                .shrinkWrap,
                                        onChanged: _busy
                                            ? null
                                            : (value) {
                                                setState(() {
                                                  if (value == true) {
                                                    _selected.add(opId);
                                                  } else {
                                                    _selected.remove(opId);
                                                  }
                                                });
                                              },
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          code,
                                          maxLines: 1,
                                          overflow:
                                              TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight:
                                                FontWeight.w900,
                                            fontSize: 11.5,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${widget.showAll ? '$actionText • ' : ''}'
                                          '${_positionText(row)}',
                                          maxLines: 1,
                                          overflow:
                                              TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 10.2,
                                            color: Colors.black54,
                                          ),
                                        ),
                                        Text(
                                          '${_timeText(_asInt(row['createdMs']))}'
                                          '${attempts > 0 ? ' • thử $attempts lần' : ''}',
                                          maxLines: 1,
                                          overflow:
                                              TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 9.8,
                                            color: Colors.black54,
                                          ),
                                        ),
                                        if (lastError.isNotEmpty)
                                          Text(
                                            lastError,
                                            maxLines: 1,
                                            overflow:
                                                TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 9.6,
                                              color:
                                                  Colors.red.shade700,
                                              fontWeight:
                                                  FontWeight.w700,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  IconButton(
                                    tooltip: 'Xác nhận thao tác này',
                                    visualDensity:
                                        VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    constraints:
                                        const BoxConstraints.tightFor(
                                      width: 36,
                                      height: 36,
                                    ),
                                    onPressed: _busy
                                        ? null
                                        : () => _uploadIds([opId]),
                                    icon: const Icon(
                                      Icons.task_alt,
                                      size: 20,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Xóa thao tác này',
                                    visualDensity:
                                        VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    constraints:
                                        const BoxConstraints.tightFor(
                                      width: 36,
                                      height: 36,
                                    ),
                                    onPressed: _busy
                                        ? null
                                        : () => _deleteIds([opId]),
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.red,
                                      size: 20,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
      ),
    );
  }
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    required this.api,
  });
  final WarehouseApi api;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final _query = TextEditingController();
  static const int _pageSize = 200;
  List<HistoryEntry> _items = const [];
  bool _loading = true;
  String _searchText = '';
  int _offset = 0;
  int _total = 0;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _refresh(resetPage: true);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool resetPage = false}) async {
    if (resetPage) _offset = 0;
    if (mounted) setState(() => _loading = true);
    try {
      final page = await widget.api.historyPage(
        limit: _pageSize,
        offset: _offset,
        query: _searchText,
      );
      if (!mounted) return;
      final rows = (page['rows'] as List<dynamic>? ?? const [])
          .whereType<HistoryEntry>()
          .toList();
      final total = _asInt(page['total']);
      // Nếu dữ liệu vừa thu hẹp và offset vượt trang cuối, quay về trang cuối.
      if (rows.isEmpty && total > 0 && _offset >= total) {
        _offset = max(0, ((total - 1) ~/ _pageSize) * _pageSize);
        return _refresh();
      }
      setState(() {
        _items = rows;
        _total = total;
      });
    } catch (e) {
      if (mounted) _snack(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _searchChanged(String value) {
    _searchText = value;
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 280), () {
      if (mounted) _refresh(resetPage: true);
    });
  }

  Future<void> _previousPage() async {
    if (_offset <= 0 || _loading) return;
    _offset = max(0, _offset - _pageSize);
    await _refresh();
  }

  Future<void> _nextPage() async {
    if (_loading || _offset + _pageSize >= _total) return;
    _offset += _pageSize;
    await _refresh();
  }

  int get _pageNumber => _total == 0 ? 0 : (_offset ~/ _pageSize) + 1;
  int get _pageCount => _total == 0 ? 0 : ((_total + _pageSize - 1) ~/ _pageSize);

  Future<void> _scanHistoryQr() async {
    final code = await _scanOneQr(context);
    if (code == null || !mounted) return;
    _query.text = code;
    _searchText = code;
    await _refresh(resetPage: true);
  }

  Future<void> _showHistoryDetail(HistoryEntry item) async {
    final position = item.location.trim().isEmpty
        ? '-'
        : item.slot > 0
            ? _rackPositionLabel(
                item.location,
                item.slot,
                warehouseId: widget.api.warehouseId,
              )
            : 'Dãy số ${_displayShelf(item.location)}';

    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('CHI TIẾT LỊCH SỬ'),
        content: SizedBox(
          width: 430,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _InfoRow(
                  label: 'Mã PIN',
                  value: item.pinCode.isEmpty ? '-' : item.pinCode,
                ),
                _InfoRow(label: 'Thao tác', value: _actionLabel(item.action)),
                _InfoRow(label: 'Vị trí', value: position),
                _InfoRow(label: 'Thời gian', value: item.timestamp),
                _InfoRow(
                  label: 'Người thao tác',
                  value: item.operatorId.isEmpty ? '-' : item.operatorId,
                ),
                _InfoRow(
                  label: 'Thiết bị',
                  value: item.deviceId.isEmpty ? '-' : item.deviceId,
                ),
                _InfoRow(
                  label: 'Ghi chú',
                  value: item.note.isEmpty ? '-' : item.note,
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ĐÓNG'),
          ),
        ],
      ),
    );
  }

  String _actionLabel(String action) {
    switch (action) {
      case 'NHAP':
        return 'NHẬP PIN';
      case 'THAY_NHAP':
        return 'THAY PIN • NHẬP MỚI';
      case 'XUAT':
        return 'XUẤT PIN';
      case 'THAY_XUAT':
        return 'THAY PIN • XUẤT CŨ';
      case 'THEM_KE':
        return 'THÊM DÃY SỐ';
      case 'XOA_KE':
        return 'XÓA DÃY SỐ';
      case 'DOI_TEN_KE':
        return 'ĐỔI TÊN / NHÃN DÃY';
      case 'CAU_HINH_KE':
        return 'CẤU HÌNH DÃY SỐ';
      case 'KIEM_KE':
        return 'KIỂM KÊ';
      default:
        return action.isEmpty ? 'THAO TÁC HỆ THỐNG' : action;
    }
  }

  Widget _buildList(List<HistoryEntry> rows) {
    if (_loading && rows.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 120),
            Center(child: Text('Không có dữ liệu ở trang này')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 30),
        itemCount: rows.length,
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (_, index) {
          final item = rows[index];
          final hasPin = item.pinCode.trim().isNotEmpty;
          final hasPosition =
              item.location.trim().isNotEmpty && item.slot > 0;
          final title = hasPin ? item.pinCode : _actionLabel(item.action);
          final details = <String>[
            _actionLabel(item.action),
            if (hasPosition)
              _rackPositionLabel(
                item.location,
                item.slot,
                warehouseId: widget.api.warehouseId,
              ),
            if (!hasPosition && item.location.trim().isNotEmpty)
              'Dãy số ${_displayShelf(item.location)}',
            if (item.note.trim().isNotEmpty) item.note,
            'Người thao tác: ${item.operatorId}',
            item.timestamp,
          ];
          return Card(
            child: ListTile(
              dense: true,
              onTap: () => _showHistoryDetail(item),
              leading: CircleAvatar(
                radius: 18,
                child: Icon(
                  item.isInbound
                      ? Icons.download_rounded
                      : item.isOutbound
                          ? Icons.upload_rounded
                          : Icons.settings_outlined,
                  size: 19,
                ),
              ),
              title: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: Text(
                details.join('\n'),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inbound = _items.where((e) => e.isInbound).toList();
    final outbound = _items.where((e) => e.isOutbound).toList();
    final system = _items.where((e) => e.isSystem).toList();

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('LỊCH SỬ'),
          actions: [
            IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'NHẬP (${inbound.length})'),
              Tab(text: 'XUẤT (${outbound.length})'),
              Tab(text: 'HỆ THỐNG (${system.length})'),
            ],
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                controller: _query,
                onChanged: _searchChanged,
                onSubmitted: (value) {
                  _searchText = value;
                  _refresh(resetPage: true);
                },
                decoration: InputDecoration(
                  labelText: 'Nhập / quét QR để tra lịch sử LOCAL',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    tooltip: 'Quét QR',
                    onPressed: _scanHistoryQr,
                    icon: const Icon(Icons.qr_code_scanner),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Trang trước',
                    onPressed: _offset > 0 && !_loading ? _previousPage : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Text(
                      'Trang $_pageNumber/$_pageCount • $_total bản ghi local',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Trang sau',
                    onPressed: _offset + _pageSize < _total && !_loading
                        ? _nextPage
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _buildList(inbound),
                  _buildList(outbound),
                  _buildList(system),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.serverUrl,
    required this.autoServerUrl,
    required this.activeWarehouseId,
    required this.deviceId,
    required this.operatorId,
    required this.isAdmin,
    required this.sessionToken,
  });

  final String serverUrl;
  final String autoServerUrl;
  final String activeWarehouseId;
  final String deviceId;
  final String operatorId;
  final bool isAdmin;
  final String sessionToken;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _testing = false;

  Future<void> _test() async {
    setState(() => _testing = true);
    try {
      await WarehouseApi(
        widget.activeWarehouseId == kWarehouseAuto
            ? widget.autoServerUrl
            : widget.serverUrl,
        widget.deviceId,
        operatorId: widget.operatorId,
        sessionToken: widget.sessionToken,
        warehouseId: widget.activeWarehouseId,
        authBaseUrl: widget.serverUrl,
      ).ping();
      if (mounted) _snack(context, 'Kết nối ${warehouseLabel(widget.activeWarehouseId)} thành công.');
    } catch (e) {
      if (mounted) _snack(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _changePassword() async {
    if (widget.isAdmin || widget.activeWarehouseId != kWarehouseVf) return;
    final verification = TextEditingController();
    final newPass = TextEditingController();
    final confirm = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ĐỔI MẬT KHẨU'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: verification,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Mật khẩu hiện tại',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: newPass,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Mật khẩu mới'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: confirm,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Nhập lại mật khẩu mới',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Đổi mật khẩu'),
          ),
        ],
      ),
    );

    final currentPassword = verification.text;
    final newPassword = newPass.text;
    final confirmedPassword = confirm.text;
    verification.dispose();
    newPass.dispose();
    confirm.dispose();

    if (ok != true) return;
    if (newPassword.length < 6) {
      _snack(context, 'Mật khẩu mới phải từ 6 ký tự.', error: true);
      return;
    }
    if (newPassword != confirmedPassword) {
      _snack(context, 'Mật khẩu nhập lại không khớp.', error: true);
      return;
    }

    try {
      final api = WarehouseApi(
        widget.serverUrl,
        widget.deviceId,
        operatorId: widget.operatorId,
        sessionToken: widget.sessionToken,
      );
      await api.changeOwnPassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      if (mounted) _snack(context, 'Đổi mật khẩu thành công.');
    } catch (e) {
      if (mounted) _snack(context, e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CÀI ĐẶT HIỆN TRƯỜNG'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_done_outlined),
              title: Text(
                'Backend • ${warehouseLabel(widget.activeWarehouseId)}',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: const Text(
                'URL Backend được quản trị trên N07 HUBDNI PC. Android chỉ kiểm tra kết nối để tránh cấu hình nhầm tại hiện trường.',
              ),
              trailing: OutlinedButton(
                onPressed: _testing ? null : _test,
                child: const Text('KIỂM TRA'),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: ListTile(
              leading: Icon(
                widget.isAdmin
                    ? Icons.admin_panel_settings_outlined
                    : Icons.person_outline,
              ),
              title: Text(
                'User: ${widget.operatorId}',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: Text(
                widget.isAdmin
                    ? 'Quyền ADMIN • quản trị Backend, User và mật khẩu ADMIN thực hiện trên PC.'
                    : 'User thường • không được sửa cấu hình server.',
              ),
            ),
          ),
          if (!widget.isAdmin &&
              widget.activeWarehouseId == kWarehouseVf) ...[
            const SizedBox(height: 10),
            Card(
              child: ListTile(
                leading: const Icon(Icons.password),
                title: const Text('Đổi mật khẩu'),
                subtitle: const Text(
                  'Nhập mật khẩu hiện tại để đổi mật khẩu mới.',
                ),
                trailing: FilledButton(
                  onPressed: _changePassword,
                  child: const Text('Đổi pass'),
                ),
              ),
            ),
          ],
          if (!widget.isAdmin &&
              widget.activeWarehouseId == kWarehouseAuto) ...[
            const SizedBox(height: 10),
            const _NoticeCard(
              message:
                  'Muốn đổi mật khẩu, hãy chuyển sang PIN XE MÁY ĐIỆN. User Master và cache đăng nhập offline nằm ở VF_E2W.',
              color: Colors.blue,
              icon: Icons.info_outline,
            ),
          ],
          const SizedBox(height: 10),
          Card(
            child: ListTile(
              leading: const Icon(Icons.phone_android),
              title: const Text('Mã thiết bị'),
              subtitle: SelectableText(widget.deviceId),
            ),
          ),
        ],
      ),
    );
  }


}


void _focusScannerInput(FocusNode focusNode) {
  if (!focusNode.canRequestFocus) return;
  SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  focusNode.requestFocus();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  });
  Future<void>.delayed(const Duration(milliseconds: 80), () {
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  });
  Future<void>.delayed(const Duration(milliseconds: 180), () {
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  });
}

class _ScannerTextField extends StatefulWidget {
  const _ScannerTextField({
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    required this.decoration,
    this.enabled = true,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmitted;
  final InputDecoration decoration;
  final bool enabled;

  @override
  State<_ScannerTextField> createState() => _ScannerTextFieldState();
}

class _ScannerTextFieldState extends State<_ScannerTextField> with WidgetsBindingObserver {
  bool _manualKeyboard = false;
  final FocusNode _manualTextFocus = FocusNode(
    debugLabel: 'n07-scanner-text-input',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.enabled) _armScannerInput();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _manualTextFocus.dispose();
    super.dispose();
  }

  bool _routeIsCurrent() {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    return route == null || route.isCurrent;
  }

  // iData đang hoạt động theo keyboard-wedge/IME: scanner cần một TextField
  // còn focus để nhận mã. Vì vậy KHÔNG chuyển focus sang Focus widget sau khi
  // scan xong; chỉ ẩn bàn phím mềm và giữ TextField focus ngầm liên tục.
  void _armScannerInput() {
    if (!mounted || !widget.enabled || !_routeIsCurrent()) return;
    if (_manualKeyboard) return;

    if (!_manualTextFocus.hasFocus && _manualTextFocus.canRequestFocus) {
      _manualTextFocus.requestFocus();
    }
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  void _armScannerInputWithRetries() {
    _armScannerInput();
    for (final delayMs in <int>[40, 100, 220, 450, 800]) {
      Future<void>.delayed(Duration(milliseconds: delayMs), () {
        if (!mounted || !widget.enabled || _manualKeyboard) return;
        _armScannerInput();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _manualKeyboard = false;
      _manualTextFocus.unfocus();
      widget.focusNode.unfocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      return;
    }

    if (state == AppLifecycleState.resumed && widget.enabled) {
      _manualKeyboard = false;
      // Sau sleep/foreground, iData có thể trả keyboard-wedge về chậm.
      // Request lại chính TextField nhiều nhịp để khôi phục input connection.
      _armScannerInputWithRetries();
    }
  }

  KeyEventResult _onHardwareKeyEvent(FocusNode node, KeyEvent event) {
    if (!widget.enabled || !_routeIsCurrent()) {
      return KeyEventResult.ignored;
    }

    // Khi TextField đang giữ focus (trạng thái bình thường của iData), để
    // EditableText xử lý key/IME tự nhiên. Handler này chỉ là fallback nếu
    // focus TextField chưa kịp hồi sau lifecycle/rebuild.
    if (_manualTextFocus.hasFocus) return KeyEventResult.ignored;
    if (_manualKeyboard) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    final logicalKey = event.logicalKey;
    if (logicalKey == LogicalKeyboardKey.enter ||
        logicalKey == LogicalKeyboardKey.numpadEnter ||
        logicalKey == LogicalKeyboardKey.tab) {
      final value = widget.controller.text;
      widget.onSubmitted(value);
      _armScannerInputWithRetries();
      return KeyEventResult.handled;
    }

    if (logicalKey == LogicalKeyboardKey.backspace) {
      final text = widget.controller.text;
      if (text.isNotEmpty) {
        final shortened = text.substring(0, text.length - 1);
        widget.controller.value = TextEditingValue(
          text: shortened,
          selection: TextSelection.collapsed(offset: shortened.length),
        );
      }
      return KeyEventResult.handled;
    }

    final character = event.character;
    if (character == null || character.isEmpty) {
      return KeyEventResult.handled;
    }
    if (character.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      return KeyEventResult.handled;
    }

    final next = '${widget.controller.text}$character';
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    return KeyEventResult.handled;
  }

  void _returnToScannerMode() {
    if (_manualKeyboard && mounted) {
      setState(() => _manualKeyboard = false);
    }
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    _armScannerInputWithRetries();
  }

  void _showSoftKeyboardFromTap() {
    if (!widget.enabled) return;
    if (!_manualKeyboard) {
      setState(() => _manualKeyboard = true);
    }
    if (!_manualTextFocus.hasFocus && _manualTextFocus.canRequestFocus) {
      _manualTextFocus.requestFocus();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.enabled || !_manualKeyboard) return;
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      Future<void>.delayed(const Duration(milliseconds: 240), () {
        if (!mounted || !_manualKeyboard || !widget.enabled) return;
        SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      });
    });
  }

  @override
  void didUpdateWidget(covariant _ScannerTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _manualKeyboard = false;
      _manualTextFocus.unfocus();
      widget.focusNode.unfocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } else if (!oldWidget.enabled && widget.enabled) {
      _armScannerInputWithRetries();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _onHardwareKeyEvent,
      canRequestFocus: widget.enabled,
      descendantsAreFocusable: true,
      child: TextField(
        controller: widget.controller,
        focusNode: _manualTextFocus,
        enabled: widget.enabled,
        autofocus: false,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.characters,
        textInputAction: TextInputAction.done,
        keyboardType: TextInputType.text,
        onTap: _showSoftKeyboardFromTap,
        onTapOutside: (_) => _returnToScannerMode(),
        onEditingComplete: () {},
        onSubmitted: (value) {
          // Cực quan trọng với iData: submit xong KHÔNG unfocus TextField.
          // Chỉ ẩn soft keyboard và request lại focus để mã kế tiếp bắn ngay.
          widget.onSubmitted(value);
          _returnToScannerMode();
        },
        decoration: widget.decoration,
      ),
    );
  }
}

Future<void> _vibrateScan() async {
  try {
    await HapticFeedback.vibrate();
  } catch (_) {
    // Một số thiết bị/emulator không có motor rung. Không để lỗi rung chặn nghiệp vụ.
  }
}

Future<void> _showDuplicateWarning(
  BuildContext context, {
  required String code,
  required String message,
}) async {
  try {
    await HapticFeedback.vibrate();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    await HapticFeedback.vibrate();
  } catch (_) {}

  if (!context.mounted) return;

  // Khóa ô nhập trong lúc cảnh báo đang mở để iData không bắn chồng mã phía sau dialog.
  FocusManager.instance.primaryFocus?.unfocus();
  await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: AlertDialog(
        icon: const Icon(
          Icons.warning_amber_rounded,
          color: Colors.red,
          size: 44,
        ),
        title: const Text(
          'CẢNH BÁO MÃ TRÙNG',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.red,
            fontWeight: FontWeight.w900,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              code,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Cảnh báo này không tự tắt. Bắt buộc bấm nút bên dưới để tiếp tục.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext),
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('ĐÓNG CẢNH BÁO'),
          ),
        ],
      ),
    ),
  );
}

class ContinuousScanFeedback {
  const ContinuousScanFeedback(
    this.success,
    this.message, {
    this.duplicate = false,
  });

  final bool success;
  final String message;
  final bool duplicate;
}

Future<void> _scanContinuous(
  BuildContext context, {
  required String title,
  required Future<ContinuousScanFeedback> Function(String code) onCode,
}) async {
  final controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    formats: const [BarcodeFormat.qrCode],
    autoZoom: true,
  );
  await Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => _ContinuousQrScannerPage(
        controller: controller,
        title: title,
        onCode: onCode,
      ),
    ),
  );
}

class _ContinuousQrScannerPage extends StatefulWidget {
  const _ContinuousQrScannerPage({
    required this.controller,
    required this.title,
    required this.onCode,
  });

  final MobileScannerController controller;
  final String title;
  final Future<ContinuousScanFeedback> Function(String code) onCode;

  @override
  State<_ContinuousQrScannerPage> createState() =>
      _ContinuousQrScannerPageState();
}

class _ContinuousQrScannerPageState
    extends State<_ContinuousQrScannerPage> {
  bool _processing = false;
  int _success = 0;
  int _failed = 0;
  String _lastCode = '';
  String _message = 'Đưa QR vào khung. Camera sẽ giữ nguyên để bắn liên tục.';
  bool _lastOk = true;
  DateTime? _lastDetectedAt;

  Future<void> _detect(BarcodeCapture capture) async {
    if (_processing) return;
    String value = '';
    for (final barcode in capture.barcodes) {
      if (barcode.format != BarcodeFormat.qrCode) continue;
      value = barcode.rawValue?.trim() ?? '';
      if (value.isNotEmpty) break;
    }
    if (value.isEmpty) return;

    final now = DateTime.now();
    if (value == _lastCode &&
        _lastDetectedAt != null &&
        now.difference(_lastDetectedAt!) < const Duration(milliseconds: 1600)) {
      return;
    }

    _processing = true;
    _lastCode = value;
    _lastDetectedAt = now;
    try {
      final result = await widget.onCode(value);
      if (!mounted) return;
      setState(() {
        _lastOk = result.success;
        _message = result.message;
        result.success ? _success++ : _failed++;
      });

      if (result.duplicate) {
        await _showDuplicateWarning(
          context,
          code: value,
          message: result.message,
        );
        if (!mounted) return;
        _lastDetectedAt = DateTime.now();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastOk = false;
        _failed++;
        _message = '$e';
      });
    } finally {
      _processing = false;
    }
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('XONG'),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: widget.controller,
            onDetect: _detect,
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 270,
                height: 220,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 3),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
          Positioned(
            left: 10,
            right: 10,
            bottom: 14,
            child: Card(
              color: Colors.black87,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '✓ $_success',
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(width: 18),
                        Text(
                          '✕ $_failed',
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _message,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _lastOk ? Colors.white : Colors.redAccent,
                        fontSize: 12,
                      ),
                    ),
                    if (_processing) ...[
                      const SizedBox(height: 5),
                      const LinearProgressIndicator(minHeight: 2),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<String?> _scanOneQr(BuildContext context) async {
  final controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
    autoZoom: true,
  );

  return Navigator.push<String>(
    context,
    MaterialPageRoute(
      builder: (_) => _QrScannerPage(controller: controller),
    ),
  );
}

class _QrScannerPage extends StatefulWidget {
  const _QrScannerPage({required this.controller});
  final MobileScannerController controller;

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> {
  bool _done = false;

  Future<void> _detect(BarcodeCapture capture) async {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      if (barcode.format != BarcodeFormat.qrCode) continue;
      final value = barcode.rawValue?.trim() ?? '';
      if (value.isEmpty) continue;
      _done = true;
      await widget.controller.stop();
      if (mounted) Navigator.pop(context, value);
      break;
    }
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QUÉT QR')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: widget.controller,
            onDetect: _detect,
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 285,
                height: 245,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 3),
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
          const Positioned(
            top: 18,
            left: 18,
            right: 18,
            child: Card(
              color: Colors.black87,
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Chỉ nhận QR. Barcode ngang sẽ bỏ qua.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<List<String>> _pickQrCodesFromAlbum(
  BuildContext context, {
  required bool multi,
}) async {
  final picker = ImagePicker();
  final List<XFile> images;
  if (multi) {
    images = await picker.pickMultiImage();
  } else {
    final image = await picker.pickImage(source: ImageSource.gallery);
    images = image == null ? [] : [image];
  }
  if (images.isEmpty) return const [];

  final controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  final codes = <String>[];
  final failed = <String>[];

  try {
    for (final image in images) {
      try {
        final capture = await controller
            .analyzeImage(image.path)
            .timeout(const Duration(seconds: 12));
        final local = <String>{};
        if (capture != null) {
          for (final barcode in capture.barcodes) {
            if (barcode.format != BarcodeFormat.qrCode) continue;
            final value = barcode.rawValue?.trim() ?? '';
            if (value.isNotEmpty) local.add(value);
          }
        }
        if (local.isEmpty) {
          failed.add(image.name);
        } else {
          codes.addAll(local);
        }
      } catch (_) {
        failed.add(image.name);
      }
    }
  } finally {
    controller.dispose();
  }

  if (context.mounted && failed.isNotEmpty) {
    _snack(
      context,
      'Không đọc được QR: ${failed.join(', ')}',
      error: true,
    );
  }
  return codes;
}

class _SyncStatusCard extends StatelessWidget {
  const _SyncStatusCard({
    required this.state,
    this.onRetry,
    this.onManualPendingTap,
  });

  final LocalSyncState state;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onManualPendingTap;

  Future<void> _showConflicts(BuildContext context) async {
    final rows = await LocalWarehouseStore.instance.listConflicts(limit: 20);
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('XUNG ĐỘT ĐỒNG BỘ'),
        content: SizedBox(
          width: double.maxFinite,
          child: rows.isEmpty
              ? const Text('Không còn xung đột.')
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    title: Text(
                      '${rows[i]['action']}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text('${rows[i]['message']}'),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Đóng'),
          ),
          FilledButton(
            onPressed: () async {
              await LocalWarehouseStore.instance.clearConflicts();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('ĐÃ XEM • XÓA CẢNH BÁO'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasConflict = state.conflicts > 0;
    final offline = !state.online;
    final manualOnly =
        state.manualPending > 0 && state.autoPending == 0;

    final Color color = hasConflict
        ? Colors.red
        : offline
            ? Colors.orange
            : state.syncing || state.autoPending > 0
                ? Colors.blue
                : manualOnly
                    ? Colors.deepPurple
                    : Colors.green;

    final IconData icon = hasConflict
        ? Icons.warning_amber_rounded
        : offline
            ? Icons.cloud_off
            : state.syncing || state.autoPending > 0
                ? Icons.sync
                : manualOnly
                    ? Icons.cloud_upload_outlined
                    : Icons.cloud_done;

    final String text;
    if (hasConflict) {
      text =
          '${state.conflicts} thao tác xung đột • ${state.pending} đang chờ';
    } else if (offline) {
      text = '${state.message.isNotEmpty ? state.message : 'OFFLINE'} • '
          '${state.manualPending} NHẬP/XUẤT chờ xác nhận';
    } else if (state.syncing) {
      text = 'Đang xử lý • ${state.pending} thao tác chờ';
    } else if (state.message.startsWith('LỖI')) {
      text = state.message;
    } else if (state.autoPending > 0) {
      text = '${state.autoPending} thao tác hệ thống chờ đồng bộ'
          '${state.manualPending > 0 ? ' • ${state.manualPending} NHẬP/XUẤT chờ xác nhận' : ''}';
    } else if (state.manualPending > 0) {
      text =
          '${state.manualPending} NHẬP/XUẤT chờ xác nhận • tự gửi Server sau 5 phút';
    } else {
      text = 'Đã đồng bộ • không có thao tác chờ';
    }

    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (state.manualPending > 0 && onManualPendingTap != null)
            Icon(
              Icons.chevron_right,
              color: color,
              size: 20,
            ),
        ],
      ),
    );

    if (hasConflict) {
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _showConflicts(context),
        child: content,
      );
    }

    // Manual NHẬP/XUẤT: Home card is the entry point to the queue.
    // Chạm để mở danh sách xác nhận. Nếu bỏ quên, timer 5 phút xử lý riêng.
    if (state.manualPending > 0 && onManualPendingTap != null) {
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: state.syncing
            ? null
            : () => unawaited(onManualPendingTap!()),
        child: content,
      );
    }

    if (offline ||
        state.autoPending > 0 ||
        state.message.startsWith('LỖI ĐỒNG BỘ')) {
      if (onRetry != null) {
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: state.syncing ? null : () => unawaited(onRetry!()),
          child: content,
        );
      }
    }

    return content;
  }
}


class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 105,
            child: Text(
              label,
              style: const TextStyle(color: Colors.black54),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.message,
    required this.color,
    required this.icon,
  });

  final String message;
  final MaterialColor color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color.shade700),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

void _snack(
  BuildContext context,
  String message, {
  bool error = false,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? Colors.red.shade700 : null,
    ),
  );
}
