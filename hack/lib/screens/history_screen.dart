import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../models/access_event.dart';
import '../models/vehicle.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<AccessEvent> _events = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    _events = await DbHelper.instance.recentEvents(limit: 100);
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Historique des passages'),
        backgroundColor: Colors.black87,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          )
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _events.isEmpty
              ? const Center(
                  child: Text('Aucun événement enregistré.',
                      style: TextStyle(color: Colors.white38)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _events.length,
                  separatorBuilder: (_, _) =>
                      const Divider(color: Colors.white12, height: 1),
                  itemBuilder: (_, i) => _buildTile(_events[i]),
                ),
    );
  }

  Widget _buildTile(AccessEvent e) {
    final catColor  = Color(e.category.colorValue);
    final isEntry   = e.eventType == EventType.entry;
    final timeStr   = DateFormat('dd/MM/yy HH:mm').format(e.timestamp);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: catColor.withAlpha(50),
        child: Icon(
          isEntry ? Icons.login : Icons.logout,
          color: catColor,
          size: 20,
        ),
      ),
      title: Row(
        children: [
          Text(
            e.plateNumber,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: catColor.withAlpha(40),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              e.category.label,
              style: TextStyle(color: catColor, fontSize: 11),
            ),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            '$timeStr — ${isEntry ? "Entrée" : "Sortie"}',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          if (e.fee != null && e.fee! > 0)
            Text(
              'Tarif: ${e.fee!.toStringAsFixed(2)} DT'
              '${e.durationHours != null ? " (${e.durationHours!.toStringAsFixed(1)}h)" : ""}',
              style: const TextStyle(color: Colors.orange, fontSize: 12),
            ),
          if (e.reason != null)
            Text(
              e.reason!,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
      trailing: Icon(
        e.accessGranted ? Icons.check_circle_outline : Icons.cancel_outlined,
        color: e.accessGranted ? Colors.greenAccent : Colors.redAccent,
        size: 22,
      ),
    );
  }
}
