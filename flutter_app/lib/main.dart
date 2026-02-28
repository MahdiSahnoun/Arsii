import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'screens/camera_screen.dart';
import 'screens/history_screen.dart';
import 'screens/vehicles_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Parking Tunisien',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.green,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  bool _cameraPermission = false;

  @override
  void initState() {
    super.initState();
    _requestCamera();
  }

  Future<void> _requestCamera() async {
    final status = await Permission.camera.request();
    setState(() => _cameraPermission = status.isGranted);
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      // Tab 0 – Camera
      _cameraPermission
          ? const CameraScreen()
          : _PermissionDeniedScreen(onRetry: _requestCamera),
      // Tab 1 – History
      const HistoryScreen(),
      // Tab 2 – Vehicles DB
      const VehiclesScreen(),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: screens,
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: const Color(0xFF111111),
        selectedItemColor: Colors.greenAccent,
        unselectedItemColor: Colors.white38,
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.videocam),
            label: 'Caméra',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: 'Historique',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.directions_car),
            label: 'Véhicules',
          ),
        ],
      ),
    );
  }
}

class _PermissionDeniedScreen extends StatelessWidget {
  final VoidCallback onRetry;
  const _PermissionDeniedScreen({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.camera_alt, size: 80, color: Colors.white24),
          const SizedBox(height: 20),
          const Text(
            'Permission caméra requise',
            style: TextStyle(color: Colors.white70, fontSize: 18),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Autoriser'),
          ),
        ],
      ),
    );
  }
}
