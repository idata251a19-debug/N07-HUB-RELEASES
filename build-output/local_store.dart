import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';


const int _kAislesPerShelf = 6;
const int _kRowsPerAisle = 10;
const int _kLegacyAislesPerShelf = 3;
const int _kLegacyRowsPerAisle = 6;
const int _kCellsPerRow = 4;
const int _kBasePinsPerCell = 16;
const int _kPinsPerCell = 18;
const int _kExtraPinsPerCell = _kPinsPerCell - _kBasePinsPerCell;
const int _kLegacyPinsPerAisle =
    _kLegacyRowsPerAisle * _kCellsPerRow * _kBasePinsPerCell;
const int _kLegacyRackCapacity =
    _kLegacyAislesPerShelf * _kLegacyPinsPerAisle;
const int _kExtendedRowsSlots =
    _kLegacyAislesPerShelf *
    (_kRowsPerAisle - _kLegacyRowsPerAisle) *
    _kCellsPerRow *
    _kBasePinsPerCell;
const int _kBaseRackCapacity =
    _kAislesPerShelf * _kRowsPerAisle * _kCellsPerRow * _kBasePinsPerCell;
const int _kExtraRackSlots =
    _kAislesPerShelf * _kRowsPerAisle * _kCellsPerRow * _kExtraPinsPerCell;
const int _kRackCapacity = _kBaseRackCapacity + _kExtraRackSlots;

const String _kWarehouseVf = 'VF_E2W';
const String _kWarehouseAuto = 'AUTO_EV';
const int _kVfCellsPerAisle = 4;
const int _kAutoDefaultPositionsPerAisle = 4;
const int _kAutoMaxPositionsPerAisle = 6;

class _LocalLayoutConfig {
  const _LocalLayoutConfig({
    required this.aisles,
    required this.cells,
    required this.slotsPerCell,
  });

  final int aisles;
  final int cells;
  final int slotsPerCell;

  int get capacity => aisles * cells * slotsPerCell;
}


class LocalSyncState {
  const LocalSyncState({
    required this.online,
    required this.syncing,
    required this.pending,
    required this.manualPending,
    required this.conflicts,
    this.lastSync,
    this.message = '',
    this.authError = '',
  });

  final bool online;
  final bool syncing;
  final int pending;
  final int manualPending;
  final int conflicts;
  final DateTime? lastSync;
  final String message;
  final String authError;

  int get autoPending =>
      pending > manualPending ? pending - manualPending : 0;

  LocalSyncState copyWith({
    bool? online,
    bool? syncing,
    int? pending,
    int? manualPending,
    int? conflicts,
    DateTime? lastSync,
    String? message,
    String? authError,
  }) {
    return LocalSyncState(
      online: online ?? this.online,
      syncing: syncing ?? this.syncing,
      pending: pending ?? this.pending,
      manualPending: manualPending ?? this.manualPending,
      conflicts: conflicts ?? this.conflicts,
      lastSync: lastSync ?? this.lastSync,
      message: message ?? this.message,
      authError: authError ?? this.authError,
    );
  }
}

class CachedLogin {
  const CachedLogin({
    required this.valid,
    required this.user,
    required this.sessionToken,
  });

  final bool valid;
  final Map<String, dynamic> user;
  final String sessionToken;
}

class LocalWarehouseStore {
  LocalWarehouseStore._();
  static final LocalWarehouseStore instance = LocalWarehouseStore._();

  Database? _db;
  String _warehouseId = _kWarehouseVf;
  final Random _random = Random();

  String get warehouseId => _warehouseId;

  String _normalizeWarehouse(String value) {
    final clean = value.trim().toUpperCase();
    if (clean == _kWarehouseVf || clean == _kWarehouseAuto) return clean;
    throw ArgumentError.value(value, 'warehouseId', 'Kho không hợp lệ');
  }

  String get _databaseFileName => _warehouseId == _kWarehouseAuto
      ? 'n07_hub_auto_ev_v1.db'
      : 'n07_hub_offline_v4.db';

  Future<void> switchWarehouse(String warehouseId) async {
    final next = _normalizeWarehouse(warehouseId);
    if (next == _warehouseId && _db != null) return;
    final old = _db;
    _db = null;
    if (old != null) {
      try {
        await old.close();
      } catch (_) {}
    }
    _warehouseId = next;
    syncState.value = const LocalSyncState(
      online: true,
      syncing: false,
      pending: 0,
      manualPending: 0,
      conflicts: 0,
    );
    await db;
  }

  final ValueNotifier<LocalSyncState> syncState = ValueNotifier(
    const LocalSyncState(
      online: true,
      syncing: false,
      pending: 0,
      manualPending: 0,
      conflicts: 0,
    ),
  );

  Future<Database> get db async {
    if (_db != null) return _db!;
    final base = await getDatabasesPath();
    _db = await openDatabase(
      '$base/$_databaseFileName',
      version: 11,
      onCreate: (database, version) async {
        await database.execute('''
          CREATE TABLE locations(
            id TEXT PRIMARY KEY,
            capacity INTEGER NOT NULL DEFAULT 4320,
            updated_at TEXT NOT NULL DEFAULT ''
          )
        ''');
        await database.execute('''
          CREATE TABLE pins(
            code TEXT PRIMARY KEY,
            location TEXT NOT NULL,
            slot INTEGER NOT NULL,
            stored_at TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL DEFAULT '',
            device_id TEXT NOT NULL DEFAULT '',
            operator_id TEXT NOT NULL DEFAULT '',
            battery_type TEXT NOT NULL DEFAULT '',
            remote_slot_id TEXT NOT NULL DEFAULT ''
          )
        ''');
        await database.execute(
          'CREATE UNIQUE INDEX idx_pins_location_slot ON pins(location, slot)',
        );
        await database.execute(
          'CREATE INDEX idx_pins_remote_slot ON pins(remote_slot_id)',
        );
        await database.execute('''
          CREATE TABLE outbox(
            op_id TEXT PRIMARY KEY,
            action TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_ms INTEGER NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT NOT NULL DEFAULT ''
          )
        ''');
        await database.execute('''
          CREATE TABLE conflicts(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            op_id TEXT NOT NULL,
            action TEXT NOT NULL,
            message TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_ms INTEGER NOT NULL
          )
        ''');
        await database.execute('''
          CREATE TABLE local_history(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            pin_code TEXT NOT NULL,
            action TEXT NOT NULL,
            location TEXT NOT NULL,
            slot INTEGER NOT NULL DEFAULT 0,
            note TEXT NOT NULL DEFAULT '',
            device_id TEXT NOT NULL DEFAULT '',
            operator_id TEXT NOT NULL DEFAULT '',
            op_id TEXT NOT NULL DEFAULT '',
            battery_type TEXT NOT NULL DEFAULT '',
            server_id TEXT NOT NULL DEFAULT '',
            server_revision INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'LOCAL'
          )
        ''');
        await database.execute(
          "CREATE UNIQUE INDEX idx_local_history_server_id "
          "ON local_history(server_id) WHERE server_id<>''",
        );
        await database.execute(
          'CREATE INDEX idx_local_history_pin ON local_history(pin_code, id DESC)',
        );
        await database.execute(
          'CREATE INDEX idx_local_history_revision ON local_history(server_revision)',
        );
        await database.execute('''
          CREATE TABLE audits(
            session_id TEXT PRIMARY KEY,
            timestamp TEXT NOT NULL,
            location TEXT NOT NULL,
            expected INTEGER NOT NULL,
            scanned INTEGER NOT NULL,
            matched INTEGER NOT NULL,
            missing_count INTEGER NOT NULL,
            wrong_count INTEGER NOT NULL,
            unknown_count INTEGER NOT NULL,
            duplicate_scans INTEGER NOT NULL,
            details TEXT NOT NULL DEFAULT '',
            operator_id TEXT NOT NULL DEFAULT ''
          )
        ''');
        await database.execute('''
          CREATE TABLE users_cache(
            id TEXT PRIMARY KEY,
            password_hash TEXT NOT NULL DEFAULT '',
            session_token TEXT NOT NULL DEFAULT '',
            user_json TEXT NOT NULL,
            updated_ms INTEGER NOT NULL
          )
        ''');
        await database.execute('''
          CREATE TABLE meta(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await database.execute('''
          CREATE TABLE rack_labels(
            location TEXT NOT NULL,
            kind TEXT NOT NULL,
            aisle_no INTEGER NOT NULL DEFAULT 0,
            row_no INTEGER NOT NULL DEFAULT 0,
            cell_no INTEGER NOT NULL DEFAULT 0,
            label TEXT NOT NULL,
            updated_at TEXT NOT NULL DEFAULT '',
            PRIMARY KEY(location, kind, aisle_no, row_no, cell_no)
          )
        ''');
        await database.execute('''
          CREATE TABLE remote_slots(
            remote_slot_id TEXT PRIMARY KEY,
            location TEXT NOT NULL,
            local_slot INTEGER NOT NULL,
            aisle_code TEXT NOT NULL DEFAULT '',
            aisle_label TEXT NOT NULL DEFAULT '',
            shelf_code TEXT NOT NULL DEFAULT '',
            shelf_label TEXT NOT NULL DEFAULT '',
            level_code TEXT NOT NULL DEFAULT '',
            level_label TEXT NOT NULL DEFAULT '',
            slot_code TEXT NOT NULL DEFAULT '',
            slot_label TEXT NOT NULL DEFAULT '',
            sort_key INTEGER NOT NULL DEFAULT 0,
            active INTEGER NOT NULL DEFAULT 1
          )
        ''');
        await database.execute(
          'CREATE UNIQUE INDEX idx_remote_slots_legacy ON remote_slots(location, local_slot)',
        );
        await database.execute('''
          CREATE TABLE sync_log(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_ms INTEGER NOT NULL,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            reason TEXT NOT NULL DEFAULT '',
            rows_downloaded INTEGER NOT NULL DEFAULT 0,
            rows_uploaded INTEGER NOT NULL DEFAULT 0,
            revision_before INTEGER NOT NULL DEFAULT 0,
            revision_after INTEGER NOT NULL DEFAULT 0,
            full_bootstrap INTEGER NOT NULL DEFAULT 0,
            layout_reloaded INTEGER NOT NULL DEFAULT 0,
            sync_mode TEXT NOT NULL DEFAULT '',
            history_rows INTEGER NOT NULL DEFAULT 0,
            inventory_delta_rows INTEGER NOT NULL DEFAULT 0,
            removed_pin_rows INTEGER NOT NULL DEFAULT 0,
            slots_rows INTEGER NOT NULL DEFAULT 0,
            page_count INTEGER NOT NULL DEFAULT 0,
            response_bytes INTEGER NOT NULL DEFAULT 0,
            error TEXT NOT NULL DEFAULT ''
          )
        ''');
        // Không tạo Dãy giả trên cài đặt mới. Mỗi kho chỉ mở thao tác sau khi
        // đã nhận snapshot đầu tiên từ đúng Backend V25.
      },
      onUpgrade: (database, oldVersion, newVersion) async {
        await database.update(
          'locations',
          {'capacity': _kRackCapacity},
        );

        if (oldVersion < 2) {
          final defaults = ['01', '02', '03', '04'];
          final now = DateTime.now().toIso8601String();
          for (final id in defaults) {
            await database.insert(
              'locations',
              {'id': id, 'capacity': _kRackCapacity, 'updated_at': now},
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );
          }
        }
        if (oldVersion < 3) {
          await database.update('locations', {'capacity': _kRackCapacity});
        }
        if (oldVersion < 4) {
          await database.update('locations', {'capacity': _kRackCapacity});
          await database.execute('''
            CREATE TABLE IF NOT EXISTS rack_labels(
              location TEXT NOT NULL,
              kind TEXT NOT NULL,
              aisle_no INTEGER NOT NULL DEFAULT 0,
              row_no INTEGER NOT NULL DEFAULT 0,
              cell_no INTEGER NOT NULL DEFAULT 0,
              label TEXT NOT NULL,
              updated_at TEXT NOT NULL DEFAULT '',
              PRIMARY KEY(location, kind, aisle_no, row_no, cell_no)
            )
          ''');
        }
        if (oldVersion < 7) {
          try {
            await database.execute(
              "ALTER TABLE pins ADD COLUMN battery_type TEXT NOT NULL DEFAULT ''",
            );
          } catch (_) {}
          try {
            await database.execute(
              "ALTER TABLE local_history ADD COLUMN battery_type TEXT NOT NULL DEFAULT ''",
            );
          } catch (_) {}
        }
        if (oldVersion < 8) {
          for (final sql in <String>[
            "ALTER TABLE local_history ADD COLUMN server_id TEXT NOT NULL DEFAULT ''",
            'ALTER TABLE local_history ADD COLUMN server_revision INTEGER NOT NULL DEFAULT 0',
            "ALTER TABLE local_history ADD COLUMN source TEXT NOT NULL DEFAULT 'LOCAL'",
          ]) {
            try {
              await database.execute(sql);
            } catch (_) {}
          }
          try {
            await database.execute(
              "CREATE UNIQUE INDEX IF NOT EXISTS idx_local_history_server_id "
              "ON local_history(server_id) WHERE server_id<>''",
            );
          } catch (_) {}
          await database.execute(
            'CREATE INDEX IF NOT EXISTS idx_local_history_pin ON local_history(pin_code, id DESC)',
          );
          await database.execute(
            'CREATE INDEX IF NOT EXISTS idx_local_history_revision ON local_history(server_revision)',
          );
        }
        if (oldVersion < 9) {
          await database.execute('''
            CREATE TABLE IF NOT EXISTS remote_slots(
              remote_slot_id TEXT PRIMARY KEY,
              location TEXT NOT NULL,
              local_slot INTEGER NOT NULL,
              aisle_code TEXT NOT NULL DEFAULT '',
              aisle_label TEXT NOT NULL DEFAULT '',
              shelf_code TEXT NOT NULL DEFAULT '',
              shelf_label TEXT NOT NULL DEFAULT '',
              level_code TEXT NOT NULL DEFAULT '',
              level_label TEXT NOT NULL DEFAULT '',
              slot_code TEXT NOT NULL DEFAULT '',
              slot_label TEXT NOT NULL DEFAULT '',
              sort_key INTEGER NOT NULL DEFAULT 0,
              active INTEGER NOT NULL DEFAULT 1
            )
          ''');
          await database.execute(
            'CREATE UNIQUE INDEX IF NOT EXISTS idx_remote_slots_legacy ON remote_slots(location, local_slot)',
          );
          await database.execute('''
            CREATE TABLE IF NOT EXISTS sync_log(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              started_ms INTEGER NOT NULL,
              duration_ms INTEGER NOT NULL DEFAULT 0,
              reason TEXT NOT NULL DEFAULT '',
              rows_downloaded INTEGER NOT NULL DEFAULT 0,
              rows_uploaded INTEGER NOT NULL DEFAULT 0,
              revision_before INTEGER NOT NULL DEFAULT 0,
              revision_after INTEGER NOT NULL DEFAULT 0,
              full_bootstrap INTEGER NOT NULL DEFAULT 0,
              layout_reloaded INTEGER NOT NULL DEFAULT 0,
              sync_mode TEXT NOT NULL DEFAULT '',
              history_rows INTEGER NOT NULL DEFAULT 0,
              inventory_delta_rows INTEGER NOT NULL DEFAULT 0,
              removed_pin_rows INTEGER NOT NULL DEFAULT 0,
              slots_rows INTEGER NOT NULL DEFAULT 0,
              page_count INTEGER NOT NULL DEFAULT 0,
              response_bytes INTEGER NOT NULL DEFAULT 0,
              error TEXT NOT NULL DEFAULT ''
            )
          ''');
        }
        if (oldVersion < 10) {
          try {
            await database.execute(
              "ALTER TABLE pins ADD COLUMN remote_slot_id TEXT NOT NULL DEFAULT ''",
            );
          } catch (_) {}
          await database.execute(
            'CREATE INDEX IF NOT EXISTS idx_pins_remote_slot ON pins(remote_slot_id)',
          );
        }
        if (oldVersion < 11) {
          for (final sql in <String>[
            "ALTER TABLE sync_log ADD COLUMN sync_mode TEXT NOT NULL DEFAULT ''",
            'ALTER TABLE sync_log ADD COLUMN history_rows INTEGER NOT NULL DEFAULT 0',
            'ALTER TABLE sync_log ADD COLUMN inventory_delta_rows INTEGER NOT NULL DEFAULT 0',
            'ALTER TABLE sync_log ADD COLUMN removed_pin_rows INTEGER NOT NULL DEFAULT 0',
            'ALTER TABLE sync_log ADD COLUMN slots_rows INTEGER NOT NULL DEFAULT 0',
            'ALTER TABLE sync_log ADD COLUMN page_count INTEGER NOT NULL DEFAULT 0',
            'ALTER TABLE sync_log ADD COLUMN response_bytes INTEGER NOT NULL DEFAULT 0',
          ]) {
            try {
              await database.execute(sql);
            } catch (_) {}
          }
        }
      },
    );
    await refreshSyncState();
    return _db!;
  }

  Future<void> init({String warehouseId = _kWarehouseVf}) async {
    _warehouseId = _normalizeWarehouse(warehouseId);
    await db;
  }

  String _nowText() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(n.day)}/${two(n.month)}/${n.year} ${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
  }

  int _baseAisleFromPosition(int position) {
    if (position < 1) return 0;

    if (position <= _kLegacyRackCapacity) {
      return ((position - 1) ~/ _kLegacyPinsPerAisle) + 1;
    }

    final extendedRowsEnd = _kLegacyRackCapacity + _kExtendedRowsSlots;
    if (position <= extendedRowsEnd) {
      final offset = position - _kLegacyRackCapacity - 1;
      final pinsPerExtendedAisle =
          (_kRowsPerAisle - _kLegacyRowsPerAisle) *
          _kCellsPerRow *
          _kBasePinsPerCell;
      return (offset ~/ pinsPerExtendedAisle) + 1;
    }

    final offset = position - extendedRowsEnd - 1;
    final pinsPerFullAisle =
        _kRowsPerAisle * _kCellsPerRow * _kBasePinsPerCell;
    return _kLegacyAislesPerShelf + (offset ~/ pinsPerFullAisle) + 1;
  }

  int _baseRowFromPosition(int position) {
    if (position < 1) return 0;

    if (position <= _kLegacyRackCapacity) {
      final withinAisle = (position - 1) % _kLegacyPinsPerAisle;
      return (withinAisle ~/ (_kCellsPerRow * _kBasePinsPerCell)) + 1;
    }

    final extendedRowsEnd = _kLegacyRackCapacity + _kExtendedRowsSlots;
    if (position <= extendedRowsEnd) {
      final offset = position - _kLegacyRackCapacity - 1;
      final pinsPerExtendedAisle =
          (_kRowsPerAisle - _kLegacyRowsPerAisle) *
          _kCellsPerRow *
          _kBasePinsPerCell;
      final withinAisle = offset % pinsPerExtendedAisle;
      return _kLegacyRowsPerAisle +
          (withinAisle ~/ (_kCellsPerRow * _kBasePinsPerCell)) +
          1;
    }

    final offset = position - extendedRowsEnd - 1;
    final pinsPerFullAisle =
        _kRowsPerAisle * _kCellsPerRow * _kBasePinsPerCell;
    final withinAisle = offset % pinsPerFullAisle;
    return (withinAisle ~/ (_kCellsPerRow * _kBasePinsPerCell)) + 1;
  }

  int _baseCellFromPosition(int position) {
    if (position < 1) return 0;
    return ((position - 1) %
                (_kCellsPerRow * _kBasePinsPerCell) ~/
            _kBasePinsPerCell) +
        1;
  }

  int _basePinInCell(int position) {
    if (position < 1) return 0;
    return ((position - 1) % _kBasePinsPerCell) + 1;
  }

  int _baseSlotFromParts(int aisle, int row, int cell, int pinNo) {
    if (aisle <= _kLegacyAislesPerShelf &&
        row <= _kLegacyRowsPerAisle) {
      return (((aisle - 1) * _kLegacyRowsPerAisle + (row - 1)) *
                  _kCellsPerRow +
              (cell - 1)) *
          _kBasePinsPerCell +
          pinNo;
    }

    if (aisle <= _kLegacyAislesPerShelf) {
      final rowsBeyondLegacy = row - _kLegacyRowsPerAisle - 1;
      final pinsPerExtendedAisle =
          (_kRowsPerAisle - _kLegacyRowsPerAisle) *
          _kCellsPerRow *
          _kBasePinsPerCell;
      return _kLegacyRackCapacity +
          (aisle - 1) * pinsPerExtendedAisle +
          rowsBeyondLegacy * _kCellsPerRow * _kBasePinsPerCell +
          (cell - 1) * _kBasePinsPerCell +
          pinNo;
    }

    final extendedRowsEnd = _kLegacyRackCapacity + _kExtendedRowsSlots;
    final pinsPerFullAisle =
        _kRowsPerAisle * _kCellsPerRow * _kBasePinsPerCell;
    return extendedRowsEnd +
        (aisle - _kLegacyAislesPerShelf - 1) * pinsPerFullAisle +
        (row - 1) * _kCellsPerRow * _kBasePinsPerCell +
        (cell - 1) * _kBasePinsPerCell +
        pinNo;
  }

  int _extraCellOrdinal(int aisle, int row, int cell) =>
      ((aisle - 1) * _kRowsPerAisle + (row - 1)) * _kCellsPerRow +
      (cell - 1);

  int _aisleFromPosition(int position) {
    if (position < 1) return 0;
    if (position <= _kBaseRackCapacity) {
      return _baseAisleFromPosition(position);
    }
    final extra = position - _kBaseRackCapacity - 1;
    final cellOrdinal = extra ~/ _kExtraPinsPerCell;
    return (cellOrdinal ~/ (_kRowsPerAisle * _kCellsPerRow)) + 1;
  }

  int _rowFromPosition(int position) {
    if (position < 1) return 0;
    if (position <= _kBaseRackCapacity) {
      return _baseRowFromPosition(position);
    }
    final extra = position - _kBaseRackCapacity - 1;
    final cellOrdinal = extra ~/ _kExtraPinsPerCell;
    final withinAisle = cellOrdinal % (_kRowsPerAisle * _kCellsPerRow);
    return (withinAisle ~/ _kCellsPerRow) + 1;
  }

  int _cellFromPosition(int position) {
    if (position < 1) return 0;
    if (position <= _kBaseRackCapacity) {
      return _baseCellFromPosition(position);
    }
    final extra = position - _kBaseRackCapacity - 1;
    final cellOrdinal = extra ~/ _kExtraPinsPerCell;
    return (cellOrdinal % _kCellsPerRow) + 1;
  }

  int _pinInCell(int position) {
    if (position < 1) return 0;
    if (position <= _kBaseRackCapacity) {
      return _basePinInCell(position);
    }
    final extra = position - _kBaseRackCapacity - 1;
    return _kBasePinsPerCell + (extra % _kExtraPinsPerCell) + 1;
  }

  int _slotFromParts(int aisle, int row, int cell, int pinNo) {
    if (pinNo <= _kBasePinsPerCell) {
      return _baseSlotFromParts(aisle, row, cell, pinNo);
    }
    final ordinal = _extraCellOrdinal(aisle, row, cell);
    return _kBaseRackCapacity +
        ordinal * _kExtraPinsPerCell +
        (pinNo - _kBasePinsPerCell);
  }

  List<int> _cellSlotNumbers(int aisle, int row, int cell) =>
      List<int>.generate(
        _kPinsPerCell,
        (i) => _slotFromParts(aisle, row, cell, i + 1),
        growable: false,
      );

  Future<_LocalLayoutConfig> _layoutConfig(
    DatabaseExecutor executor,
    String location,
  ) async {
    final rows = await executor.query(
      'rack_labels',
      columns: ['kind', 'label'],
      where: 'location=? AND kind IN (?, ?, ?)',
      whereArgs: [location, 'SO_DAY', 'SO_O', 'SO_PIN_O'],
    );

    int read(String kind, int fallback) {
      for (final row in rows) {
        if ('${row['kind'] ?? ''}'.toUpperCase() == kind) {
          return int.tryParse('${row['label'] ?? ''}') ?? fallback;
        }
      }
      return fallback;
    }

    final aisles = read('SO_DAY', _kAislesPerShelf)
        .clamp(1, _kAislesPerShelf)
        .toInt();
    final cells = _warehouseId == _kWarehouseAuto
        ? read('SO_O', _kAutoDefaultPositionsPerAisle)
            .clamp(1, _kAutoMaxPositionsPerAisle)
            .toInt()
        : _kVfCellsPerAisle;
    final slots = read('SO_PIN_O', _kPinsPerCell)
        .clamp(1, _kPinsPerCell)
        .toInt();
    return _LocalLayoutConfig(
      aisles: aisles,
      cells: cells,
      slotsPerCell: slots,
    );
  }

  List<int> _allowedSlots(_LocalLayoutConfig config) {
    final result = <int>[];
    for (var aisle = 1; aisle <= config.aisles; aisle++) {
      for (var flat = 1; flat <= config.cells; flat++) {
        final row = ((flat - 1) ~/ _kCellsPerRow) + 1;
        final cell = ((flat - 1) % _kCellsPerRow) + 1;
        for (var pin = 1; pin <= config.slotsPerCell; pin++) {
          result.add(_slotFromParts(aisle, row, cell, pin));
        }
      }
    }
    return result;
  }

  bool _slotAllowed(int slot, _LocalLayoutConfig config) {
    if (slot < 1 || slot > _kRackCapacity) return false;
    final aisle = _aisleFromPosition(slot);
    final flatCell =
        ((_rowFromPosition(slot) - 1) * _kCellsPerRow) +
        _cellFromPosition(slot);
    return aisle >= 1 &&
        aisle <= config.aisles &&
        flatCell >= 1 &&
        flatCell <= config.cells &&
        _pinInCell(slot) <= config.slotsPerCell;
  }


  String _positionText(int position) {
    if (position < 1) return '-';
    final row = _rowFromPosition(position);
    final cell = _cellFromPosition(position);
    final flatCell = ((row - 1) * _kCellsPerRow) + cell;
    final term = _warehouseId == _kWarehouseAuto ? 'Vị trí' : 'Ô';
    return 'Kệ ${_aisleFromPosition(position)} - $term $flatCell - '
        'Slot ${_pinInCell(position).toString().padLeft(2, '0')}';
  }

  String _opId(String deviceId) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final rnd = _random.nextInt(1 << 31);
    return '$deviceId-$stamp-$rnd';
  }

  String _passwordHash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  Future<void> setMeta(String key, String value) async {
    final database = await db;
    await database.insert(
      'meta',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> getMeta(String key) async {
    final database = await db;
    final rows = await database.query('meta', where: 'key=?', whereArgs: [key]);
    return rows.isEmpty ? '' : '${rows.first['value'] ?? ''}';
  }

  Future<bool> hasSnapshot() async {
    return (await getMeta('last_snapshot_ms')).isNotEmpty;
  }

  Future<void> cacheLogin({
    required String id,
    required String password,
    required String sessionToken,
    required Map<String, dynamic> user,
  }) async {
    final database = await db;
    await database.insert(
      'users_cache',
      {
        'id': id.toUpperCase(),
        'password_hash': _passwordHash(password),
        'session_token': sessionToken,
        'user_json': jsonEncode(user),
        'updated_ms': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> refreshQueuedActorToken({
    required String operatorId,
    required String sessionToken,
  }) async {
    if (operatorId.trim().isEmpty || sessionToken.trim().isEmpty) return;
    final database = await db;
    final rows = await database.query('outbox', columns: ['op_id', 'payload']);
    final batch = database.batch();
    for (final row in rows) {
      try {
        final payload = Map<String, dynamic>.from(
          jsonDecode('${row['payload'] ?? '{}'}') as Map,
        );
        final actor = '${payload['_actorId'] ?? ''}'.toUpperCase();
        if (actor != operatorId.toUpperCase()) continue;
        payload['_actorSessionToken'] = sessionToken;
        batch.update(
          'outbox',
          {'payload': jsonEncode(payload)},
          where: 'op_id=?',
          whereArgs: ['${row['op_id']}'],
        );
      } catch (_) {}
    }
    await batch.commit(noResult: true);
  }

  Future<void> cacheUser(
    Map<String, dynamic> user, {
    String? sessionToken,
  }) async {
    final id = '${user['id'] ?? ''}'.toUpperCase();
    if (id.isEmpty) return;
    final database = await db;
    final rows = await database.query(
      'users_cache',
      where: 'id=?',
      whereArgs: [id],
      limit: 1,
    );
    final old = rows.isEmpty ? const <String, Object?>{} : rows.first;
    await database.insert(
      'users_cache',
      {
        'id': id,
        'password_hash': '${old['password_hash'] ?? ''}',
        'session_token': sessionToken ?? '${old['session_token'] ?? ''}',
        'user_json': jsonEncode(user),
        'updated_ms': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateCachedPassword(String id, String newPassword) async {
    final database = await db;
    await database.update(
      'users_cache',
      {
        'password_hash': _passwordHash(newPassword),
        'updated_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id=?',
      whereArgs: [id.toUpperCase()],
    );
  }

  Future<CachedLogin?> offlineLogin(String id, String password) async {
    final database = await db;
    final rows = await database.query(
      'users_cache',
      where: 'id=?',
      whereArgs: [id.toUpperCase()],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    if ('${row['password_hash'] ?? ''}' != _passwordHash(password)) return null;
    final user = Map<String, dynamic>.from(
      jsonDecode('${row['user_json'] ?? '{}'}') as Map,
    );
    if (user['active'] == false) return null;
    return CachedLogin(
      valid: true,
      user: user,
      sessionToken: '${row['session_token'] ?? ''}',
    );
  }

  Future<Map<String, dynamic>?> cachedUser(String id) async {
    final database = await db;
    final rows = await database.query(
      'users_cache',
      where: 'id=?',
      whereArgs: [id.toUpperCase()],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(
        jsonDecode('${rows.first['user_json']}') as Map,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> applySnapshot(Map<String, dynamic> snapshot) async {
    final database = await db;
    final locations = (snapshot['locations'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final pins = (snapshot['pins'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final labels = (snapshot['labels'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    await database.transaction((txn) async {
      await txn.delete('pins');
      await txn.delete('locations');
      await txn.delete('rack_labels');
      for (final item in locations) {
        final id = '${item['location'] ?? ''}'.trim();
        if (id.isEmpty) continue;
        await txn.insert(
          'locations',
          {
            'id': id,
            'capacity': (item['capacity'] as num?)?.toInt() ?? _kRackCapacity,
            'updated_at': '${item['updatedAt'] ?? ''}',
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final item in pins) {
        final code = '${item['code'] ?? ''}'.trim();
        final location = '${item['location'] ?? ''}'.trim();
        final slot = int.tryParse('${item['slot'] ?? ''}') ?? 0;
        if (code.isEmpty || location.isEmpty || slot < 1 || slot > _kRackCapacity) continue;
        await txn.insert(
          'pins',
          {
            'code': code,
            'location': location,
            'slot': slot,
            'stored_at': '${item['storedAt'] ?? ''}',
            'updated_at': '${item['updatedAt'] ?? ''}',
            'device_id': '${item['deviceId'] ?? ''}',
            'operator_id': '${item['operatorId'] ?? ''}',
            'battery_type': '${item['pinType'] ?? item['batteryType'] ?? ''}',
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final item in labels) {
        final location = '${item['location'] ?? ''}'.trim();
        final kind = '${item['kind'] ?? ''}'.trim().toUpperCase();
        final aisle = int.tryParse('${item['aisle'] ?? 0}') ?? 0;
        final row = int.tryParse('${item['row'] ?? 0}') ?? 0;
        final cell = int.tryParse('${item['cell'] ?? 0}') ?? 0;
        final label = '${item['label'] ?? ''}'.trim();
        if (location.isEmpty || kind.isEmpty || label.isEmpty) continue;
        await txn.insert(
          'rack_labels',
          {
            'location': location,
            'kind': kind,
            'aisle_no': aisle,
            'row_no': row,
            'cell_no': cell,
            'label': label,
            'updated_at': '${item['updatedAt'] ?? ''}',
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    final pinTypes = (snapshot['pinTypes'] as List<dynamic>? ?? const [])
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    await setMeta('pin_types_json', jsonEncode(pinTypes));
    await setMeta('last_snapshot_ms', '${DateTime.now().millisecondsSinceEpoch}');
  }

  Future<Map<String, dynamic>> localSummary() async {
    final database = await db;
    final rows = await database.rawQuery('''
      SELECT l.id AS location, COUNT(p.code) AS occupied
      FROM locations l
      LEFT JOIN pins p ON p.location=l.id
      GROUP BY l.id
    ''');

    var totalPins = 0;
    var totalCapacity = 0;
    var fullLocations = 0;
    for (final row in rows) {
      final location = '${row['location'] ?? ''}';
      final occupied = (row['occupied'] as num?)?.toInt() ?? 0;
      final config = await _layoutConfig(database, location);
      totalPins += occupied;
      totalCapacity += config.capacity;
      if (occupied >= config.capacity) fullLocations++;
    }

    return {
      'totalPins': totalPins,
      'totalLocations': rows.length,
      'fullLocations': fullLocations,
      'emptySlots': max(0, totalCapacity - totalPins),
    };
  }

  Future<List<Map<String, dynamic>>> listLocations() async {
    final database = await db;
    final rows = await database.rawQuery('''
      SELECT l.id AS location, COUNT(p.code) AS occupied
      FROM locations l
      LEFT JOIN pins p ON p.location=l.id
      GROUP BY l.id
      ORDER BY CAST(l.id AS INTEGER), l.id
    ''');
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final location = '${row['location'] ?? ''}';
      final config = await _layoutConfig(database, location);
      result.add({
        ...row,
        'capacity': config.capacity,
      });
    }
    return result;
  }

  Future<Map<String, dynamic>?> getLocation(String location) async {
    final database = await db;
    final exists = await database.query(
      'locations',
      where: 'id=?',
      whereArgs: [location],
      limit: 1,
    );
    if (exists.isEmpty) return null;
    final rows = await database.query(
      'pins',
      where: 'location=?',
      whereArgs: [location],
      orderBy: 'slot ASC',
    );
    final bySlot = <int, Map<String, Object?>>{};
    for (final row in rows) {
      bySlot[(row['slot'] as num).toInt()] = row;
    }
    final config = await _layoutConfig(database, location);
    final slots = <Map<String, dynamic>>[];
    for (final i in _allowedSlots(config)) {
      final row = bySlot[i];
      slots.add({
        'slot': i,
        'pinCode': row?['code'],
        'storedAt': row?['stored_at'],
      });
    }
    final labelRows = await database.query(
      'rack_labels',
      where: 'location=?',
      whereArgs: [location],
    );
    return {
      'location': location,
      'occupied': rows.length,
      'slots': slots,
      'labels': labelRows.map((r) => {
        'kind': '${r['kind'] ?? ''}',
        'aisle': (r['aisle_no'] as num?)?.toInt() ?? 0,
        'row': (r['row_no'] as num?)?.toInt() ?? 0,
        'cell': (r['cell_no'] as num?)?.toInt() ?? 0,
        'label': '${r['label'] ?? ''}',
      }).toList(),
    };
  }

  Future<Map<String, String>> _positionLabels(
    Database database,
    String location,
    int slot,
  ) async {
    final aisle = _aisleFromPosition(slot);
    final row = _rowFromPosition(slot);
    final cell = _cellFromPosition(slot);
    final rows = await database.query(
      'rack_labels',
      where: 'location=?',
      whereArgs: [location],
    );

    String find(String kind, int a, int r, int c, String fallback) {
      for (final item in rows) {
        if ('${item['kind'] ?? ''}'.toUpperCase() == kind &&
            (item['aisle_no'] as num?)?.toInt() == a &&
            (item['row_no'] as num?)?.toInt() == r &&
            (item['cell_no'] as num?)?.toInt() == c) {
          final label = '${item['label'] ?? ''}'.trim();
          if (label.isNotEmpty) return label;
        }
      }
      return fallback;
    }

    final flatCell = ((row - 1) * _kCellsPerRow) + cell;
    final term = _warehouseId == _kWarehouseAuto ? 'Vị trí' : 'Ô';
    return {
      'aisleName': find('DAY', aisle, 0, 0, 'Kệ $aisle'),
      'rowName': '',
      'cellName': find('O', aisle, row, cell, '$term $flatCell'),
    };
  }

  Future<Map<String, dynamic>> searchPin(String code) async {
    final database = await db;
    final rows = await database.query(
      'pins',
      where: 'code=?',
      whereArgs: [code],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final row = rows.first;
      final location = '${row['location']}';
      final slot = (row['slot'] as num?)?.toInt() ?? 0;
      final labels = await _positionLabels(database, location, slot);
      return {
        'found': true,
        'active': true,
        'code': code,
        'location': location,
        'slot': slot,
        'storedAt': '${row['stored_at'] ?? ''}',
        'exportedAt': '',
        'pinType': '${row['battery_type'] ?? ''}',
        ...labels,
      };
    }

    final history = await database.query(
      'local_history',
      where: 'pin_code=? AND action IN (?, ?)',
      whereArgs: [code, 'XUAT', 'THAY_XUAT'],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (history.isNotEmpty) {
      final row = history.first;
      final location = '${row['location']}';
      final slot = (row['slot'] as num?)?.toInt() ?? 0;
      final labels = await _positionLabels(database, location, slot);
      return {
        'found': true,
        'active': false,
        'code': code,
        'location': location,
        'slot': slot,
        'storedAt': '',
        'exportedAt': '${row['timestamp'] ?? ''}',
        'pinType': '${row['battery_type'] ?? ''}',
        ...labels,
      };
    }
    return {
      'found': false,
      'active': false,
      'code': code,
      'location': '',
      'slot': 0,
      'storedAt': '',
      'exportedAt': '',
      'pinType': '',
    };
  }

  Future<Map<String, dynamic>> importPinToCell({
    required String location,
    required int aisle,
    required int row,
    required int cell,
    required String code,
    required String deviceId,
    required String operatorId,
    required String sessionToken,
    String pinType = '',
  }) async {
    if (aisle < 1 || aisle > _kAislesPerShelf ||
        row < 1 || row > _kRowsPerAisle ||
        cell < 1 || cell > _kCellsPerRow) {
      final term = _warehouseId == _kWarehouseAuto ? 'Vị trí' : 'Ô';
      return {
        'ok': false,
        'code': 'bad_cell',
        'message': 'Dãy / Kệ / $term không hợp lệ.',
      };
    }

    final database = await db;
    final opId = _opId(deviceId);
    final now = _nowText();
    return database.transaction((txn) async {
      final loc = await txn.query(
        'locations',
        where: 'id=?',
        whereArgs: [location],
        limit: 1,
      );
      if (loc.isEmpty) {
        return {
          'ok': false,
          'code': 'not_found',
          'message': 'Không tìm thấy Dãy số $location.',
        };
      }

      final config = await _layoutConfig(txn, location);
      final flatCell = ((row - 1) * _kCellsPerRow) + cell;
      final term = _warehouseId == _kWarehouseAuto ? 'Vị trí' : 'Ô';
      if (aisle > config.aisles || flatCell > config.cells) {
        return {
          'ok': false,
          'code': 'bad_cell',
          'message': '$term nằm ngoài cấu hình của Dãy.',
        };
      }

      final dup = await txn.query(
        'pins',
        where: 'code=?',
        whereArgs: [code],
        limit: 1,
      );
      if (dup.isNotEmpty) {
        final d = dup.first;
        return {
          'ok': false,
          'code': 'duplicate',
          'message':
              'MÃ ĐÃ TỒN TẠI - Dãy số ${d['location']} - ${_positionText((d['slot'] as num).toInt())}',
          'location': '${d['location']}',
          'slot': (d['slot'] as num?)?.toInt() ?? 0,
        };
      }

      final cellSlots = _cellSlotNumbers(aisle, row, cell)
          .take(config.slotsPerCell)
          .toList(growable: false);
      final placeholders = List.filled(cellSlots.length, '?').join(',');
      final occupiedRows = await txn.rawQuery(
        'SELECT slot FROM pins WHERE location=? AND slot IN ($placeholders)',
        [location, ...cellSlots],
      );
      final occupied =
          occupiedRows.map((e) => (e['slot'] as num).toInt()).toSet();

      int? slot;
      for (final candidate in cellSlots) {
        if (!occupied.contains(candidate)) {
          slot = candidate;
          break;
        }
      }
      if (slot == null) {
        return {
          'ok': false,
          'code': 'cell_full',
          'message': '$term đã đầy ${config.slotsPerCell}/'
              '${config.slotsPerCell} pin. Hãy chọn $term khác.',
        };
      }

      await txn.insert('pins', {
        'code': code,
        'location': location,
        'slot': slot,
        'stored_at': now,
        'updated_at': now,
        'device_id': deviceId,
        'operator_id': operatorId,
        'battery_type': pinType.trim(),
      });

      await _queueInTxn(txn, opId, 'importPinToCell', {
        '_actorId': operatorId,
        '_actorSessionToken': sessionToken,
        '_actorDeviceId': deviceId,
        'location': location,
        'aisle': aisle,
        'row': row,
        'cell': cell,
        'preferredSlot': slot,
        'code': code,
        'pinType': pinType.trim(),
        'clientTime': now,
      });

      await _historyInTxn(
        txn,
        timestamp: now,
        pinCode: code,
        action: 'NHAP',
        location: location,
        slot: slot,
        note:
            'Nhập pin vào ${_positionText(slot)} trên máy${syncState.value.online ? '' : ' (OFFLINE)'}',
        deviceId: deviceId,
        operatorId: operatorId,
        opId: opId,
        pinType: pinType.trim(),
      );

      return {
        'ok': true,
        'code': code,
        'location': location,
        'slot': slot,
        'cellFull': occupied.length + 1 >= config.slotsPerCell,
        'queued': true,
      };
    });
  }

  Future<Map<String, dynamic>> importPin({
    required String location,
    required String code,
    required String deviceId,
    required String operatorId,
    required String sessionToken,
    String pinType = '',
    int? exactSlot,
  }) async {
    final database = await db;
    final opId = _opId(deviceId);
    final now = _nowText();
    return database.transaction((txn) async {
      final loc = await txn.query(
        'locations',
        where: 'id=?',
        whereArgs: [location],
        limit: 1,
      );
      if (loc.isEmpty) {
        return {'ok': false, 'code': 'not_found', 'message': 'Không tìm thấy Dãy số $location.'};
      }
      final config = await _layoutConfig(txn, location);
      final dup = await txn.query('pins', where: 'code=?', whereArgs: [code], limit: 1);
      if (dup.isNotEmpty) {
        final row = dup.first;
        return {
          'ok': false,
          'code': 'duplicate',
          'message': 'MÃ ĐÃ TỒN TẠI - Dãy số ${row['location']} - ${_positionText((row['slot'] as num).toInt())}',
          'location': '${row['location']}',
          'slot': (row['slot'] as num?)?.toInt() ?? 0,
        };
      }

      int? slot = exactSlot;
      if (slot != null) {
        if (!_slotAllowed(slot, config)) {
          return {
            'ok': false,
            'code': 'bad_slot',
            'message': 'Vị trí nằm ngoài cấu hình của Dãy.',
          };
        }
        final occupied = await txn.query(
          'pins',
          where: 'location=? AND slot=?',
          whereArgs: [location, slot],
          limit: 1,
        );
        if (occupied.isNotEmpty) {
          return {
            'ok': false,
            'code': 'occupied',
            'message': '${_positionText(slot)} đang có pin ${occupied.first['code']}.',
          };
        }
      } else {
        final occupiedRows = await txn.query(
          'pins',
          columns: ['slot'],
          where: 'location=?',
          whereArgs: [location],
        );
        final occupied = occupiedRows.map((e) => (e['slot'] as num).toInt()).toSet();
        for (final candidate in _allowedSlots(config)) {
          if (!occupied.contains(candidate)) {
            slot = candidate;
            break;
          }
        }
        if (slot == null) {
          return {
            'ok': false,
            'code': 'full',
            'message': 'Dãy số $location đã đầy '
                '${config.capacity}/${config.capacity}.',
          };
        }
      }

      await txn.insert('pins', {
        'code': code,
        'location': location,
        'slot': slot,
        'stored_at': now,
        'updated_at': now,
        'device_id': deviceId,
        'operator_id': operatorId,
        'battery_type': pinType.trim(),
      });
      await _queueInTxn(txn, opId, 'importPinAtSlot', {
        '_actorId': operatorId,
        '_actorSessionToken': sessionToken,
        '_actorDeviceId': deviceId,
        'location': location,
        'code': code,
        'slot': slot,
        'pinType': pinType.trim(),
        'clientTime': now,
      });
      await _historyInTxn(
        txn,
        timestamp: now,
        pinCode: code,
        action: 'NHAP',
        location: location,
        slot: slot,
        note: 'Nhập pin trên máy${syncState.value.online ? '' : ' (OFFLINE)'}',
        deviceId: deviceId,
        operatorId: operatorId,
        opId: opId,
        pinType: pinType.trim(),
      );
      final countRows = await txn.rawQuery(
        'SELECT COUNT(*) AS c FROM pins WHERE location=?',
        [location],
      );
      final occupiedAfter = (countRows.first['c'] as num?)?.toInt() ?? 0;
      return {
        'ok': true,
        'code': code,
        'location': location,
        'slot': slot,
        'full': occupiedAfter >= config.capacity,
        'queued': true,
      };
    });
  }

  Future<Map<String, dynamic>> exportPin({
    required String code,
    required String deviceId,
    required String operatorId,
    required String sessionToken,
  }) async {
    final database = await db;
    final opId = _opId(deviceId);
    final now = _nowText();
    return database.transaction((txn) async {
      final rows = await txn.query('pins', where: 'code=?', whereArgs: [code], limit: 1);
      if (rows.isEmpty) {
        return {'ok': false, 'code': 'not_found', 'message': 'Pin không còn trong tồn trên máy.'};
      }
      final row = rows.first;
      final location = '${row['location']}';
      final slot = (row['slot'] as num?)?.toInt() ?? 0;
      final pinType = '${row['battery_type'] ?? ''}';
      await txn.delete('pins', where: 'code=?', whereArgs: [code]);
      await _queueInTxn(txn, opId, 'exportPin', {
        '_actorId': operatorId,
        '_actorSessionToken': sessionToken,
        '_actorDeviceId': deviceId,
        'code': code,
        'expectedLocation': location,
        'expectedSlot': slot,
        'originalStoredAt': '${row['stored_at'] ?? ''}',
        'pinType': pinType,
        'clientTime': now,
      });
      await _historyInTxn(
        txn,
        timestamp: now,
        pinCode: code,
        action: 'XUAT',
        location: location,
        slot: slot,
        note: 'Xuất pin trên máy${syncState.value.online ? '' : ' (OFFLINE)'}',
        deviceId: deviceId,
        operatorId: operatorId,
        opId: opId,
        pinType: pinType,
      );
      return {
        'ok': true,
        'code': code,
        'location': location,
        'slot': slot,
        'pinType': pinType,
        'queued': true,
      };
    });
  }

  Future<Map<String, dynamic>> replacePin({
    required String location,
    required int slot,
    required String newCode,
    required String deviceId,
    required String operatorId,
    required String sessionToken,
  }) async {
    final database = await db;
    final opId = _opId(deviceId);
    final now = _nowText();
    return database.transaction((txn) async {
      final duplicate = await txn.query(
        'pins',
        where: 'code=?',
        whereArgs: [newCode],
        limit: 1,
      );
      if (duplicate.isNotEmpty) {
        final d = duplicate.first;
        return {
          'ok': false,
          'code': 'duplicate',
          'message': 'MÃ ĐÃ TỒN TẠI - Dãy số ${d['location']} - ${_positionText((d['slot'] as num).toInt())}',
          'location': '${d['location']}',
          'slot': (d['slot'] as num?)?.toInt() ?? 0,
        };
      }
      final oldRows = await txn.query(
        'pins',
        where: 'location=? AND slot=?',
        whereArgs: [location, slot],
        limit: 1,
      );
      final expectedOldCode =
          oldRows.isEmpty ? '' : '${oldRows.first['code']}';
      if (oldRows.isNotEmpty) {
        final oldCode = expectedOldCode;
        await txn.delete('pins', where: 'code=?', whereArgs: [oldCode]);
        await _historyInTxn(
          txn,
          timestamp: now,
          pinCode: oldCode,
          action: 'THAY_XUAT',
          location: location,
          slot: slot,
          note: 'Thay pin - xuất pin cũ trên máy',
          deviceId: deviceId,
          operatorId: operatorId,
          opId: opId,
        );
      }
      await txn.insert('pins', {
        'code': newCode,
        'location': location,
        'slot': slot,
        'stored_at': now,
        'updated_at': now,
        'device_id': deviceId,
        'operator_id': operatorId,
      });
      await _queueInTxn(txn, opId, 'replacePin', {
        '_actorId': operatorId,
        '_actorSessionToken': sessionToken,
        '_actorDeviceId': deviceId,
        'location': location,
        'slot': slot,
        'newCode': newCode,
        'expectedOldCode': expectedOldCode,
        'clientTime': now,
      });
      await _historyInTxn(
        txn,
        timestamp: now,
        pinCode: newCode,
        action: 'THAY_NHAP',
        location: location,
        slot: slot,
        note: 'Thay pin - nhập pin mới trên máy',
        deviceId: deviceId,
        operatorId: operatorId,
        opId: opId,
      );
      return {
        'ok': true,
        'location': location,
        'slot': slot,
        'full': false,
        'queued': true,
      };
    });
  }

  Future<void> applyConfirmedImport({
    required String code,
    required String location,
    required int slot,
    required String pinType,
    required String deviceId,
    required String operatorId,
  }) async {
    final database = await db;
    final now = _nowText();
    await database.transaction((txn) async {
      await txn.delete('pins', where: 'code=?', whereArgs: [code]);
      await txn.delete('pins', where: 'location=? AND slot=?', whereArgs: [location, slot]);
      await txn.insert('pins', {
        'code': code,
        'location': location,
        'slot': slot,
        'stored_at': now,
        'updated_at': now,
        'device_id': deviceId,
        'operator_id': operatorId,
        'battery_type': pinType.trim(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _historyInTxn(
        txn,
        timestamp: now,
        pinCode: code,
        action: 'NHAP',
        location: location,
        slot: slot,
        note: 'Đã nhập và xác nhận Supabase',
        deviceId: deviceId,
        operatorId: operatorId,
        opId: 'SERVER-${DateTime.now().microsecondsSinceEpoch}',
        pinType: pinType,
      );
    });
    await refreshSyncState(online: true, message: 'Đã đồng bộ Supabase');
  }

  Future<void> applyConfirmedExport({
    required String code,
    required String location,
    required int slot,
    required String pinType,
    required String deviceId,
    required String operatorId,
  }) async {
    final database = await db;
    final now = _nowText();
    await database.transaction((txn) async {
      await txn.delete('pins', where: 'code=?', whereArgs: [code]);
      await _historyInTxn(
        txn,
        timestamp: now,
        pinCode: code,
        action: 'XUAT',
        location: location,
        slot: slot,
        note: 'Đã xuất và xác nhận Supabase',
        deviceId: deviceId,
        operatorId: operatorId,
        opId: 'SERVER-${DateTime.now().microsecondsSinceEpoch}',
        pinType: pinType,
      );
    });
    await refreshSyncState(online: true, message: 'Đã đồng bộ Supabase');
  }

  Future<void> applyConfirmedReplace({
    required String oldCode,
    required String newCode,
    required String location,
    required int slot,
    required String deviceId,
    required String operatorId,
  }) async {
    final database = await db;
    final now = _nowText();
    await database.transaction((txn) async {
      String pinType = '';
      final oldRows = await txn.query('pins', where: 'location=? AND slot=?', whereArgs: [location, slot], limit: 1);
      if (oldRows.isNotEmpty) pinType = '${oldRows.first['battery_type'] ?? ''}';
      if (oldCode.trim().isNotEmpty) {
        await txn.delete('pins', where: 'code=?', whereArgs: [oldCode]);
        await _historyInTxn(
          txn,
          timestamp: now,
          pinCode: oldCode,
          action: 'THAY_XUAT',
          location: location,
          slot: slot,
          note: 'Thay PIN - xuất PIN cũ đã xác nhận Supabase',
          deviceId: deviceId,
          operatorId: operatorId,
          opId: 'SERVER-${DateTime.now().microsecondsSinceEpoch}-O',
          pinType: pinType,
        );
      } else {
        await txn.delete('pins', where: 'location=? AND slot=?', whereArgs: [location, slot]);
      }
      await txn.delete('pins', where: 'code=?', whereArgs: [newCode]);
      await txn.insert('pins', {
        'code': newCode,
        'location': location,
        'slot': slot,
        'stored_at': now,
        'updated_at': now,
        'device_id': deviceId,
        'operator_id': operatorId,
        'battery_type': pinType,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _historyInTxn(
        txn,
        timestamp: now,
        pinCode: newCode,
        action: 'THAY_NHAP',
        location: location,
        slot: slot,
        note: 'Thay PIN - nhập PIN mới đã xác nhận Supabase',
        deviceId: deviceId,
        operatorId: operatorId,
        opId: 'SERVER-${DateTime.now().microsecondsSinceEpoch}-N',
        pinType: pinType,
      );
    });
    await refreshSyncState(online: true, message: 'Đã đồng bộ Supabase');
  }

  Future<void> applyConfirmedAudit({
    required String sessionId,
    required String location,
    required List<String> scannedCodes,
    required int expected,
    required int matched,
    required List<String> missing,
    required List<String> wrongLocation,
    required List<String> unknown,
    required int duplicateScans,
    required String operatorId,
  }) async {
    final database = await db;
    final now = _nowText();
    await database.transaction((txn) async {
      await txn.insert('audits', {
        'session_id': sessionId,
        'timestamp': now,
        'location': location,
        'expected': expected,
        'scanned': scannedCodes.length,
        'matched': matched,
        'missing_count': missing.length,
        'wrong_count': wrongLocation.length,
        'unknown_count': unknown.length,
        'duplicate_scans': duplicateScans,
        'details': jsonEncode({'missing': missing, 'wrongLocation': wrongLocation, 'unknown': unknown}),
        'operator_id': operatorId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _historyInTxn(
        txn,
        timestamp: now,
        pinCode: '',
        action: 'KIEM_KE',
        location: location,
        slot: 0,
        note: 'Kiểm kê đã xác nhận Supabase • khớp $matched • thiếu ${missing.length}',
        deviceId: 'ANDROID',
        operatorId: operatorId,
        opId: 'SERVER-${DateTime.now().microsecondsSinceEpoch}-AUDIT',
      );
    });
    await refreshSyncState(online: true, message: 'Kiểm kê đã đồng bộ Supabase');
  }

  Future<void> saveAudit({
    required String sessionId,
    required String location,
    required List<String> scannedCodes,
    required int expected,
    required int matched,
    required List<String> missing,
    required List<String> wrongLocation,
    required List<String> unknown,
    required int duplicateScans,
    required String deviceId,
    required String operatorId,
    required String sessionToken,
  }) async {
    final database = await db;
    final now = _nowText();
    final opId = _opId(deviceId);
    await database.transaction((txn) async {
      await txn.insert(
        'audits',
        {
          'session_id': sessionId,
          'timestamp': now,
          'location': location,
          'expected': expected,
          'scanned': scannedCodes.length,
          'matched': matched,
          'missing_count': missing.length,
          'wrong_count': wrongLocation.length,
          'unknown_count': unknown.length,
          'duplicate_scans': duplicateScans,
          'details': jsonEncode({
            'missing': missing,
            'wrongLocation': wrongLocation,
            'unknown': unknown,
          }),
          'operator_id': operatorId,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _queueInTxn(txn, opId, 'saveAudit', {
        '_actorId': operatorId,
        '_actorSessionToken': sessionToken,
        '_actorDeviceId': deviceId,
        'sessionId': sessionId,
        'location': location,
        'scanned': scannedCodes,
        'expected': expected,
        'matched': matched,
        'missing': missing,
        'wrongLocation': wrongLocation,
        'unknown': unknown,
        'duplicateScans': duplicateScans,
        'clientTime': now,
      });
      await _historyInTxn(
        txn,
        timestamp: now,
        pinCode: '',
        action: 'KIEM_KE',
        location: location,
        slot: 0,
        note:
            'Kiểm kê ${scannedCodes.length} mã • khớp $matched • thiếu ${missing.length} • sai Dãy số ${wrongLocation.length}',
        deviceId: deviceId,
        operatorId: operatorId,
        opId: opId,
      );
    });
  }

  Future<void> _queueInTxn(
    Transaction txn,
    String opId,
    String action,
    Map<String, dynamic> payload,
  ) async {
    await txn.insert(
      'outbox',
      {
        'op_id': opId,
        'action': action,
        'payload': jsonEncode(payload),
        'created_ms': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> _historyInTxn(
    Transaction txn, {
    required String timestamp,
    required String pinCode,
    required String action,
    required String location,
    required int slot,
    required String note,
    required String deviceId,
    required String operatorId,
    required String opId,
    String pinType = '',
  }) async {
    await txn.insert('local_history', {
      'timestamp': timestamp,
      'pin_code': pinCode,
      'action': action,
      'location': location,
      'slot': slot,
      'note': note,
      'device_id': deviceId,
      'operator_id': operatorId,
      'op_id': opId,
      'battery_type': pinType.trim(),
    });
  }


  bool _isPendingInboundAction(String action) =>
      action == 'importPinToCell' || action == 'importPinAtSlot';

  bool _isPendingOutboundAction(String action) => action == 'exportPin';

  String _pendingTransferCode(
    String action,
    Map<String, dynamic> payload,
  ) {
    if (_isPendingInboundAction(action)) {
      return '${payload['code'] ?? ''}'.trim();
    }
    if (_isPendingOutboundAction(action)) {
      return '${payload['code'] ?? ''}'.trim();
    }
    return '';
  }

  String _pendingTransferLocation(
    String action,
    Map<String, dynamic> payload,
  ) {
    if (_isPendingInboundAction(action)) {
      return '${payload['location'] ?? ''}'.trim();
    }
    if (_isPendingOutboundAction(action)) {
      return '${payload['expectedLocation'] ?? ''}'.trim();
    }
    return '';
  }

  int _pendingTransferSlot(
    String action,
    Map<String, dynamic> payload,
  ) {
    if (action == 'importPinToCell') {
      return int.tryParse('${payload['preferredSlot'] ?? 0}') ?? 0;
    }
    if (action == 'importPinAtSlot') {
      return int.tryParse('${payload['slot'] ?? 0}') ?? 0;
    }
    if (action == 'exportPin') {
      return int.tryParse('${payload['expectedSlot'] ?? 0}') ?? 0;
    }
    return 0;
  }

  Future<List<Map<String, dynamic>>> listPendingTransfers({
    required bool inbound,
  }) async {
    final database = await db;
    final rows = await database.query(
      'outbox',
      orderBy: 'created_ms ASC',
    );

    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final action = '${row['action'] ?? ''}';
      if (inbound
          ? !_isPendingInboundAction(action)
          : !_isPendingOutboundAction(action)) {
        continue;
      }

      Map<String, dynamic> payload;
      try {
        payload = Map<String, dynamic>.from(
          jsonDecode('${row['payload'] ?? '{}'}') as Map,
        );
      } catch (_) {
        payload = <String, dynamic>{};
      }

      result.add({
        'opId': '${row['op_id'] ?? ''}',
        'action': action,
        'code': _pendingTransferCode(action, payload),
        'location': _pendingTransferLocation(action, payload),
        'slot': _pendingTransferSlot(action, payload),
        'createdMs': (row['created_ms'] as num?)?.toInt() ?? 0,
        'attempts': (row['attempts'] as num?)?.toInt() ?? 0,
        'lastError': '${row['last_error'] ?? ''}',
        'pinType': '${payload['pinType'] ?? ''}',
      });
    }
    return result;
  }

  Future<Map<String, dynamic>> cancelPendingTransfers(
    List<String> opIds,
  ) async {
    final cleanIds = opIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (cleanIds.isEmpty) {
      return {
        'ok': false,
        'code': 'empty_selection',
        'message': 'Chưa chọn thao tác chờ xác nhận.',
        'deleted': 0,
      };
    }

    final database = await db;
    final placeholders = List.filled(cleanIds.length, '?').join(',');
    final selectedRows = await database.rawQuery(
      'SELECT * FROM outbox WHERE op_id IN ($placeholders) ORDER BY created_ms DESC',
      cleanIds.toList(),
    );

    var deleted = 0;
    final failed = <String>[];

    for (final selectedRow in selectedRows) {
      final opId = '${selectedRow['op_id'] ?? ''}';
      final action = '${selectedRow['action'] ?? ''}';

      if (!_isPendingInboundAction(action) &&
          !_isPendingOutboundAction(action)) {
        failed.add('$opId: thao tác không thuộc NHẬP/XUẤT');
        continue;
      }

      Map<String, dynamic> payload;
      try {
        payload = Map<String, dynamic>.from(
          jsonDecode('${selectedRow['payload'] ?? '{}'}') as Map,
        );
      } catch (_) {
        failed.add('$opId: dữ liệu hàng chờ bị lỗi');
        continue;
      }

      final code = _pendingTransferCode(action, payload);
      final location = _pendingTransferLocation(action, payload);
      final slot = _pendingTransferSlot(action, payload);
      if (code.isEmpty || location.isEmpty || slot < 1) {
        failed.add('$opId: thiếu mã/vị trí để hoàn tác');
        continue;
      }

      // Không cho xóa một thao tác cũ nếu cùng mã còn thao tác mới hơn
      // chưa được chọn xóa. Việc này tránh làm local lệch chuỗi NHẬP -> XUẤT.
      final newerRows = await database.query(
        'outbox',
        where: 'created_ms>?',
        whereArgs: [(selectedRow['created_ms'] as num?)?.toInt() ?? 0],
        orderBy: 'created_ms DESC',
      );
      var blocked = false;
      for (final newer in newerRows) {
        final newerOpId = '${newer['op_id'] ?? ''}';
        if (cleanIds.contains(newerOpId)) continue;

        final newerAction = '${newer['action'] ?? ''}';
        if (!_isPendingInboundAction(newerAction) &&
            !_isPendingOutboundAction(newerAction)) {
          continue;
        }

        try {
          final newerPayload = Map<String, dynamic>.from(
            jsonDecode('${newer['payload'] ?? '{}'}') as Map,
          );
          final newerCode = _pendingTransferCode(newerAction, newerPayload);
          if (newerCode == code) {
            blocked = true;
            break;
          }
        } catch (_) {
          // Ignore malformed unrelated rows here.
        }
      }

      if (blocked) {
        failed.add('$code: còn thao tác mới hơn đang chờ, hãy xóa thao tác mới trước');
        continue;
      }

      final cancelResult = await database.transaction((txn) async {
        if (_isPendingInboundAction(action)) {
          final pinRows = await txn.query(
            'pins',
            where: 'code=?',
            whereArgs: [code],
            limit: 1,
          );

          if (pinRows.isNotEmpty) {
            final current = pinRows.first;
            final currentLocation = '${current['location'] ?? ''}';
            final currentSlot = (current['slot'] as num?)?.toInt() ?? 0;
            if (currentLocation != location || currentSlot != slot) {
              return {
                'ok': false,
                'message':
                    '$code đã đổi vị trí trên máy, không thể tự hoàn tác an toàn.',
              };
            }
            await txn.delete(
              'pins',
              where: 'code=?',
              whereArgs: [code],
            );
          }
        } else {
          // Hủy XUẤT chưa đồng bộ = trả pin về đúng vị trí local ban đầu.
          final existingCode = await txn.query(
            'pins',
            where: 'code=?',
            whereArgs: [code],
            limit: 1,
          );
          if (existingCode.isNotEmpty) {
            final current = existingCode.first;
            final currentLocation = '${current['location'] ?? ''}';
            final currentSlot = (current['slot'] as num?)?.toInt() ?? 0;
            if (currentLocation != location || currentSlot != slot) {
              return {
                'ok': false,
                'message':
                    '$code đã tồn tại ở vị trí khác, không thể hoàn tác XUẤT.',
              };
            }
          } else {
            final occupied = await txn.query(
              'pins',
              where: 'location=? AND slot=?',
              whereArgs: [location, slot],
              limit: 1,
            );
            if (occupied.isNotEmpty) {
              return {
                'ok': false,
                'message':
                    'Vị trí cũ của $code đã có pin khác, không thể hoàn tác XUẤT.',
              };
            }

            final restoredAt = '${payload['originalStoredAt'] ?? payload['clientTime'] ?? _nowText()}';
            final actorId = '${payload['_actorId'] ?? ''}';
            final actorDeviceId = '${payload['_actorDeviceId'] ?? ''}';

            await txn.insert(
              'pins',
              {
                'code': code,
                'location': location,
                'slot': slot,
                'stored_at': restoredAt,
                'updated_at': _nowText(),
                'device_id': actorDeviceId,
                'operator_id': actorId,
                'battery_type': '${payload['pinType'] ?? ''}',
              },
              conflictAlgorithm: ConflictAlgorithm.abort,
            );
          }
        }

        await txn.delete(
          'local_history',
          where: 'op_id=?',
          whereArgs: [opId],
        );
        await txn.delete(
          'outbox',
          where: 'op_id=?',
          whereArgs: [opId],
        );

        return {'ok': true};
      });

      if (cancelResult['ok'] == true) {
        deleted++;
      } else {
        failed.add('${cancelResult['message'] ?? code}');
      }
    }

    await refreshSyncState();

    return {
      'ok': failed.isEmpty,
      'deleted': deleted,
      'failed': failed,
      'message': failed.isEmpty
          ? 'Đã xóa $deleted thao tác khỏi hàng chờ và hoàn tác local.'
          : 'Đã xóa $deleted thao tác. ${failed.length} thao tác không thể xóa an toàn.',
    };
  }


  bool _isManualTransferAction(String action) =>
      _isPendingInboundAction(action) || _isPendingOutboundAction(action);

  Map<String, dynamic> _decodeOutboxRow(Map<String, Object?> row) {
    Map<String, dynamic> payload;
    try {
      payload = Map<String, dynamic>.from(
        jsonDecode('${row['payload'] ?? '{}'}') as Map,
      );
    } catch (_) {
      payload = <String, dynamic>{};
    }
    return {
      'opId': '${row['op_id'] ?? ''}',
      'action': '${row['action'] ?? ''}',
      'payload': payload,
      'createdMs': (row['created_ms'] as num?)?.toInt() ?? 0,
      'attempts': (row['attempts'] as num?)?.toInt() ?? 0,
      'lastError': '${row['last_error'] ?? ''}',
    };
  }

  Future<List<Map<String, dynamic>>> pendingAutoOps({
    int limit = 8,
  }) async {
    final database = await db;
    final rows = await database.query(
      'outbox',
      orderBy: 'created_ms ASC',
    );

    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final action = '${row['action'] ?? ''}';
      if (_isManualTransferAction(action)) continue;
      result.add(_decodeOutboxRow(row));
      if (result.length >= limit) break;
    }
    return result;
  }

  Future<int> pendingTransferCount() async {
    final database = await db;
    final rows = await database.rawQuery(
      "SELECT COUNT(*) AS c FROM outbox "
      "WHERE action IN ('importPinToCell','importPinAtSlot','exportPin')",
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<List<String>> pendingTransferOpIdsOlderThan({
    required Duration age,
    bool onlyUnattempted = true,
    int limit = 200,
  }) async {
    final database = await db;
    final safeLimit = limit.clamp(1, 1000);
    final cutoffMs =
        DateTime.now().millisecondsSinceEpoch - age.inMilliseconds;

    final attemptsClause =
        onlyUnattempted ? ' AND attempts=0' : '';

    final rows = await database.rawQuery(
      "SELECT op_id FROM outbox "
      "WHERE action IN "
      "('importPinToCell','importPinAtSlot','exportPin') "
      "AND created_ms<=?"
      "$attemptsClause "
      "ORDER BY created_ms ASC "
      "LIMIT ?",
      [cutoffMs, safeLimit],
    );

    final result = <String>[];
    final seen = <String>{};
    for (final row in rows) {
      final opId = '${row['op_id'] ?? ''}'.trim();
      if (opId.isEmpty || !seen.add(opId)) continue;
      result.add(opId);
    }
    return result;
  }

  Future<Map<String, dynamic>> pendingTransferOpsForUpload(
    List<String> opIds,
  ) async {
    final selected =
        opIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (selected.isEmpty) {
      return {
        'ops': <Map<String, dynamic>>[],
        'blocked': <String>[],
      };
    }

    final database = await db;
    final rows = await database.query(
      'outbox',
      orderBy: 'created_ms ASC',
    );

    final priorUnselectedByCode = <String, int>{};
    final ops = <Map<String, dynamic>>[];
    final blocked = <String>[];

    for (final row in rows) {
      final decoded = _decodeOutboxRow(row);
      final action = '${decoded['action'] ?? ''}';
      if (!_isManualTransferAction(action)) continue;

      final payload =
          Map<String, dynamic>.from(decoded['payload'] as Map? ?? const {});
      final code = _pendingTransferCode(action, payload);
      final opId = '${decoded['opId'] ?? ''}';

      if (selected.contains(opId)) {
        if (code.isNotEmpty &&
            (priorUnselectedByCode[code] ?? 0) > 0) {
          blocked.add(
            '$code: còn thao tác cũ hơn đang chờ. Hãy tải thao tác cũ trước hoặc chọn tất cả các thao tác của mã này.',
          );
          continue;
        }
        ops.add({
          'opId': opId,
          'action': action,
          'payload': payload,
        });
      } else if (code.isNotEmpty) {
        priorUnselectedByCode[code] =
            (priorUnselectedByCode[code] ?? 0) + 1;
      }
    }

    return {
      'ops': ops,
      'blocked': blocked,
    };
  }

  Future<void> markManualTransferUploadResult({
    required String opId,
    required Map<String, dynamic> result,
  }) async {
    final database = await db;
    if (result['ok'] == true) {
      await database.delete(
        'outbox',
        where: 'op_id=?',
        whereArgs: [opId],
      );
      return;
    }

    final code = '${result['code'] ?? 'upload_failed'}';
    final message = '${result['message'] ?? code}';
    await database.rawUpdate(
      'UPDATE outbox '
      'SET attempts=attempts+1, last_error=? '
      'WHERE op_id=?',
      ['$code • $message', opId],
    );
  }

  Future<void> markTransferAttemptsFailed(
    Iterable<String> opIds,
    String message,
  ) async {
    final ids = opIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) return;
    final database = await db;
    final placeholders = List.filled(ids.length, '?').join(',');
    await database.rawUpdate(
      'UPDATE outbox SET attempts=attempts+1, last_error=? '
      'WHERE op_id IN ($placeholders)',
      [message, ...ids],
    );
  }

  Future<List<Map<String, dynamic>>> pendingOps({int limit = 8}) async {
    final database = await db;
    final rows = await database.query(
      'outbox',
      orderBy: 'created_ms ASC',
      limit: limit,
    );
    return rows.map((row) {
      final payload = Map<String, dynamic>.from(
        jsonDecode('${row['payload']}') as Map,
      );
      return {
        'opId': '${row['op_id']}',
        'action': '${row['action']}',
        'payload': payload,
      };
    }).toList();
  }

  Future<void> markSyncResult({
    required String opId,
    required String action,
    required Map<String, dynamic> result,
    Map<String, dynamic>? payload,
  }) async {
    final database = await db;
    if (result['ok'] == true) {
      await database.delete('outbox', where: 'op_id=?', whereArgs: [opId]);
      return;
    }
    final code = '${result['code'] ?? ''}';
    const conflictCodes = {
      'duplicate',
      'occupied',
      'full',
      'not_found',
      'empty',
      'bad_slot',
      'bad_cell',
      'cell_full',
      'bad_label',
      'bad_layout',
      'layout_has_pins',
      'bad_location',
      'exists',
      'bad_input',
      'permission_denied',
      'account_disabled',
      'unsupported_sync_action',
      'bad_op',
      'bad_count',
      'state_conflict',
      'location_not_empty',
      'user_not_found',
      'actor_mismatch',
    };
    if (conflictCodes.contains(code)) {
      await database.transaction((txn) async {
        await txn.insert('conflicts', {
          'op_id': opId,
          'action': action,
          'message': '${result['message'] ?? code}',
          'payload': jsonEncode(payload ?? const {}),
          'created_ms': DateTime.now().millisecondsSinceEpoch,
        });
        await txn.delete('outbox', where: 'op_id=?', whereArgs: [opId]);
      });
    } else {
      await database.rawUpdate(
        'UPDATE outbox SET attempts=attempts+1, last_error=? WHERE op_id=?',
        ['${result['message'] ?? code}', opId],
      );
    }
  }

  Future<List<Map<String, dynamic>>> listConflicts({int limit = 30}) async {
    final database = await db;
    final rows = await database.query(
      'conflicts',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map((r) => {
      'id': (r['id'] as num?)?.toInt() ?? 0,
      'opId': '${r['op_id'] ?? ''}',
      'action': '${r['action'] ?? ''}',
      'message': '${r['message'] ?? ''}',
      'payload': '${r['payload'] ?? ''}',
      'createdMs': (r['created_ms'] as num?)?.toInt() ?? 0,
    }).toList();
  }

  Future<void> clearConflicts() async {
    final database = await db;
    await database.delete('conflicts');
    await refreshSyncState();
  }

  Future<int> serverRevision() async =>
      int.tryParse(await getMeta('last_server_revision')) ?? 0;

  Future<String> layoutVersion() => getMeta('layout_version');

  Future<bool> historyBootstrapComplete() async =>
      (await getMeta('history_bootstrap_complete')) == '1';

  Future<int> remoteSlotCount() async {
    final database = await db;
    final rows = await database.rawQuery('SELECT COUNT(*) AS c FROM remote_slots');
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<List<Map<String, dynamic>>> remoteSlotRows() async {
    final database = await db;
    final rows = await database.query('remote_slots', orderBy: 'sort_key ASC');
    return rows.map((r) => {
      'id': '${r['remote_slot_id'] ?? ''}',
      'slot_id': '${r['remote_slot_id'] ?? ''}',
      'aisleCode': '${r['aisle_code'] ?? ''}',
      'aisleLabel': '${r['aisle_label'] ?? ''}',
      'shelfCode': '${r['shelf_code'] ?? ''}',
      'shelfLabel': '${r['shelf_label'] ?? ''}',
      'levelCode': '${r['level_code'] ?? ''}',
      'levelLabel': '${r['level_label'] ?? ''}',
      'slotCode': '${r['slot_code'] ?? ''}',
      'slotLabel': '${r['slot_label'] ?? ''}',
      'sortKey': (r['sort_key'] as num?)?.toInt() ?? 0,
      'active': ((r['active'] as num?)?.toInt() ?? 1) != 0,
    }).toList();
  }

  Future<String> remoteSlotForLegacy(String location, int localSlot) async {
    final database = await db;
    final rows = await database.query(
      'remote_slots',
      columns: ['remote_slot_id'],
      where: 'location=? AND local_slot=?',
      whereArgs: [location, localSlot],
      limit: 1,
    );
    return rows.isEmpty ? '' : '${rows.first['remote_slot_id'] ?? ''}';
  }

  Future<Map<String, dynamic>?> legacySlotForRemote(String remoteSlotId) async {
    final database = await db;
    final rows = await database.query(
      'remote_slots',
      columns: ['location', 'local_slot'],
      where: 'remote_slot_id=?',
      whereArgs: [remoteSlotId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return {
      'location': '${rows.first['location'] ?? ''}',
      'slot': (rows.first['local_slot'] as num?)?.toInt() ?? 0,
    };
  }

  int _remoteInt(dynamic value) {
    final text = '${value ?? ''}';
    final match = RegExp(r'(\d+)').firstMatch(text);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  int _historyTimestampMs(String value) {
    final clean = value.trim();
    final iso = DateTime.tryParse(clean);
    if (iso != null) return iso.millisecondsSinceEpoch;
    final match = RegExp(
      r'^(\d{1,2})/(\d{1,2})/(\d{4})(?:\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$',
    ).firstMatch(clean);
    if (match == null) return 0;
    try {
      return DateTime(
        int.parse(match.group(3)!),
        int.parse(match.group(2)!),
        int.parse(match.group(1)!),
        int.tryParse(match.group(4) ?? '') ?? 0,
        int.tryParse(match.group(5) ?? '') ?? 0,
        int.tryParse(match.group(6) ?? '') ?? 0,
      ).millisecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
  }

  String _localActionFromServer(String action) {
    switch (action.trim().toUpperCase()) {
      case 'IMPORT':
        return 'NHAP';
      case 'EXPORT':
        return 'XUAT';
      case 'REPLACE_IN':
        return 'THAY_NHAP';
      case 'REPLACE_OUT':
        return 'THAY_XUAT';
      default:
        return action.trim().toUpperCase();
    }
  }

  Future<void> _replaceRemoteLayoutInTxn(
    Transaction txn,
    List<Map<String, dynamic>> slots,
  ) async {
    await txn.delete('remote_slots');
    await txn.delete('locations');
    await txn.delete('rack_labels');

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final row in slots) {
      final remoteId = '${row['id'] ?? row['slot_id'] ?? ''}'.trim();
      if (remoteId.isEmpty) continue;
      final location = '${_remoteInt(row['aisleCode'] ?? row['aisle_code'])}';
      final shelf = max(1, _remoteInt(row['shelfCode'] ?? row['shelf_code']));
      final level = max(1, _remoteInt(row['levelCode'] ?? row['level_code']));
      final pin = max(1, _remoteInt(row['slotCode'] ?? row['slot_code']));
      final oldRow = ((level - 1) ~/ _kCellsPerRow) + 1;
      final oldCell = ((level - 1) % _kCellsPerRow) + 1;
      final localSlot = _slotFromParts(shelf, oldRow, oldCell, pin);
      await txn.insert(
        'remote_slots',
        {
          'remote_slot_id': remoteId,
          'location': location,
          'local_slot': localSlot,
          'aisle_code': '${row['aisleCode'] ?? row['aisle_code'] ?? ''}',
          'aisle_label': '${row['aisleLabel'] ?? row['aisle_label'] ?? ''}',
          'shelf_code': '${row['shelfCode'] ?? row['shelf_code'] ?? ''}',
          'shelf_label': '${row['shelfLabel'] ?? row['shelf_label'] ?? ''}',
          'level_code': '${row['levelCode'] ?? row['level_code'] ?? ''}',
          'level_label': '${row['levelLabel'] ?? row['level_label'] ?? ''}',
          'slot_code': '${row['slotCode'] ?? row['slot_code'] ?? ''}',
          'slot_label': '${row['slotLabel'] ?? row['slot_label'] ?? ''}',
          'sort_key': int.tryParse('${row['sortKey'] ?? row['sort_key'] ?? 0}') ?? 0,
          'active': row['active'] == false ? 0 : 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      grouped.putIfAbsent(location, () => <Map<String, dynamic>>[]).add(row);
    }

    final now = DateTime.now().toIso8601String();
    for (final entry in grouped.entries) {
      final location = entry.key;
      final rows = entry.value;
      await txn.insert(
        'locations',
        {'id': location, 'capacity': rows.length, 'updated_at': now},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      var maxShelf = 1;
      var maxLevel = 1;
      var maxPin = 1;
      final seenShelf = <int>{};
      final seenLevel = <String>{};
      for (final row in rows) {
        final shelf = max(1, _remoteInt(row['shelfCode'] ?? row['shelf_code']));
        final level = max(1, _remoteInt(row['levelCode'] ?? row['level_code']));
        final pin = max(1, _remoteInt(row['slotCode'] ?? row['slot_code']));
        maxShelf = max(maxShelf, shelf);
        maxLevel = max(maxLevel, level);
        maxPin = max(maxPin, pin);
        if (seenShelf.add(shelf)) {
          await txn.insert('rack_labels', {
            'location': location,
            'kind': 'DAY',
            'aisle_no': shelf,
            'row_no': 0,
            'cell_no': 0,
            'label': '${row['shelfLabel'] ?? row['shelf_label'] ?? 'Kệ $shelf'}',
            'updated_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        final lk = '$shelf|$level';
        if (seenLevel.add(lk)) {
          await txn.insert('rack_labels', {
            'location': location,
            'kind': 'O',
            'aisle_no': shelf,
            'row_no': ((level - 1) ~/ _kCellsPerRow) + 1,
            'cell_no': ((level - 1) % _kCellsPerRow) + 1,
            'label': '${_warehouseId == _kWarehouseAuto ? 'Vị trí' : 'Ô'} $level',
            'updated_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      final aisleLabel = rows.isEmpty
          ? 'Dãy $location'
          : '${rows.first['aisleLabel'] ?? rows.first['aisle_label'] ?? 'Dãy $location'}';
      for (final item in <Map<String, Object?>>[
        {'kind': 'KE', 'label': aisleLabel},
        {'kind': 'SO_DAY', 'label': '$maxShelf'},
        {'kind': 'SO_O', 'label': '$maxLevel'},
        {'kind': 'SO_PIN_O', 'label': '$maxPin'},
      ]) {
        await txn.insert('rack_labels', {
          'location': location,
          'kind': item['kind'],
          'aisle_no': 0,
          'row_no': 0,
          'cell_no': 0,
          'label': item['label'],
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
  }

  Future<Map<String, Map<String, dynamic>>> _remoteMapInTxn(
    Transaction txn,
  ) async {
    final rows = await txn.query('remote_slots');
    return {
      for (final r in rows)
        '${r['remote_slot_id'] ?? ''}': {
          'location': '${r['location'] ?? ''}',
          'slot': (r['local_slot'] as num?)?.toInt() ?? 0,
        },
    };
  }

  Future<void> _replaceInventoryInTxn(
    Transaction txn,
    List<Map<String, dynamic>> inventory,
    Map<String, Map<String, dynamic>> remoteMap,
  ) async {
    await txn.delete('pins');
    for (final row in inventory) {
      final code = '${row['code'] ?? row['pin_code'] ?? ''}'.trim();
      final remoteId = '${row['slotId'] ?? row['slot_id'] ?? ''}'.trim();
      final legacy = remoteMap[remoteId];
      if (code.isEmpty || legacy == null) continue;
      final location = '${legacy['location'] ?? ''}';
      final slot = int.tryParse('${legacy['slot'] ?? 0}') ?? 0;
      if (location.isEmpty || slot <= 0) continue;
      await txn.insert('pins', {
        'code': code,
        'location': location,
        'slot': slot,
        'stored_at': '${row['storedAt'] ?? row['stored_at'] ?? ''}',
        'updated_at': '${row['updatedAt'] ?? row['updated_at'] ?? ''}',
        'device_id': 'SUPABASE',
        'operator_id': '',
        'battery_type': '${row['pinType'] ?? row['pin_type'] ?? ''}',
        'remote_slot_id': remoteId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> _remapPinsFromRemoteInTxn(
    Transaction txn,
    Map<String, Map<String, dynamic>> remoteMap,
  ) async {
    final rows = await txn.query(
      'pins',
      columns: ['code', 'remote_slot_id'],
      where: "TRIM(remote_slot_id)<>''",
    );
    for (final row in rows) {
      final remoteId = '${row['remote_slot_id'] ?? ''}'.trim();
      final legacy = remoteMap[remoteId];
      if (legacy == null) continue;
      final location = '${legacy['location'] ?? ''}';
      final slot = int.tryParse('${legacy['slot'] ?? 0}') ?? 0;
      if (location.isEmpty || slot <= 0) continue;
      await txn.update(
        'pins',
        {'location': location, 'slot': slot},
        where: 'code=?',
        whereArgs: ['${row['code'] ?? ''}'],
      );
    }
  }

  Future<void> _upsertCanonicalInventoryDeltaInTxn(
    Transaction txn,
    List<Map<String, dynamic>> inventoryDelta,
    List<String> removedPinCodes,
    Map<String, Map<String, dynamic>> remoteMap,
  ) async {
    for (final rawCode in removedPinCodes) {
      final code = rawCode.trim();
      if (code.isEmpty) continue;
      await txn.delete('pins', where: 'code=?', whereArgs: [code]);
    }

    for (final row in inventoryDelta) {
      final code = '${row['code'] ?? row['pin_code'] ?? ''}'.trim();
      final remoteId = '${row['slotId'] ?? row['slot_id'] ?? ''}'.trim();
      final legacy = remoteMap[remoteId];
      if (code.isEmpty || legacy == null) continue;
      final location = '${legacy['location'] ?? ''}';
      final slot = int.tryParse('${legacy['slot'] ?? 0}') ?? 0;
      if (location.isEmpty || slot <= 0) continue;

      await txn.delete(
        'pins',
        where: 'location=? AND slot=? AND code<>?',
        whereArgs: [location, slot, code],
      );
      await txn.insert(
        'pins',
        {
          'code': code,
          'location': location,
          'slot': slot,
          'stored_at': '${row['storedAt'] ?? row['stored_at'] ?? ''}',
          'updated_at': '${row['updatedAt'] ?? row['updated_at'] ?? ''}',
          'device_id': 'SUPABASE',
          'operator_id': '',
          'battery_type': '${row['pinType'] ?? row['pin_type'] ?? ''}',
          'remote_slot_id': remoteId,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<void> _mergeServerHistoryInTxn(
    Transaction txn,
    Map<String, dynamic> row,
    Map<String, Map<String, dynamic>> remoteMap,
  ) async {
    final serverId = '${row['id'] ?? ''}'.trim();
    final operationId = '${row['operationId'] ?? row['operation_id'] ?? ''}'.trim();
    final serverRevision = int.tryParse('${row['serverRevision'] ?? row['revision'] ?? 0}') ?? 0;
    final timestamp = '${row['occurredAt'] ?? row['occurred_at'] ?? ''}';
    final pinCode = '${row['pinCode'] ?? row['pin_code'] ?? ''}'.trim();
    final action = _localActionFromServer('${row['action'] ?? ''}');
    final remoteId = '${row['slotId'] ?? row['slot_id'] ?? ''}'.trim();
    final legacy = remoteMap[remoteId];
    final location = '${legacy?['location'] ?? ''}';
    final slot = int.tryParse('${legacy?['slot'] ?? 0}') ?? 0;
    final values = <String, Object?>{
      'timestamp': timestamp,
      'pin_code': pinCode,
      'action': action,
      'location': location,
      'slot': slot,
      'note': '${row['reason'] ?? ''}',
      'device_id': '${row['deviceId'] ?? row['device_id'] ?? ''}',
      'operator_id': '${row['userId'] ?? row['user_id'] ?? ''}',
      'op_id': operationId,
      'battery_type': '${row['pinType'] ?? row['pin_type'] ?? ''}',
      'server_id': serverId,
      'server_revision': serverRevision,
      'source': 'SERVER',
    };

    if (serverId.isNotEmpty) {
      final existingServer = await txn.query(
        'local_history',
        columns: ['id'],
        where: 'server_id=?',
        whereArgs: [serverId],
        limit: 1,
      );
      if (existingServer.isNotEmpty) {
        await txn.update(
          'local_history',
          values,
          where: 'id=?',
          whereArgs: [existingServer.first['id']],
        );
        return;
      }
    }

    if (operationId.isNotEmpty) {
      final byOp = await txn.query(
        'local_history',
        columns: ['id'],
        where: 'op_id=? AND pin_code=? AND action=?',
        whereArgs: [operationId, pinCode, action],
        orderBy: 'id DESC',
        limit: 1,
      );
      if (byOp.isNotEmpty) {
        await txn.update(
          'local_history',
          values,
          where: 'id=?',
          whereArgs: [byOp.first['id']],
        );
        return;
      }
    }

    // 16.0.6 và cũ hơn từng gửi operationId mới ở thời điểm upload. Khi
    // upgrade, ghép bản ghi local cũ với server bằng dấu vân tay nghiệp vụ
    // trong cửa sổ 10 phút để không nhân đôi lịch sử đã có.
    if (pinCode.isNotEmpty) {
      final candidates = await txn.query(
        'local_history',
        where: "source='LOCAL' AND pin_code=? AND action=? AND location=? AND slot=?",
        whereArgs: [pinCode, action, location, slot],
        orderBy: 'id DESC',
        limit: 8,
      );
      final serverMs = _historyTimestampMs(timestamp);
      for (final candidate in candidates) {
        final localMs = _historyTimestampMs('${candidate['timestamp'] ?? ''}');
        if (serverMs > 0 && localMs > 0 && (serverMs - localMs).abs() <= 10 * 60 * 1000) {
          await txn.update(
            'local_history',
            values,
            where: 'id=?',
            whereArgs: [candidate['id']],
          );
          return;
        }
      }
    }

    await txn.insert(
      'local_history',
      values,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> _replayPendingPinsInTxn(Transaction txn) async {
    final rows = await txn.query('outbox', orderBy: 'created_ms ASC');
    for (final row in rows) {
      Map<String, dynamic> payload;
      try {
        payload = Map<String, dynamic>.from(
          jsonDecode('${row['payload'] ?? '{}'}') as Map,
        );
      } catch (_) {
        continue;
      }
      final action = '${row['action'] ?? ''}';
      if (_isPendingInboundAction(action)) {
        final code = '${payload['code'] ?? ''}'.trim();
        final location = '${payload['location'] ?? ''}'.trim();
        final slot = int.tryParse('${payload['slot'] ?? payload['preferredSlot'] ?? 0}') ?? 0;
        if (code.isEmpty || location.isEmpty || slot <= 0) continue;
        final occupied = await txn.query(
          'pins',
          where: 'location=? AND slot=? AND code<>?',
          whereArgs: [location, slot, code],
          limit: 1,
        );
        if (occupied.isNotEmpty) continue;
        await txn.insert('pins', {
          'code': code,
          'location': location,
          'slot': slot,
          'stored_at': '${payload['clientTime'] ?? _nowText()}',
          'updated_at': '${payload['clientTime'] ?? _nowText()}',
          'device_id': '${payload['_actorDeviceId'] ?? ''}',
          'operator_id': '${payload['_actorId'] ?? ''}',
          'battery_type': '${payload['pinType'] ?? ''}',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      } else if (_isPendingOutboundAction(action)) {
        final code = '${payload['code'] ?? ''}'.trim();
        if (code.isNotEmpty) {
          await txn.delete('pins', where: 'code=?', whereArgs: [code]);
        }
      } else if (action == 'replacePin') {
        final oldCode = '${payload['expectedOldCode'] ?? ''}'.trim();
        final newCode = '${payload['newCode'] ?? ''}'.trim();
        final location = '${payload['location'] ?? ''}'.trim();
        final slot = int.tryParse('${payload['slot'] ?? 0}') ?? 0;
        if (oldCode.isNotEmpty) {
          await txn.delete('pins', where: 'code=?', whereArgs: [oldCode]);
        }
        if (newCode.isNotEmpty && location.isNotEmpty && slot > 0) {
          final occupied = await txn.query(
            'pins',
            where: 'location=? AND slot=? AND code<>?',
            whereArgs: [location, slot, newCode],
            limit: 1,
          );
          if (occupied.isEmpty) {
            await txn.insert('pins', {
              'code': newCode,
              'location': location,
              'slot': slot,
              'stored_at': '${payload['clientTime'] ?? _nowText()}',
              'updated_at': '${payload['clientTime'] ?? _nowText()}',
              'device_id': '${payload['_actorDeviceId'] ?? ''}',
              'operator_id': '${payload['_actorId'] ?? ''}',
              'battery_type': '${payload['pinType'] ?? ''}',
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }
    }
  }

  Future<Map<String, int>> applyServerSyncBundle({
    required List<Map<String, dynamic>> slots,
    required List<Map<String, dynamic>> fullInventoryRows,
    required List<Map<String, dynamic>> inventoryDelta,
    required List<String> removedPinCodes,
    required List<Map<String, dynamic>> history,
    required int revision,
    required String layoutVersion,
    required bool fullInventory,
  }) async {
    final database = await db;
    var layoutRows = 0;
    var inventoryRows = 0;
    var historyRows = 0;
    var removedRows = 0;
    await database.transaction((txn) async {
      if (slots.isNotEmpty) {
        await _replaceRemoteLayoutInTxn(txn, slots);
        layoutRows = slots.length;
      }
      final remoteMap = await _remoteMapInTxn(txn);
      if (slots.isNotEmpty) {
        await _remapPinsFromRemoteInTxn(txn, remoteMap);
      }

      if (fullInventory) {
        await _replaceInventoryInTxn(txn, fullInventoryRows, remoteMap);
        inventoryRows = fullInventoryRows.length;
      } else {
        await _upsertCanonicalInventoryDeltaInTxn(
          txn,
          inventoryDelta,
          removedPinCodes,
          remoteMap,
        );
        inventoryRows = inventoryDelta.length;
        removedRows = removedPinCodes.length;
      }

      for (final row in history) {
        await _mergeServerHistoryInTxn(txn, row, remoteMap);
        historyRows++;
      }

      await _replayPendingPinsInTxn(txn);
      await txn.insert(
        'meta',
        {'key': 'last_server_revision', 'value': '$revision'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (layoutVersion.isNotEmpty) {
        await txn.insert(
          'meta',
          {'key': 'layout_version', 'value': layoutVersion},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await txn.insert(
        'meta',
        {
          'key': 'last_snapshot_ms',
          'value': '${DateTime.now().millisecondsSinceEpoch}',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    return {
      'slots': layoutRows,
      'inventory': inventoryRows,
      'removed': removedRows,
      'history': historyRows,
    };
  }

  Future<void> markHistoryBootstrapComplete() async {
    await setMeta('history_bootstrap_complete', '1');
  }

  Future<void> markFullBootstrapNow() async {
    await setMeta(
      'last_full_bootstrap_ms',
      '${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  Future<bool> fullBootstrapRecently({Duration window = const Duration(minutes: 10)}) async {
    final ms = int.tryParse(await getMeta('last_full_bootstrap_ms')) ?? 0;
    if (ms <= 0) return false;
    return DateTime.now().millisecondsSinceEpoch - ms < window.inMilliseconds;
  }

  Future<void> recordSyncLog({
    required int startedMs,
    required int durationMs,
    required String reason,
    required String syncMode,
    required int rowsDownloaded,
    required int rowsUploaded,
    required int revisionBefore,
    required int revisionAfter,
    required bool fullBootstrap,
    required bool layoutReloaded,
    required int historyRows,
    required int inventoryDeltaRows,
    required int removedPinRows,
    required int slotsRows,
    required int pageCount,
    required int responseBytes,
    String error = '',
  }) async {
    final database = await db;
    await database.insert('sync_log', {
      'started_ms': startedMs,
      'duration_ms': durationMs,
      'reason': reason,
      'sync_mode': syncMode,
      'rows_downloaded': rowsDownloaded,
      'rows_uploaded': rowsUploaded,
      'revision_before': revisionBefore,
      'revision_after': revisionAfter,
      'full_bootstrap': fullBootstrap ? 1 : 0,
      'layout_reloaded': layoutReloaded ? 1 : 0,
      'history_rows': historyRows,
      'inventory_delta_rows': inventoryDeltaRows,
      'removed_pin_rows': removedPinRows,
      'slots_rows': slotsRows,
      'page_count': pageCount,
      'response_bytes': responseBytes,
      'error': error,
    });
    await database.rawDelete(
      'DELETE FROM sync_log WHERE id NOT IN '
      '(SELECT id FROM sync_log ORDER BY id DESC LIMIT 500)',
    );
  }

  Map<String, dynamic> _historyRowToMap(Map<String, Object?> row) => {
    'timestamp': '${row['timestamp'] ?? ''}',
    'pinCode': '${row['pin_code'] ?? ''}',
    'action': '${row['action'] ?? ''}',
    'location': '${row['location'] ?? ''}',
    'slot': (row['slot'] as num?)?.toInt() ?? 0,
    'operatorId': '${row['operator_id'] ?? ''}',
    'note': '${row['note'] ?? ''}',
    'deviceId': '${row['device_id'] ?? ''}',
    'pinType': '${row['battery_type'] ?? ''}',
    'serverRevision': (row['server_revision'] as num?)?.toInt() ?? 0,
    'serverId': '${row['server_id'] ?? ''}',
  };

  Future<List<Map<String, dynamic>>> historyPage({
    int limit = 100,
    int offset = 0,
    String query = '',
  }) async {
    final database = await db;
    final safeLimit = limit.clamp(1, 500);
    final safeOffset = max(0, offset);
    final q = query.trim();
    List<Map<String, Object?>> rows;
    if (q.isEmpty) {
      rows = await database.query(
        'local_history',
        orderBy: 'CASE WHEN server_revision>0 THEN server_revision ELSE id END DESC, id DESC',
        limit: safeLimit,
        offset: safeOffset,
      );
    } else {
      final like = '%${q.replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
      rows = await database.rawQuery(
        "SELECT * FROM local_history WHERE "
        "pin_code LIKE ? ESCAPE '\\' COLLATE NOCASE OR "
        "action LIKE ? ESCAPE '\\' COLLATE NOCASE OR "
        "location LIKE ? ESCAPE '\\' COLLATE NOCASE OR "
        "operator_id LIKE ? ESCAPE '\\' COLLATE NOCASE OR "
        "note LIKE ? ESCAPE '\\' COLLATE NOCASE OR "
        "timestamp LIKE ? ESCAPE '\\' COLLATE NOCASE "
        "ORDER BY CASE WHEN server_revision>0 THEN server_revision ELSE id END DESC, id DESC LIMIT ? OFFSET ?",
        [like, like, like, like, like, like, safeLimit, safeOffset],
      );
    }
    return rows.map(_historyRowToMap).toList();
  }

  Future<int> historyCount({String query = ''}) async {
    final database = await db;
    final q = query.trim();
    List<Map<String, Object?>> rows;
    if (q.isEmpty) {
      rows = await database.rawQuery('SELECT COUNT(*) AS c FROM local_history');
    } else {
      final like = '%${q.replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
      rows = await database.rawQuery(
        "SELECT COUNT(*) AS c FROM local_history WHERE "
        "pin_code LIKE ? ESCAPE '\\' COLLATE NOCASE OR "
        "action LIKE ? ESCAPE '\\' COLLATE NOCASE OR "
        "location LIKE ? ESCAPE '\\' COLLATE NOCASE OR "
        "operator_id LIKE ? ESCAPE '\\' COLLATE NOCASE OR "
        "note LIKE ? ESCAPE '\\' COLLATE NOCASE OR "
        "timestamp LIKE ? ESCAPE '\\' COLLATE NOCASE",
        [like, like, like, like, like, like],
      );
    }
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<List<Map<String, dynamic>>> historyForPin(
    String code, {
    int limit = 500,
  }) async {
    final database = await db;
    final rows = await database.query(
      'local_history',
      where: 'pin_code=?',
      whereArgs: [code.trim()],
      orderBy: 'CASE WHEN server_revision>0 THEN server_revision ELSE id END DESC, id DESC',
      limit: limit.clamp(1, 1000),
    );
    return rows.map(_historyRowToMap).toList();
  }

  Future<List<Map<String, dynamic>>> recentHistory({int limit = 300}) async {
    return historyPage(limit: limit.clamp(1, 500), offset: 0);
  }

  Future<List<String>> listPinTypes() async {
    final result = <String>{};
    try {
      final raw = await getMeta('pin_types_json');
      if (raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            final value = '$item'.trim();
            if (value.isNotEmpty) result.add(value);
          }
        }
      }
    } catch (_) {}
    final database = await db;
    final rows = await database.rawQuery(
      "SELECT DISTINCT battery_type FROM pins WHERE TRIM(battery_type)<>'' ORDER BY battery_type COLLATE NOCASE",
    );
    for (final row in rows) {
      final value = '${row['battery_type'] ?? ''}'.trim();
      if (value.isNotEmpty) result.add(value);
    }
    final list = result.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  Future<Map<String, dynamic>> inventoryData() async {
    final database = await db;
    final inventory = await database.query('pins', orderBy: 'location, slot');
    final rackLabels = await database.query('rack_labels');

    return {
      'inventory': inventory.map((r) => {
        'code': '${r['code'] ?? ''}',
        'location': '${r['location'] ?? ''}',
        'slot': (r['slot'] as num?)?.toInt() ?? 0,
        'storedAt': '${r['stored_at'] ?? ''}',
        'updatedAt': '${r['updated_at'] ?? ''}',
        'deviceId': '${r['device_id'] ?? ''}',
        'operatorId': '${r['operator_id'] ?? ''}',
        'pinType': '${r['battery_type'] ?? ''}',
      }).toList(),
      'rackLabels': rackLabels.map((r) => {
        'location': '${r['location'] ?? ''}',
        'kind': '${r['kind'] ?? ''}',
        'aisle': (r['aisle_no'] as num?)?.toInt() ?? 0,
        'row': (r['row_no'] as num?)?.toInt() ?? 0,
        'cell': (r['cell_no'] as num?)?.toInt() ?? 0,
        'label': '${r['label'] ?? ''}',
      }).toList(),
    };
  }

  Future<void> refreshSyncState({
    bool? online,
    bool? syncing,
    DateTime? lastSync,
    String? message,
    String? authError,
  }) async {
    final database = await db;
    final p = await database.rawQuery('SELECT COUNT(*) AS c FROM outbox');
    final m = await database.rawQuery(
      "SELECT COUNT(*) AS c FROM outbox "
      "WHERE action IN ('importPinToCell','importPinAtSlot','exportPin')",
    );
    final c = await database.rawQuery('SELECT COUNT(*) AS c FROM conflicts');
    final pending = (p.first['c'] as num?)?.toInt() ?? 0;
    final manualPending = (m.first['c'] as num?)?.toInt() ?? 0;
    final conflicts = (c.first['c'] as num?)?.toInt() ?? 0;
    final old = syncState.value;
    syncState.value = LocalSyncState(
      online: online ?? old.online,
      syncing: syncing ?? old.syncing,
      pending: pending,
      manualPending: manualPending,
      conflicts: conflicts,
      lastSync: lastSync ?? old.lastSync,
      message: message ?? old.message,
      authError: authError ?? old.authError,
    );
  }
}
