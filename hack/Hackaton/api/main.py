"""
License Plate Detection API
Model: YOLOv11s trained on matricule dataset
Usage: Receives a camera image from a mobile app and returns detection results.
"""

import io
import base64
import logging
from pathlib import Path
from contextlib import asynccontextmanager

import torch
from PIL import Image
from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
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
    model.fuse()          # fuse Conv+BN layers for faster inference
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


@app.post(
    "/detect/base64",
    response_model=DetectionResponse,
    summary="Detect from a base64-encoded image",
)
async def detect_base64(payload: dict, conf: float = 0.25, iou: float = 0.45, annotated: bool = False):
    """
    Alternative endpoint for mobile apps that send the image as a base64 string.

    Body JSON:
    ```json
    { "image": "<base64-encoded image bytes>" }
    ```
    """
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded yet.")

    b64_data = payload.get("image")
    if not b64_data:
        raise HTTPException(status_code=400, detail="Missing 'image' field in JSON body.")

    try:
        image_bytes = base64.b64decode(b64_data)
        image       = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Cannot decode image: {exc}")

    try:
        response = run_detection(image, conf_threshold=conf, iou_threshold=iou, return_annotated=annotated)
    except Exception as exc:
        logger.exception("Inference error")
        raise HTTPException(status_code=500, detail=f"Inference failed: {exc}")

    return response


# ─────────────────────────── entry point ────────────────────────
if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=False)
