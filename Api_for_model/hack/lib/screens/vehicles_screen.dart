import 'package:flutter/material.dart';
import '../database/db_helper.dart';
import '../models/vehicle.dart';

class VehiclesScreen extends StatefulWidget {
  const VehiclesScreen({super.key});

  @override
  State<VehiclesScreen> createState() => _VehiclesScreenState();
}

class _VehiclesScreenState extends State<VehiclesScreen> {
  List<Vehicle> _vehicles = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    _vehicles = await DbHelper.instance.allVehicles();
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Véhicules enregistrés'),
        backgroundColor: Colors.black87,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _vehicles.length,
              separatorBuilder: (_, _) =>
                  const Divider(color: Colors.white12, height: 1),
              itemBuilder: (_, i) => _buildTile(_vehicles[i]),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await _showAddDialog(context);
          _load();
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildTile(Vehicle v) {
    final color = Color(v.category.colorValue);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: color.withAlpha(50),
        child: Text(
          v.category.label.substring(0, 1),
          style: TextStyle(color: color, fontWeight: FontWeight.bold),
        ),
      ),
      title: Text(
        v.plateNumber,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
          letterSpacing: 2,
        ),
      ),
      subtitle: Text(
        '${v.ownerName} • ${v.category.label}',
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      trailing: v.notes == null
          ? null
          : Tooltip(
              message: v.notes!,
              child: const Icon(Icons.info_outline,
                  color: Colors.white38, size: 18),
            ),
    );
  }

  Future<void> _showAddDialog(BuildContext ctx) async {
    final plateCtrl = TextEditingController();
    final ownerCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    VehicleCategory selected = VehicleCategory.visitor;

    await showDialog(
      context: ctx,
      builder: (_) => StatefulBuilder(builder: (ctx2, setSt) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Nouveau véhicule',
              style: TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _field(plateCtrl, 'Numéro de plaque (ex: 232 TN 6893)'),
                const SizedBox(height: 10),
                _field(ownerCtrl, "Nom du propriétaire"),
                const SizedBox(height: 10),
                DropdownButton<VehicleCategory>(
                  value: selected,
                  dropdownColor: const Color(0xFF2A2A2A),
                  isExpanded: true,
                  items: VehicleCategory.values
                      .map((c) => DropdownMenuItem(
                            value: c,
                            child: Text(c.label,
                                style:
                                    const TextStyle(color: Colors.white)),
                          ))
                      .toList(),
                  onChanged: (v) => setSt(() => selected = v!),
                ),
                const SizedBox(height: 10),
                _field(notesCtrl, 'Notes / conditions (optionnel)'),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx2),
                child: const Text('Annuler')),
            ElevatedButton(
              onPressed: () async {
                if (plateCtrl.text.trim().isEmpty ||
                    ownerCtrl.text.trim().isEmpty) { return; }
                await DbHelper.instance.upsertVehicle(Vehicle(
                  plateNumber: plateCtrl.text.trim().toUpperCase(),
                  ownerName:   ownerCtrl.text.trim(),
                  category:    selected,
                  notes:       notesCtrl.text.trim().isEmpty
                      ? null
                      : notesCtrl.text.trim(),
                ));
                if (ctx2.mounted) Navigator.pop(ctx2);
              },
              child: const Text('Ajouter'),
            ),
          ],
        );
      }),
    );
  }

  Widget _field(TextEditingController c, String hint) => TextField(
        controller: c,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Colors.white38),
          enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24)),
          focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.greenAccent)),
        ),
      );
}
