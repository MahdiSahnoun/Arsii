"""
License Plate Detection API
Model: YOLOv11s trained on matricule dataset
Usage: Receives a camera image from a mobile app and returns detection + OCR results.
"""

import io
import base64
import logging
from pathlib import Path
from contextlib import asynccontextmanager

from PIL import Image
from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from ultralytics import YOLO

# ─────────────────────────── logging ────────────────────────────
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ─────────────────────────── paths ──────────────────────────────
BASE_DIR   = Path(__file__).resolve().parent.parent   # D:\Hackaton
MODEL_PATH = BASE_DIR / "hack.pt"

# ─────────────────────────── globals ────────────────────────────
model: YOLO = None


# ─────────────────────────── lifespan ───────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    global model
    logger.info(f"Loading model from: {MODEL_PATH}")
    if not MODEL_PATH.exists():
        raise FileNotFoundError(f"Model file not found: {MODEL_PATH}")
    model = YOLO(str(MODEL_PATH))
    model.fuse()
    logger.info(f"Model loaded — classes: {model.names}")
    yield
    logger.info("API shutting down.")


# ─────────────────────────── app ────────────────────────────────
app = FastAPI(
    title="License Plate Detection API",
    description=(
        "YOLOv11s model that detects license plates (matricules) in images "
        "captured by a mobile camera."
    ),
    version="1.0.0",
    lifespan=lifespan,
)

# Allow any origin so the mobile app can call from any network
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ─────────────────────────── schemas ────────────────────────────
class DetectionBox(BaseModel):
    x1: float
    y1: float
    x2: float
    y2: float
    confidence: float
    class_id: int
    class_name: str


class DetectionResponse(BaseModel):
    success: bool
    image_width: int
    image_height: int
    detections: list[DetectionBox]
    annotated_image_base64: str | None = None  # optional — send back annotated frame


class PlateOCRItem(BaseModel):
    bbox: DetectionBox
    raw_text: str        # raw OCR string (may include Arabic)
    plate_number: str    # normalized  e.g. "232 TN 6893"
    ocr_confidence: float


class OCRResponse(BaseModel):
    success: bool
    image_width: int
    image_height: int
    plates: list[PlateOCRItem]


# ─────────────────────────── helpers ────────────────────────────
def run_detection(
    image: Image.Image,
    conf_threshold: float = 0.25,
    iou_threshold: float = 0.45,
    return_annotated: bool = False,
) -> DetectionResponse:
    """Run YOLO inference on a PIL image and return structured results."""
    results = model.predict(
        source=image,
        conf=conf_threshold,
        iou=iou_threshold,
        verbose=False,
    )

    result = results[0]
    boxes  = result.boxes

    detections: list[DetectionBox] = []
    for box in boxes:
        x1, y1, x2, y2 = box.xyxy[0].tolist()
        detections.append(
            DetectionBox(
                x1=round(x1, 2),
                y1=round(y1, 2),
                x2=round(x2, 2),
                y2=round(y2, 2),
                confidence=round(float(box.conf[0]), 4),
                class_id=int(box.cls[0]),
                class_name=model.names[int(box.cls[0])],
            )
        )

    # Annotated image (optional — saves bandwidth when not needed)
    annotated_b64 = None
    if return_annotated:
        annotated_frame = result.plot()          # numpy BGR array
        annotated_pil   = Image.fromarray(annotated_frame[..., ::-1])  # BGR→RGB
        buf = io.BytesIO()
        annotated_pil.save(buf, format="JPEG", quality=85)
        annotated_b64 = base64.b64encode(buf.getvalue()).decode("utf-8")

    return DetectionResponse(
        success=True,
        image_width=image.width,
        image_height=image.height,
        detections=detections,
        annotated_image_base64=annotated_b64,
    )


# ─────────────────────────── routes ─────────────────────────────

@app.get("/health", summary="Health check")
async def health():
    """Returns 200 when the model is loaded and the API is ready."""
    return {
        "status": "ok",
        "model": str(MODEL_PATH.name),
        "classes": model.names if model else {},
        "device": str(next(model.model.parameters()).device) if model else "N/A",
    }


@app.post(
    "/detect",
    response_model=DetectionResponse,
    summary="Detect license plates in an image",
)
async def detect(
    file: UploadFile = File(..., description="Image captured by the mobile camera (JPEG/PNG)"),
    conf: float = 0.25,
    iou: float  = 0.45,
    annotated: bool = False,
):
    """
    Upload a camera frame and receive detection results.

    - **file**: image file (JPEG, PNG, WEBP …)
    - **conf**: minimum confidence threshold (0–1), default 0.25
    - **iou**: IOU threshold for NMS, default 0.45
    - **annotated**: if `true`, also returns the annotated image as base64 JPEG
    """
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded yet.")

    # Validate content type
    if file.content_type and not file.content_type.startswith("image/"):
        raise HTTPException(
            status_code=415,
            detail=f"Unsupported media type: {file.content_type}. Send an image.",
        )

    try:
        contents = await file.read()
        image    = Image.open(io.BytesIO(contents)).convert("RGB")
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Cannot read image: {exc}")

    try:
        response = run_detection(image, conf_threshold=conf, iou_threshold=iou, return_annotated=annotated)
    except Exception as exc:
        logger.exception("Inference error")
        raise HTTPException(status_code=500, detail=f"Inference failed: {exc}")

    return response


# ──────────── Plate reconstruction from character detections ────
# The model detects individual characters:
#   classes 0-9  → digit glyphs
#   class  'TU'  → تونس separator (displayed as "TN")
#   class  'RS'  → سلسلة رقمية (shown as-is)
#   class  'libye' → Libyan plate marker
# Strategy: cluster character boxes into rows, sort each row left→right,
#           concatenate class names → plate string.

def _cluster_rows(detections: list[DetectionBox]) -> list[list[DetectionBox]]:
    """Group boxes that share roughly the same vertical band (= same plate row)."""
    if not detections:
        return []
    by_y = sorted(detections, key=lambda b: (b.y1 + b.y2) / 2)
    clusters: list[list[DetectionBox]] = [[by_y[0]]]
    for box in by_y[1:]:
        cy = (box.y1 + box.y2) / 2
        last = clusters[-1]
        avg_h  = sum(b.y2 - b.y1 for b in last) / len(last)
        last_cy = sum((b.y1 + b.y2) / 2 for b in last) / len(last)
        if abs(cy - last_cy) < avg_h * 0.8:
            last.append(box)
        else:
            clusters.append([box])
    return clusters


def _boxes_to_plate(boxes: list[DetectionBox]) -> tuple[str, str, float]:
    """
    Sort boxes left→right, map class names to plate string.
    Returns (raw_text, plate_number, avg_confidence).
    e.g. classes [2,3,2,TU,6,8,9,3] → raw="2 3 2 TN 6 8 9 3"
                                        plate="232 TN 6893"
    """
    sorted_boxes = sorted(boxes, key=lambda b: b.x1)
    tokens: list[str] = []
    for b in sorted_boxes:
        name = b.class_name.upper()
        tokens.append("TN" if name == "TU" else name)

    raw_text = " ".join(tokens)

    # Build canonical plate: digits before TN + " TN " + digits after TN
    if "TN" in tokens:
        idx   = tokens.index("TN")
        left  = "".join(tokens[:idx])
        right = "".join(tokens[idx + 1:])
        plate = f"{left} TN {right}".strip()
    else:
        plate = "".join(tokens)   # no separator found — best effort

    avg_conf = round(sum(b.confidence for b in sorted_boxes) / len(sorted_boxes), 4)
    return raw_text, plate, avg_conf


def _overall_bbox(boxes: list[DetectionBox]) -> DetectionBox:
    """Compute a bounding box that encloses all character boxes."""
    return DetectionBox(
        x1=round(min(b.x1 for b in boxes), 2),
        y1=round(min(b.y1 for b in boxes), 2),
        x2=round(max(b.x2 for b in boxes), 2),
        y2=round(max(b.y2 for b in boxes), 2),
        confidence=round(sum(b.confidence for b in boxes) / len(boxes), 4),
        class_id=-1,
        class_name="plate",
    )


def run_ocr(image: Image.Image, conf_threshold: float = 0.25) -> OCRResponse:
    """
    YOLO detects every character on the plate → cluster into rows
    → sort left-to-right → concatenate → return plate_number.
    No EasyOCR needed: the model IS the character recognizer.
    """
    det = run_detection(image, conf_threshold=conf_threshold)
    plates: list[PlateOCRItem] = []

    for cluster in _cluster_rows(det.detections):
        if len(cluster) < 2:   # discard lone detections (noise)
            continue
        raw_text, plate_number, avg_conf = _boxes_to_plate(cluster)
        plates.append(PlateOCRItem(
            bbox=_overall_bbox(cluster),
            raw_text=raw_text,
            plate_number=plate_number,
            ocr_confidence=avg_conf,
        ))

    return OCRResponse(
        success=True,
        image_width=image.width,
        image_height=image.height,
        plates=plates,
    )


# ─────────────────────── /detect/base64/ocr ─────────────────────

@app.post(
    "/detect/base64/ocr",
    response_model=OCRResponse,
    summary="Detect plates + OCR from a base64-encoded image",
)
async def detect_base64_ocr(
    payload: dict,
    conf: float = 0.25,
):
    """
    Full pipeline: YOLO detection → crop → EasyOCR → normalized plate number.

    Body JSON: `{ "image": "<base64 bytes>" }`

    Each plate in `plates[]` has:
    - `plate_number`: normalized text e.g. **"232 TN 6893"**
    - `bbox`: bounding box
    - `ocr_confidence`: 0–1
    """
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded yet.")

    b64_data = payload.get("image")
    if not b64_data:
        raise HTTPException(status_code=400, detail="Missing 'image' field.")

    try:
        image_bytes = base64.b64decode(b64_data)
        image       = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Cannot decode image: {exc}")

    try:
        return run_ocr(image, conf_threshold=conf)
    except Exception as exc:
        logger.exception("OCR error")
        raise HTTPException(status_code=500, detail=f"OCR failed: {exc}")


# ─────────────────────────── entry point ────────────────────────
if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=False)
