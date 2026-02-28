# License Plate Detection API

REST API exposing the YOLOv11s model (`hack.pt`) trained to detect **license plates (matricules)**.  
Designed to be consumed by a mobile application that streams camera frames.

---

## Start the server

```bash
# from D:\Hackaton\
.venv\Scripts\python.exe api\main.py
# or
.venv\Scripts\uvicorn.exe api.main:app --host 0.0.0.0 --port 8000
```

Interactive docs: http://localhost:8000/docs

---

## Endpoints

### `GET /health`
Returns model status.
```json
{
  "status": "ok",
  "model": "hack.pt",
  "classes": {"0": "license_plate"},
  "device": "cpu"
}
```

---

### `POST /detect`
Send a camera frame, receive bounding boxes.

| Parameter | Type   | Default | Description |
|-----------|--------|---------|-------------|
| `file`    | file   | —       | JPEG / PNG image from camera |
| `conf`    | float  | 0.25    | Minimum confidence |
| `iou`     | float  | 0.45    | NMS IOU threshold |
| `annotated` | bool | false  | Return annotated image as base64 |

**Response:**
```json
{
  "success": true,
  "image_width": 1280,
  "image_height": 720,
  "detections": [
    {
      "x1": 312.5,
      "y1": 410.2,
      "x2": 589.8,
      "y2": 478.3,
      "confidence": 0.9231,
      "class_id": 0,
      "class_name": "license_plate"
    }
  ],
  "annotated_image_base64": null
}
```

---

### `POST /detect/base64`
Same as `/detect` but the image is sent as a base64 string in the JSON body.

**Request body:**
```json
{ "image": "<base64-encoded bytes>" }
```

---

## Mobile integration example (Flutter / Dart)

```dart
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

Future<Map> detectPlate(File imageFile) async {
  final uri = Uri.parse('http://<SERVER_IP>:8000/detect?annotated=true');
  final request = http.MultipartRequest('POST', uri);
  request.files.add(await http.MultipartFile.fromPath('file', imageFile.path));
  final streamed = await request.send();
  final response = await http.Response.fromStream(streamed);
  return jsonDecode(response.body);
}
```

---

## Mobile integration example (React Native)

```javascript
const detectPlate = async (photoUri) => {
  const formData = new FormData();
  formData.append('file', { uri: photoUri, type: 'image/jpeg', name: 'frame.jpg' });

  const res = await fetch('http://<SERVER_IP>:8000/detect?annotated=true', {
    method: 'POST',
    body: formData,
  });
  return res.json();
};
```
