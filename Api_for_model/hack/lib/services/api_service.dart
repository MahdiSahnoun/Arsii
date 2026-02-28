import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Result from the /detect/base64/ocr endpoint for a single detected plate.
class PlateResult {
  final String plateNumber;
  final double yoloConfidence;
  final double ocrConfidence;
  final double x1, y1, x2, y2;

  const PlateResult({
    required this.plateNumber,
    required this.yoloConfidence,
    required this.ocrConfidence,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  factory PlateResult.fromJson(Map<String, dynamic> j) {
    final bbox = j['bbox'] as Map<String, dynamic>;
    return PlateResult(
      plateNumber:    (j['plate_number'] as String? ?? '').trim().toUpperCase(),
      yoloConfidence: (bbox['confidence'] as num? ?? 0).toDouble(),
      ocrConfidence:  (j['ocr_confidence'] as num? ?? 0).toDouble(),
      x1: (bbox['x1'] as num? ?? 0).toDouble(),
      y1: (bbox['y1'] as num? ?? 0).toDouble(),
      x2: (bbox['x2'] as num? ?? 0).toDouble(),
      y2: (bbox['y2'] as num? ?? 0).toDouble(),
    );
  }
}

class ApiService {
  // Change this to your PC's local IP (ipconfig → IPv4 address)
  // e.g. "192.168.1.15"  — NOT 10.0.2.2 (that's emulator-only)
  static String serverIp = '192.168.1.100';
  static int    serverPort = 8000;

  static String get baseUrl => 'http://$serverIp:$serverPort';

  /// Update the server IP at runtime (called from settings dialog).
  static void setServerIp(String ip) {
    serverIp = ip.trim();
  }

  /// Sends a JPEG frame and returns a list of detected plates with their text.
  static Future<List<PlateResult>> detectPlates(Uint8List jpegBytes) async {
    try {
      final imageBase64 = base64Encode(jpegBytes);
      final url = Uri.parse('$baseUrl/detect/base64/ocr');

      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'image': imageBase64}),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final plates = data['plates'] as List<dynamic>? ?? [];
        return plates
            .map((p) => PlateResult.fromJson(p as Map<String, dynamic>))
            .toList();
      } else {
        debugPrint('[ApiService] HTTP ${response.statusCode}: ${response.body}');
        return [];
      }
    } catch (e) {
      debugPrint('[ApiService] Connection error: $e');
      return [];
    }
  }

  /// Simple health check — returns true if server is reachable.
  static Future<bool> healthCheck() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 4));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
