/// Categories of vehicles in the parking system
enum VehicleCategory {
  vip,           // Priority access, no fees
  subscriber,    // Monthly subscription, free
  conditional,   // Allowed but with time/day restrictions
  visitor,       // Pay per hour
  blacklist,     // Denied access
}

extension VehicleCategoryX on VehicleCategory {
  String get label {
    switch (this) {
      case VehicleCategory.vip:         return 'VIP';
      case VehicleCategory.subscriber:  return 'Abonné';
      case VehicleCategory.conditional: return 'Abonné conditionnel';
      case VehicleCategory.visitor:     return 'Visiteur';
      case VehicleCategory.blacklist:   return 'Blacklist';
    }
  }

  /// Color code (int) for the badge
  int get colorValue {
    switch (this) {
      case VehicleCategory.vip:         return 0xFFFFD700; // gold
      case VehicleCategory.subscriber:  return 0xFF4CAF50; // green
      case VehicleCategory.conditional: return 0xFFFF9800; // orange
      case VehicleCategory.visitor:     return 0xFF2196F3; // blue
      case VehicleCategory.blacklist:   return 0xFFF44336; // red
    }
  }

  bool get isAllowed => this != VehicleCategory.blacklist;
}

/// A registered vehicle in the local SQLite database
class Vehicle {
  final int? id;
  final String plateNumber;   // normalized e.g. "232 TN 6893"
  final String ownerName;
  final VehicleCategory category;
  final String? notes;        // restriction notes for conditional

  const Vehicle({
    this.id,
    required this.plateNumber,
    required this.ownerName,
    required this.category,
    this.notes,
  });

  Map<String, dynamic> toMap() => {
    'id':           id,
    'plate_number': plateNumber,
    'owner_name':   ownerName,
    'category':     category.name,
    'notes':        notes,
  };

  factory Vehicle.fromMap(Map<String, dynamic> m) => Vehicle(
    id:          m['id'] as int?,
    plateNumber: m['plate_number'] as String,
    ownerName:   m['owner_name'] as String,
    category:    VehicleCategory.values.firstWhere(
                   (e) => e.name == m['category'],
                   orElse: () => VehicleCategory.visitor,
                 ),
    notes:       m['notes'] as String?,
  );
}
