import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/vehicle.dart';
import '../models/access_event.dart';

// ─── Tariff constants ──────────────────────────────────────────
const double kHourlyRate        = 2.0;   // DT / hour  (visitors)
const double kConditionalRate   = 1.0;   // DT / hour  (conditional — after free hours)
const int    kConditionalFreeH  = 2;     // free hours before billing conditional

class DbHelper {
  static final DbHelper instance = DbHelper._();
  DbHelper._();

  Database? _db;

  Future<Database> get db async => _db ??= await _open();

  // ─── Open / create ─────────────────────────────────────────
  Future<Database> _open() async {
    final dbPath = join(await getDatabasesPath(), 'parking.db');
    return openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE vehicles (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            plate_number TEXT    NOT NULL UNIQUE,
            owner_name   TEXT    NOT NULL,
            category     TEXT    NOT NULL,
            notes        TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE events (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            plate_number   TEXT    NOT NULL,
            category       TEXT    NOT NULL,
            event_type     TEXT    NOT NULL,
            timestamp      TEXT    NOT NULL,
            access_granted INTEGER NOT NULL,
            reason         TEXT,
            duration_hours REAL,
            fee            REAL
          )
        ''');
        await _seed(db);
      },
    );
  }

  // ─── Seed known vehicles ───────────────────────────────────
  Future<void> _seed(Database db) async {
    final vehicles = [
      // ── VIP ──────────────────────────────────────────────
      Vehicle(plateNumber: '97 TN 9900',  ownerName: 'Dirigeant A',  category: VehicleCategory.vip),
      Vehicle(plateNumber: '12 TN 0001',  ownerName: 'Directeur B',  category: VehicleCategory.vip),
      Vehicle(plateNumber: '5 TN 100',    ownerName: 'VIP Invité',   category: VehicleCategory.vip),

      // ── Abonné ───────────────────────────────────────────
      Vehicle(plateNumber: '232 TN 6893', ownerName: 'Mohamed Ali',  category: VehicleCategory.subscriber),
      Vehicle(plateNumber: '960 TN 9438', ownerName: 'Sana Triki',   category: VehicleCategory.subscriber),
      Vehicle(plateNumber: '73 TN 3294',  ownerName: 'Karim Bouzid', category: VehicleCategory.subscriber),
      Vehicle(plateNumber: '45 TN 7812',  ownerName: 'Rania Salah',  category: VehicleCategory.subscriber),
      Vehicle(plateNumber: '188 TN 4401', ownerName: 'Hedi Khlifi',  category: VehicleCategory.subscriber),

      // ── Abonné conditionnel ───────────────────────────────
      Vehicle(plateNumber: '300 TN 2200', ownerName: 'Fares Mrad',   category: VehicleCategory.conditional,
              notes: 'Accès autorisé Lun–Ven 08h–18h uniquement. 2h gratuites puis $kConditionalRate DT/h.'),
      Vehicle(plateNumber: '512 TN 8800', ownerName: 'Ines Jouini',  category: VehicleCategory.conditional,
              notes: 'Accès autorisé Sam–Dim 09h–13h. Tarif réduit après 2h gratuites.'),
      Vehicle(plateNumber: '99 TN 5050',  ownerName: 'Naim Belhaj',  category: VehicleCategory.conditional,
              notes: 'Véhicule de service — accès sur rendez-vous uniquement.'),

      // ── Blacklist ─────────────────────────────────────────
      Vehicle(plateNumber: '666 TN 6666', ownerName: 'Inconnu',       category: VehicleCategory.blacklist,
              notes: 'Véhicule signalé — contacter la sécurité.'),
      Vehicle(plateNumber: '111 TN 1111', ownerName: 'Interdit B',    category: VehicleCategory.blacklist,
              notes: 'Dettes impayées.'),
    ];

    for (final v in vehicles) {
      await db.insert('vehicles', v.toMap()..remove('id'));
    }
  }

  // ─── Vehicle lookups ───────────────────────────────────────

  /// Look up a vehicle by exact plate number.
  Future<Vehicle?> findByPlate(String plate) async {
    final d = await db;
    final normalized = plate.trim().toUpperCase();
    final rows = await d.query(
      'vehicles',
      where: 'UPPER(plate_number) = ?',
      whereArgs: [normalized],
    );
    if (rows.isEmpty) return null;
    return Vehicle.fromMap(rows.first);
  }

  Future<List<Vehicle>> allVehicles() async {
    final d = await db;
    final rows = await d.query('vehicles', orderBy: 'category, plate_number');
    return rows.map(Vehicle.fromMap).toList();
  }

  Future<int> upsertVehicle(Vehicle v) async {
    final d = await db;
    return d.insert('vehicles', v.toMap()..remove('id'),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ─── Access decision ────────────────────────────────────────

  /// Decide whether a plate is allowed + compute reason string.
  AccessDecision decide(Vehicle? vehicle) {
    if (vehicle == null) {
      return AccessDecision(
        granted: true,   // unknown plate → allow as visitor
        category: VehicleCategory.visitor,
        reason: 'Plaque non enregistrée — accès visiteur (tarif $kHourlyRate DT/h.',
      );
    }
    switch (vehicle.category) {
      case VehicleCategory.vip:
        return AccessDecision(
          granted: true,
          category: VehicleCategory.vip,
          reason: 'Accès VIP — prioritaire, aucun frais.',
        );
      case VehicleCategory.subscriber:
        return AccessDecision(
          granted: true,
          category: VehicleCategory.subscriber,
          reason: 'Abonné mensuel — accès libre, aucun frais.',
        );
      case VehicleCategory.conditional:
        return AccessDecision(
          granted: true,
          category: VehicleCategory.conditional,
          reason: vehicle.notes ??
              '${kConditionalFreeH}h gratuites, puis $kConditionalRate DT/h.',
        );
      case VehicleCategory.visitor:
        return AccessDecision(
          granted: true,
          category: VehicleCategory.visitor,
          reason: 'Visiteur — tarif $kHourlyRate DT/h.',
        );
      case VehicleCategory.blacklist:
        return AccessDecision(
          granted: false,
          category: VehicleCategory.blacklist,
          reason: vehicle.notes ?? 'Véhicule en liste noire — accès refusé.',
        );
    }
  }

  // ─── Events ─────────────────────────────────────────────────

  Future<int> logEvent(AccessEvent e) async {
    final d = await db;
    return d.insert('events', e.toMap()..remove('id'));
  }

  /// Find the last unmatched entry for a plate (to compute duration on exit).
  Future<AccessEvent?> lastEntry(String plate) async {
    final d = await db;
    final rows = await d.query(
      'events',
      where: "plate_number = ? AND event_type = 'entry'",
      whereArgs: [plate.trim().toUpperCase()],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return AccessEvent.fromMap(rows.first);
  }

  Future<List<AccessEvent>> recentEvents({int limit = 50}) async {
    final d = await db;
    final rows = await d.query('events', orderBy: 'id DESC', limit: limit);
    return rows.map(AccessEvent.fromMap).toList();
  }

  // ─── Fee calculator ─────────────────────────────────────────

  double computeFee(VehicleCategory cat, double hours) {
    switch (cat) {
      case VehicleCategory.vip:
      case VehicleCategory.subscriber:
        return 0.0;
      case VehicleCategory.conditional:
        final billable = (hours - kConditionalFreeH).clamp(0.0, double.infinity);
        return (billable * kConditionalRate * 100).round() / 100;
      case VehicleCategory.visitor:
        return (hours * kHourlyRate * 100).round() / 100;
      case VehicleCategory.blacklist:
        return 0.0;
    }
  }
}

/// Simple return value from [DbHelper.decide]
class AccessDecision {
  final bool granted;
  final VehicleCategory category;
  final String reason;
  const AccessDecision(
      {required this.granted, required this.category, required this.reason});
}
