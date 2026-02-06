import os
import subprocess
import time
import threading
from typing import Optional, Tuple

import cv2
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

app = FastAPI(title="Camera API")

# ---------- CAMERA SETTINGS ----------

# USB camera settings (kept the same keys you already use)
camera_settings = {
    "resolution": "2592x1944",       # default resolution
    "gain": 0,
    "exposure_time": None,           # v4l2 exposure_time_absolute (int) or None for auto
    "auto_white_balance": True,
    "white_balance_temp": 4,
}

# DSLR camera port mapping
dslr_ports = {
    "1000D": "usb:001,002",
    "6D": "usb:003,005",
}

# Capture directory (served over HTTP)
CAPTURE_DIR = "/home/pi/camd/captures/webcam"
os.makedirs(CAPTURE_DIR, exist_ok=True)
app.mount("/captures/webcam", StaticFiles(directory=CAPTURE_DIR), name="webcam_captures")

# USB camera index (/dev/video0)
usb_camera_index = 0

# ---------- MODELS ----------

class WebcamSettings(BaseModel):
    resolution: Optional[str] = None
    gain: Optional[int] = None
    exposure_time: Optional[int] = None
    auto_white_balance: Optional[bool] = None
    white_balance_temp: Optional[int] = None

# ---------- WEBCAM GLOBALS (persistent OpenCV handle) ----------

_cam_lock = threading.Lock()
_cam: Optional[cv2.VideoCapture] = None
_cam_wh: Optional[Tuple[int, int]] = None

# Track what we last applied to avoid hammering v4l2-ctl
_last_applied = {
    "resolution": None,
    "gain": None,
    "exposure_time": None,
    "auto_white_balance": None,
    "white_balance_temp": None,
}

def _parse_res(res: str) -> Tuple[int, int]:
    try:
        w_s, h_s = res.lower().split("x")
        w, h = int(w_s), int(h_s)
        if w <= 0 or h <= 0:
            raise ValueError()
        return w, h
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid resolution format. Use WxH, e.g. 1920x1080")

def _ensure_camera_open(target_w: int, target_h: int) -> None:
    """
    Keep the webcam open. If resolution changed, reopen to force many UVC cams
    to actually switch modes.
    """
    global _cam, _cam_wh

    # open if needed
    if _cam is None or not _cam.isOpened():
        _cam = cv2.VideoCapture(usb_camera_index, cv2.CAP_V4L2)
        if not _cam.isOpened():
            _cam = None
            _cam_wh = None
            raise HTTPException(status_code=500, detail=f"Cannot open /dev/video{usb_camera_index}")

    # if mode changed, reopen to force new mode (faster than fighting driver state)
    if _cam_wh != (target_w, target_h):
        try:
            _cam.release()
        except Exception:
            pass
        _cam = cv2.VideoCapture(usb_camera_index, cv2.CAP_V4L2)
        if not _cam.isOpened():
            _cam = None
            _cam_wh = None
            raise HTTPException(status_code=500, detail=f"Cannot reopen /dev/video{usb_camera_index} at {target_w}x{target_h}")

        # Request size
        _cam.set(cv2.CAP_PROP_FRAME_WIDTH, float(target_w))
        _cam.set(cv2.CAP_PROP_FRAME_HEIGHT, float(target_h))
        _cam_wh = (target_w, target_h)

        # Warm-up frames (reduces first-frame latency and stale buffers)
        for _ in range(3):
            _cam.read()

def _apply_webcam_settings_if_needed() -> None:
    """
    Apply controls via ONE v4l2-ctl call (fast), but only include controls that
    make sense for current mode so the combined call doesn't fail.

    Key behavior:
    - If exposure_time is None => auto exposure; do NOT send exposure_time_absolute
    - If auto_white_balance is True => do NOT send white_balance_temperature
    """
    global _last_applied

    # Only apply if any setting changed since last apply
    changed = any(camera_settings[k] != _last_applied[k] for k in _last_applied.keys())
    if not changed:
        return

    # Build combined v4l2-ctl controls safely
    ctrls = []

    # gain always safe (per your v4l2-ctl output)
    if camera_settings["gain"] is not None:
        ctrls.append(f"gain={int(camera_settings['gain'])}")

    # exposure
    exp = camera_settings["exposure_time"]
    if exp is None:
        # auto exposure
        # your device exposes auto_exposure menu 0..3; previously you used 0 for auto
        ctrls.append("auto_exposure=0")
        # do NOT set exposure_time_absolute in auto mode
    else:
        ctrls.append("auto_exposure=1")  # manual-ish mode on many UVC cams
        ctrls.append(f"exposure_time_absolute={int(exp)}")

    # white balance
    awb = bool(camera_settings["auto_white_balance"])
    ctrls.append(f"white_balance_automatic={1 if awb else 0}")
    if not awb:
        ctrls.append(f"white_balance_temperature={int(camera_settings['white_balance_temp'])}")
    # if awb is on, do NOT set temperature (it is flagged inactive)

    cmd = ["v4l2-ctl", "-d", f"/dev/video{usb_camera_index}", "--set-ctrl=" + ",".join(ctrls)]
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"Failed to apply camera settings: {e}")

    # record applied
    for k in _last_applied.keys():
        _last_applied[k] = camera_settings[k]

def capture_webcam_image(filename: str) -> str:
    """
    Capture using persistent OpenCV camera. Settings applied once per change.
    """
    filepath = os.path.join(CAPTURE_DIR, filename)
    w, h = _parse_res(camera_settings["resolution"])

    with _cam_lock:
        # Apply controls only if changed (fast path)
        _apply_webcam_settings_if_needed()

        # Ensure camera open at requested resolution
        _ensure_camera_open(w, h)

        ok, frame = _cam.read()
        if not ok or frame is None:
            raise HTTPException(status_code=500, detail="Failed to capture frame from webcam")

        # Write JPEG (default OpenCV compression)
        if not cv2.imwrite(filepath, frame):
            raise HTTPException(status_code=500, detail="Failed to write captured image to disk")

    return filepath

# ---------- DSLR ----------

def capture_dslr(camera_model: str, bulb_seconds: int = 0) -> str:
    port = dslr_ports.get(camera_model)
    if not port:
        raise HTTPException(status_code=400, detail=f"Unknown DSLR model: {camera_model}")

    timestamp = int(time.time())
    filename = f"{camera_model}-{timestamp}.jpg"
    filepath = os.path.join(CAPTURE_DIR, filename)

    if camera_model == "1000D":
        cmd = [
            "gphoto2",
            "--port", port,
            "--wait-event=1s",
            "--set-config", "/main/actions/bulb=1",
            "--wait-event", f"{bulb_seconds}s",
            "--set-config", "/main/actions/bulb=0",
            "--wait-event-and-download=2s",
            "--filename", filepath,
        ]
    elif camera_model == "6D":
        cmd = [
            "gphoto2",
            "--port", port,
            "--wait-event=1s",
            "--set-config", "eosremoterelease=2",
            "--wait-event", f"{bulb_seconds}s",
            "--set-config", "eosremoterelease=4",
            "--wait-event-and-download=3s",
            "--filename", filepath,
        ]
    else:
        raise HTTPException(status_code=400, detail="DSLR model not supported")

    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"DSLR capture failed: {e}")

    return filepath

# ---------- ENDPOINTS (kept identical paths/payloads/responses) ----------

@app.post("/webcam/settings")
def update_webcam_settings(settings: WebcamSettings):
    if settings.resolution:
        camera_settings["resolution"] = settings.resolution
    if settings.gain is not None:
        camera_settings["gain"] = settings.gain
    if settings.exposure_time is not None:
        camera_settings["exposure_time"] = settings.exposure_time
    if settings.auto_white_balance is not None:
        camera_settings["auto_white_balance"] = settings.auto_white_balance
    if settings.white_balance_temp is not None:
        camera_settings["white_balance_temp"] = settings.white_balance_temp

    try:
        # Apply immediately so errors surface here (response format unchanged)
        with _cam_lock:
            _apply_webcam_settings_if_needed()
    except HTTPException as e:
        return JSONResponse(status_code=500, content={"status": "error", "detail": str(e.detail)})

    return {"status": "ok", "settings": camera_settings}

@app.get("/webcam/capture")
def webcam_capture(return_file: bool = Query(False)):
    timestamp = int(time.time())
    filename = f"still_{timestamp}.jpg"
    filepath = capture_webcam_image(filename)

    if return_file:
        return FileResponse(filepath, filename=filename)
    else:
        file_url = f"/captures/webcam/{filename}"
        return {"status": "ok", "file": file_url, "resolution": camera_settings["resolution"]}

@app.get("/dslr/capture")
def dslr_capture(model: str = Query(...), bulb_seconds: int = Query(0), return_file: bool = Query(False)):
    filepath = capture_dslr(model, bulb_seconds)
    if return_file:
        return FileResponse(filepath, filename=os.path.basename(filepath))
    else:
        # kept exactly as your current code returns (filesystem path)
        return {"status": "ok", "file": filepath}

@app.get("/status")
def status():
    return {"status": "ok", "camera_settings": camera_settings}
