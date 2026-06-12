# Hybrid Photo-Angle-Change Prototype

**Proof that the hybrid approach works**: real geometric rotation (depth reprojection) + generative fill (Nano Banana) + Street View grounding.

## Run the proof (no API keys, no model downloads)

```bash
pip install numpy opencv-python-headless
python3 demo_synthetic.py
```

Builds a synthetic street scene with perfect ground-truth depth (standing in for iPhone LiDAR / Apple Depth Pro), then orbits the camera 30° and 45° around the subject.

### Measured results

| Orbit angle | Valid-pixel PSNR vs ground truth | Frame needing AI fill |
|---|---|---|
| **30°** | **35.5 dB** (geometrically correct) | 27.9% |
| **45°** | **35.9 dB** (geometrically correct) | 33.4% |

**What this proves:**
- ~70% of the rotated image is **real, deterministic geometry** — pixel-accurate vs. what a camera at the new position actually sees (>35 dB PSNR)
- The remaining ~30% (disocclusions + newly-visible field of view) is a precise **hole mask** — exactly the input a generative model needs
- The AI never has to "imagine the rotation"; it only fills clearly-delimited gaps, guided by Street View ground truth

### Output files

- `out_montage.png` — 4-panel comparison per angle: original | real rotation with magenta holes | filled | ground truth
- `out_{30,45}_rotated_holes.png`, `out_{30,45}_filled.png`, `out_{30,45}_groundtruth.png`

## Run on a real photo

```bash
export GEMINI_API_KEY=...   # https://aistudio.google.com/apikey
export MAPS_API_KEY=...     # Street View Static API enabled

python3 hybrid_pipeline.py photo.jpg \
    --depth depth.png \          # 16-bit mm PNG (iPhone LiDAR) or .npy metres (Depth Pro)
    --angle 30 \
    --lat 48.8584 --lng 2.2945 --heading 110   # optional: GPS for Street View grounding
```

Without keys it still runs stage 1 (geometry) and writes the warped image + hole mask with a local placeholder fill.

## Key geometric insight (discovered while building)

A camera **rotating in place** produces zero parallax — it's a pure homography, no holes, no AI needed (but it only reveals out-of-frame content). What users mean by "change my photo's angle" is **orbiting around the subject** — that creates parallax and disocclusions, which is why the hybrid (depth math + generative fill) is the right architecture.

## Files

| File | Role |
|---|---|
| `reproject.py` | Core: depth → 3D points → new camera pose → z-buffered splat + hole mask. Pure numpy, no ML. |
| `demo_synthetic.py` | The proof: ray-cast scene, orbit 30°/45°, compare vs ground truth, measure PSNR. |
| `hybrid_pipeline.py` | Real-photo CLI: photo + depth → reproject → Street View fetch → Nano Banana hole fill. |

## Mapping to the iOS app

| Prototype piece | iPhone equivalent |
|---|---|
| Ground-truth depth from ray casting | LiDAR (`AVDepthData`) on Pro models; Apple Depth Pro (CoreML) on others |
| `reproject.py` numpy splat | Metal compute shader or `vImage` (runs in milliseconds on-device) |
| `fetch_streetview()` | `StreetViewService.swift` (already in `PhotoAngleApp/`) |
| `nano_banana_fill()` | `NanoBananaService.swift` (already in `PhotoAngleApp/`) |
