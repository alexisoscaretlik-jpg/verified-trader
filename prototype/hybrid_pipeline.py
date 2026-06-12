"""
Hybrid angle-change pipeline for REAL photos.

  photo + depth ──► geometric view change (reproject.py) ──► holes mask
                                                              │
  GPS + heading ──► Street View reference ────────────────────┤
                                                              ▼
                                       Nano Banana (Gemini) fills ONLY the
                                       holes, guided by the reference
Usage:
  python3 hybrid_pipeline.py photo.jpg --depth depth.png --angle 30 \
      [--orbit-distance 6] [--lat 48.8584 --lng 2.2945 --heading 110]

  depth.png : 16-bit PNG, millimetres (iPhone LiDAR / ARKit export), or a
              .npy float array in metres (e.g. from Apple Depth Pro).

Environment:
  GEMINI_API_KEY  – enables the Nano Banana fill step
  MAPS_API_KEY    – enables the Street View reference fetch
Without keys the script still runs stages 1-2 and saves the warped image +
hole mask, using a local inpaint as placeholder fill.
"""
import argparse
import base64
import json
import os
import sys
import urllib.request

import cv2
import numpy as np

from reproject import reproject

GEMINI_MODEL = "gemini-2.5-flash-preview-04-17"
GEMINI_URL = ("https://generativelanguage.googleapis.com/v1beta/models/"
              f"{GEMINI_MODEL}:generateContent")
STREETVIEW_URL = "https://maps.googleapis.com/maps/api/streetview"


def load_depth(path: str, shape) -> np.ndarray:
    if path.endswith(".npy"):
        d = np.load(path).astype(np.float64)            # metres
    else:
        raw = cv2.imread(path, cv2.IMREAD_UNCHANGED)
        if raw is None:
            sys.exit(f"cannot read depth file: {path}")
        d = raw.astype(np.float64) / 1000.0             # mm -> metres
    if d.shape != shape:
        d = cv2.resize(d, (shape[1], shape[0]), interpolation=cv2.INTER_NEAREST)
    return d


def fetch_streetview(lat, lng, heading, key, size="640x480"):
    url = (f"{STREETVIEW_URL}?size={size}&location={lat},{lng}"
           f"&heading={heading:.1f}&pitch=0&fov=90&key={key}")
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read()


def nano_banana_fill(warped_png: bytes, mask_png: bytes,
                     reference_jpg: bytes | None, angle: float, key: str) -> bytes:
    """Ask Nano Banana to fill ONLY the masked holes."""
    prompt = (
        "Image 1 is a photo re-rendered from a camera viewpoint rotated "
        f"{angle:.0f} degrees around the subject; the geometry of all visible "
        "pixels is correct. Image 2 is a binary mask: WHITE marks holes where "
        "no image data exists. Fill ONLY the white-masked regions with "
        "photorealistic content that continues the scene seamlessly. Do NOT "
        "modify any pixel outside the mask."
    )
    parts = [
        {"text": prompt},
        {"inline_data": {"mime_type": "image/png",
                         "data": base64.b64encode(warped_png).decode()}},
        {"inline_data": {"mime_type": "image/png",
                         "data": base64.b64encode(mask_png).decode()}},
    ]
    if reference_jpg:
        parts[0]["text"] += (
            " Image 3 is a Google Street View photo taken at the same GPS "
            "location facing the new viewpoint direction — use it as ground-"
            "truth reference for what the occluded areas actually look like.")
        parts.append({"inline_data": {"mime_type": "image/jpeg",
                                      "data": base64.b64encode(reference_jpg).decode()}})

    body = json.dumps({
        "contents": [{"role": "user", "parts": parts}],
        "generationConfig": {"responseModalities": ["Text", "Image"]},
    }).encode()

    req = urllib.request.Request(
        f"{GEMINI_URL}?key={key}", data=body,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        resp = json.loads(r.read())

    for part in resp["candidates"][0]["content"]["parts"]:
        inline = part.get("inline_data") or part.get("inlineData")
        if inline:
            return base64.b64decode(inline["data"])
    raise RuntimeError("Nano Banana returned no image")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("photo")
    ap.add_argument("--depth", required=True, help="depth .png (mm) or .npy (m)")
    ap.add_argument("--angle", type=float, default=30, help="degrees, 15-50")
    ap.add_argument("--orbit-distance", type=float, default=None,
                    help="orbit pivot distance in metres (default: median depth)")
    ap.add_argument("--fov", type=float, default=70.0)
    ap.add_argument("--lat", type=float)
    ap.add_argument("--lng", type=float)
    ap.add_argument("--heading", type=float,
                    help="compass heading at capture; angle offset is added")
    ap.add_argument("--out", default="hybrid_out")
    args = ap.parse_args()

    bgr = cv2.imread(args.photo)
    if bgr is None:
        sys.exit(f"cannot read photo: {args.photo}")
    rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
    depth = load_depth(args.depth, rgb.shape[:2])

    orbit = args.orbit_distance or float(np.median(depth[depth > 0]))
    print(f"stage 1: geometric view change {args.angle:.0f} deg "
          f"(orbit pivot {orbit:.1f} m)")
    warped, holes = reproject(rgb, depth, args.angle, args.fov,
                              orbit_distance=orbit)
    print(f"  holes: {100 * holes.mean():.1f}% of frame")

    warped_bgr = cv2.cvtColor(warped, cv2.COLOR_RGB2BGR)
    mask8 = (holes * 255).astype(np.uint8)
    cv2.imwrite(f"{args.out}_warped.png", warped_bgr)
    cv2.imwrite(f"{args.out}_mask.png", mask8)

    reference = None
    maps_key = os.environ.get("MAPS_API_KEY")
    if maps_key and args.lat is not None and args.lng is not None:
        target_heading = ((args.heading or 0) + args.angle) % 360
        print(f"stage 1b: Street View reference at heading {target_heading:.0f} deg")
        reference = fetch_streetview(args.lat, args.lng, target_heading, maps_key)
        with open(f"{args.out}_streetview_ref.jpg", "wb") as f:
            f.write(reference)

    gemini_key = os.environ.get("GEMINI_API_KEY")
    if gemini_key:
        print("stage 2: Nano Banana generative fill…")
        ok, warped_png = cv2.imencode(".png", warped_bgr)
        ok2, mask_png = cv2.imencode(".png", mask8)
        result = nano_banana_fill(warped_png.tobytes(), mask_png.tobytes(),
                                  reference, args.angle, gemini_key)
        with open(f"{args.out}_final.png", "wb") as f:
            f.write(result)
        print(f"done → {args.out}_final.png")
    else:
        print("stage 2: GEMINI_API_KEY not set — local inpaint placeholder")
        filled = cv2.inpaint(warped_bgr, mask8, 5, cv2.INPAINT_TELEA)
        cv2.imwrite(f"{args.out}_final_placeholder.png", filled)
        print(f"done → {args.out}_final_placeholder.png "
              "(set GEMINI_API_KEY for the real AI fill)")


if __name__ == "__main__":
    main()
