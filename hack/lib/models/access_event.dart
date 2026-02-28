import 'vehicle.dart';

enum EventType { entry, exit }

/// One parking event (entry or exit)
class AccessEvent {
  final int? id;
  final String plateNumber;
  final VehicleCategory category;
  final EventType eventType;
  final DateTime timestamp;
  final bool accessGranted;
  final String? reason;        // why denied / which rule applied
  final double? durationHours; // filled on exit
  final double? fee;           // computed tariff on exit

  const AccessEvent({
    this.id,
    required this.plateNumber,
    required this.category,
    required this.eventType,
    required this.timestamp,
    required this.accessGranted,
    this.reason,
    this.durationHours,
    this.fee,
  });

  Map<String, dynamic> toMap() => {
    'id':             id,
    'plate_number':   plateNumber,
    'category':       category.name,
    'event_type':     eventType.name,
    'timestamp':      timestamp.toIso8601String(),
    'access_granted': accessGranted ? 1 : 0,
    'reason':         reason,
    'duration_hours': durationHours,
    'fee':            fee,
  };

  factory AccessEvent.fromMap(Map<String, dynamic> m) => AccessEvent(
    id:             m['id'] as int?,
    plateNumber:    m['plate_number'] as String,
    category:       VehicleCategory.values.firstWhere(
                      (e) => e.name == m['category'],
                      orElse: () => VehicleCategory.visitor,
                    ),
    eventType:      EventType.values.firstWhere(
                      (e) => e.name == m['event_type'],
                      orElse: () => EventType.entry,
                    ),
    timestamp:      DateTime.parse(m['timestamp'] as String),
    accessGranted:  (m['access_granted'] as int) == 1,
    reason:         m['reason'] as String?,
    durationHours:  m['duration_hours'] as double?,
    fee:            m['fee'] as double?,
  );
}
