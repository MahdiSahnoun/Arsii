import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import '../services/api_service.dart';
import '../models/vehicle.dart';
import '../models/access_event.dart';
import '../database/db_helper.dart';

// ─────────────────────────────────────────────────────────────────
// Top-level data class for compute() — isolates can't receive
// CameraImage directly, so we copy the raw planes first.
// ─────────────────────────────────────────────────────────────────
class _YuvData {
  final int width, height;
  final Uint8List yPlane, uPlane, vPlane;
  final int yRowStride, uvRowStride, uvPixelStride;

  const _YuvData({
    required this.width,
    required this.height,
    required this.yPlane,
    required this.uPlane,
    required this.vPlane,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
  });
}

/// Top-level function — required by compute().  Runs in a background isolate.
Uint8List? _convertYuvToJpeg(_YuvData d) {
  try {
    final out = img.Image(width: d.width, height: d.height, numChannels: 3);
    for (int y = 0; y < d.height; y++) {
      for (int x = 0; x < d.width; x++) {
        final uvIdx = d.uvRowStride * (y >> 1) + (x >> 1) * d.uvPixelStride;
        final idx   = y * d.yRowStride + x;
        if (idx >= d.yPlane.length || uvIdx >= d.uPlane.length) continue;

        final yp = d.yPlane[idx];
        final up = d.uPlane[uvIdx];
        final vp = d.vPlane[uvIdx];

        final r = (yp + vp * 1.402 - 179.456).round().clamp(0, 255);
        final g = (yp - up * 0.344136 - vp * 0.714136 + 135.46).round().clamp(0, 255);
        final b = (yp + up * 1.772 - 226.816).round().clamp(0, 255);
        out.setPixelRgb(x, y, r, g, b);
      }
    }
    final rotated = img.copyRotate(out, angle: 90);
    return img.encodeJpg(rotated, quality: 65);
  } catch (_) {
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────
// State holder for one detected plate
// ─────────────────────────────────────────────────────────────────
class _PlateState {
  final String plateNumber;
  final AccessDecision decision;
  final String ownerName;

  const _PlateState({
    required this.plateNumber,
    required this.decision,
    required this.ownerName,
  });
}

// ─────────────────────────────────────────────────────────────────

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _cameraController;
  bool _isProcessing = false;
  bool _apiReachable = false;

  List<_PlateState> _detectedPlates = [];
  String _statusMsg = 'Initialisation…';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      setState(() => _statusMsg = 'Aucune caméra trouvée');
      return;
    }

    _cameraController = CameraController(
      cameras[0],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _cameraController!.initialize();
    if (!mounted) return;
    setState(() {});

    // Health check in parallel — don't block camera start
    _checkApi();

    _cameraController!.startImageStream(_processFrame);
  }

  Future<void> _checkApi() async {
    final ok = await ApiService.healthCheck();
    if (mounted) {
      setState(() {
        _apiReachable = ok;
        _statusMsg = ok ? 'Caméra active — en écoute' : '⚠️ Serveur inaccessible — vérifier IP';
      });
    }
  }

  // ── Frame processing (non-blocking) ───────────────────────────

  Future<void> _processFrame(CameraImage frame) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      // Copy plane bytes BEFORE passing to isolate
      final yuvData = _YuvData(
        width:        frame.width,
        height:       frame.height,
        yPlane:       Uint8List.fromList(frame.planes[0].bytes),
        uPlane:       Uint8List.fromList(frame.planes[1].bytes),
        vPlane:       Uint8List.fromList(frame.planes[2].bytes),
        yRowStride:   frame.planes[0].bytesPerRow,
        uvRowStride:  frame.planes[1].bytesPerRow,
        uvPixelStride: frame.planes[1].bytesPerPixel!,
      );

      // Heavy pixel conversion runs in background isolate — UI stays smooth
      final jpeg = await compute(_convertYuvToJpeg, yuvData);
      if (jpeg == null) return;

      final results = await ApiService.detectPlates(jpeg);

      final plates = <_PlateState>[];
      for (final r in results) {
        if (r.plateNumber.isEmpty) continue;
        final vehicle  = await DbHelper.instance.findByPlate(r.plateNumber);
        final decision = DbHelper.instance.decide(vehicle);

        plates.add(_PlateState(
          plateNumber: r.plateNumber,
          decision:    decision,
          ownerName:   vehicle?.ownerName ?? 'Inconnu',
        ));

        // Log only new plates
        if (!_detectedPlates.any((p) => p.plateNumber == r.plateNumber)) {
          await DbHelper.instance.logEvent(AccessEvent(
            plateNumber:   r.plateNumber,
            category:      decision.category,
            eventType:     EventType.entry,
            timestamp:     DateTime.now(),
            accessGranted: decision.granted,
            reason:        decision.reason,
          ));
        }
      }

      if (mounted) {
        setState(() {
          _detectedPlates = plates;
          if (results.isNotEmpty) _apiReachable = true;
          _statusMsg = plates.isEmpty
              ? (_apiReachable ? 'En écoute…' : '⚠️ IP: ${ApiService.serverIp} — non accessible')
              : 'Plaque(s) détectée(s)';
        });
      }
    } catch (e) {
      debugPrint('[CameraScreen] error: $e');
    } finally {
      await Future.delayed(const Duration(milliseconds: 800));
      _isProcessing = false;
    }
  }

  @override
  void dispose() {
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    super.dispose();
  }

  // ── IP Settings dialog ─────────────────────────────────────────

  Future<void> _showIpDialog() async {
    final ctrl = TextEditingController(text: ApiService.serverIp);
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Adresse IP du serveur',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Saisir l\'IP locale du PC (ex: 192.168.1.15)\nPour trouver l\'IP: ipconfig → IPv4',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white, fontSize: 18, letterSpacing: 1),
              decoration: const InputDecoration(
                prefixText: 'http://',
                prefixStyle: TextStyle(color: Colors.white38),
                suffixText: ':8000',
                suffixStyle: TextStyle(color: Colors.white38),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.greenAccent)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: () {
              ApiService.setServerIp(ctrl.text);
              Navigator.pop(context);
              _checkApi(); // re-test with new IP
            },
            child: const Text('Connecter'),
          ),
        ],
      ),
    );
  }

  // ── UI ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cameraReady =
        _cameraController != null && _cameraController!.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Détection Matricules'),
        backgroundColor: Colors.black87,
        actions: [
          // Tap the wifi icon to change IP
          IconButton(
            icon: Icon(
              _apiReachable ? Icons.wifi : Icons.wifi_off,
              color: _apiReachable ? Colors.greenAccent : Colors.redAccent,
            ),
            tooltip: 'IP: ${ApiService.serverIp}',
            onPressed: _showIpDialog,
          ),
        ],
      ),
      body: Stack(
        children: [
          // ── Camera preview ─────────────────────────────────
          if (cameraReady)
            Positioned.fill(child: CameraPreview(_cameraController!))
          else
            const Center(child: CircularProgressIndicator()),

          // ── Scan guide frame ───────────────────────────────
          Center(
            child: Container(
              width:  MediaQuery.of(context).size.width * 0.88,
              height: 90,
              decoration: BoxDecoration(
                border: Border.all(
                  color: _detectedPlates.isEmpty
                      ? Colors.white54
                      : (_detectedPlates.first.decision.granted
                          ? Colors.greenAccent
                          : Colors.redAccent),
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),

          // ── Status message ─────────────────────────────────
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: _showIpDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _statusMsg,
                    style: TextStyle(
                      color: _apiReachable ? Colors.white70 : Colors.orangeAccent,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ── Plate info panel ───────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildResultPanel(),
          ),
        ],
      ),
    );
  }

  Widget _buildResultPanel() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(220),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: _detectedPlates.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Aucune plaque en vue',
                    style: TextStyle(color: Colors.white38, fontSize: 16),
                  ),
                  if (!_apiReachable) ...[
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: _showIpDialog,
                      child: Text(
                        'Toucher pour configurer l\'IP (${ApiService.serverIp})',
                        style: const TextStyle(
                            color: Colors.orangeAccent, fontSize: 12),
                      ),
                    ),
                  ],
                ],
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: _detectedPlates.map(_buildPlateCard).toList(),
            ),
    );
  }

  Widget _buildPlateCard(_PlateState p) {
    final cat     = p.decision.category;
    final color   = Color(cat.colorValue);
    final granted = p.decision.granted;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        color.withAlpha(30),
        border:       Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_parking, color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              Text(
                p.plateNumber,
                style: const TextStyle(
                  color: Colors.white, fontSize: 26,
                  fontWeight: FontWeight.bold, letterSpacing: 3,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color:        granted ? Colors.green.withAlpha(80) : Colors.red.withAlpha(80),
                  borderRadius: BorderRadius.circular(20),
                  border:       Border.all(color: granted ? Colors.green : Colors.red),
                ),
                child: Text(
                  granted ? 'AUTORISÉ' : 'REFUSÉ',
                  style: TextStyle(
                    color:      granted ? Colors.greenAccent : Colors.redAccent,
                    fontSize:   12, fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withAlpha(60),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(cat.label,
                    style: TextStyle(
                        color: color, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(p.ownerName,
                    style: const TextStyle(color: Colors.white60, fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(p.decision.reason,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
              maxLines: 3, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

