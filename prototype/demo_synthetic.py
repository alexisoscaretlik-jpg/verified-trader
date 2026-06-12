"""
PROOF-OF-CONCEPT for the hybrid photo-angle-change pipeline.

Builds a synthetic street scene (ground, two buildings, a close sign post,
sky) by ray casting, so we have a photo AND perfect ground-truth depth —
the same data an iPhone LiDAR / Apple Depth Pro would provide for a real
photo.

For 30° and 45° orbits around the subject it produces:
  1. the original view
  2. the REAL geometric view change (depth reprojection) with holes shown
     in magenta — areas with no source data  ← stage 1 of the hybrid
  3. a quick local inpaint as a stand-in for the Nano Banana fill ← stage 2
  4. the GROUND TRUTH render from the new viewpoint (what a camera would
     actually have seen there) — to measure how correct the reprojection is

It prints PSNR between the reprojected pixels and ground truth on the
valid (non-hole) region: high PSNR proves the view change is geometrically
real, not hallucinated.

Run:  python3 demo_synthetic.py
"""
import numpy as np
import cv2

from reproject import intrinsics, camera_pose, reproject

W, H = 960, 640
FOV = 70.0
SKY_DEPTH = 60.0
ORBIT_D = 8.0          # subject pivot distance (m) — the near building


# ---------------------------------------------------------------- scene ---
def raycast_scene(yaw_deg: float = 0.0, orbit_distance: float | None = None):
    """Ray-cast the synthetic street scene from camera pose (yaw, orbit).
    Returns (rgb uint8 HxWx3, depth float HxW) — depth is camera-frame z."""
    fx, fy, cx, cy = intrinsics(W, H, FOV)
    R, C = camera_pose(yaw_deg, orbit_distance)

    us, vs = np.meshgrid(np.arange(W), np.arange(H))
    d_cam = np.stack([(us - cx) / fx, (vs - cy) / fy, np.ones((H, W))], -1)
    d = d_cam @ R.T                      # ray dirs in world frame
    O = C                                # ray origin (camera centre)

    dx, dy, dz = d[..., 0], d[..., 1], d[..., 2]
    t_best = np.full((H, W), np.inf)
    rgb = np.zeros((H, W, 3), np.uint8)

    def shade(t, mask, colors):
        with np.errstate(invalid="ignore"):
            hit = mask & (t < t_best) & (t > 1e-6)
        t_best[hit] = t[hit]
        rgb[hit] = colors[hit]

    # --- sky (background) ---
    grad = np.clip(vs / H, 0, 1)[..., None]
    rgb[:] = ((1 - grad) * np.array([120, 170, 235]) +
              grad * np.array([215, 230, 248])).astype(np.uint8)

    with np.errstate(divide="ignore", invalid="ignore"):
        # --- ground plane: y = +1.5 m (camera 1.5 m above ground, y down) ---
        t = np.where(dy > 1e-6, (1.5 - O[1]) / dy, np.inf)
        p = O + t[..., None] * d
        in_b = (np.abs(p[..., 0]) <= 45) & (p[..., 2] > 0) & (p[..., 2] <= 50)
        checker = (np.nan_to_num(np.floor(p[..., 0] / 2) +
                                 np.floor(p[..., 2] / 2)) % 2).astype(bool)
        g = np.zeros((H, W, 3), np.uint8)
        g[checker] = (168, 162, 150)
        g[~checker] = (110, 106, 98)
        shade(t, in_b, g)

        def facade(z_plane, x0, x1, y0, base, glass, cell=1.3):
            """Vertical wall at z=z_plane, x∈[x0,x1], y∈[y0, 1.5]."""
            t = np.where(dz > 1e-6, (z_plane - O[2]) / dz, np.inf)
            p = O + t[..., None] * d
            m = ((p[..., 0] >= x0) & (p[..., 0] <= x1) &
                 (p[..., 1] >= y0) & (p[..., 1] <= 1.5))
            fu = (p[..., 0] - x0) / cell % 1.0
            fv = (p[..., 1] - y0) / cell % 1.0
            win = (fu > 0.18) & (fu < 0.82) & (fv > 0.18) & (fv < 0.72)
            c = np.zeros((H, W, 3), np.uint8)
            c[:] = base
            c[win] = glass
            shade(t, m, c)

        # --- far building (right side, z = 14 m) ---
        facade(14.0, 0.0, 10.0, -6.0, base=(96, 104, 118), glass=(196, 170, 120))
        # --- near building (left side, z = 8 m) ---
        facade(8.0, -8.0, -0.6, -4.0, base=(176, 84, 62), glass=(70, 92, 120))

        # --- close sign post (z = 4 m) — the big disocclusion maker ---
        t = np.where(dz > 1e-6, (4.0 - O[2]) / dz, np.inf)
        p = O + t[..., None] * d
        m = ((p[..., 0] >= 1.0) & (p[..., 0] <= 1.7) &
             (p[..., 1] >= -1.3) & (p[..., 1] <= 1.5))
        c = np.zeros((H, W, 3), np.uint8)
        c[:] = (46, 160, 88)
        stripe = (np.nan_to_num(p[..., 1] * 4) % 2 < 1)
        c[m & stripe] = (240, 240, 240)
        shade(t, m, c)

    depth = np.where(np.isfinite(t_best), t_best, SKY_DEPTH)
    return rgb, depth


# ---------------------------------------------------------------- utils ---
def psnr(a, b, mask):
    """PSNR on `mask` after eroding it 2 px (excludes splat-edge aliasing)
    and a light blur (standard for resampling comparisons)."""
    m = cv2.erode(mask.astype(np.uint8), np.ones((5, 5), np.uint8)).astype(bool)
    ab = cv2.GaussianBlur(a, (3, 3), 0).astype(float)
    bb = cv2.GaussianBlur(b, (3, 3), 0).astype(float)
    diff = (ab - bb)[m]
    mse = np.mean(diff ** 2)
    return 99.0 if mse < 1e-9 else 10 * np.log10(255.0 ** 2 / mse)


def label(img, text):
    out = img.copy()
    cv2.rectangle(out, (0, 0), (out.shape[1], 34), (0, 0, 0), -1)
    cv2.putText(out, text, (10, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.62,
                (255, 255, 255), 2, cv2.LINE_AA)
    return out


def save(path, rgb):
    cv2.imwrite(path, cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR))


# ----------------------------------------------------------------- main ---
def run(angle):
    print(f"\n=== Orbit around subject: {angle}° ===")
    rgb0, depth0 = raycast_scene()

    # STAGE 1 — real geometric view change via depth reprojection
    warped, holes = reproject(rgb0, depth0, angle, FOV, orbit_distance=ORBIT_D)

    shown = warped.copy()
    shown[holes] = (255, 0, 220)                      # magenta = no data

    # STAGE 2 stand-in — local inpaint where Nano Banana would fill.
    # (In production this is the Gemini API call with the Street View
    #  reference; cv2.inpaint just proves the mask plumbing end-to-end.)
    mask8 = (holes * 255).astype(np.uint8)
    filled = cv2.inpaint(cv2.cvtColor(warped, cv2.COLOR_RGB2BGR), mask8,
                         5, cv2.INPAINT_TELEA)
    filled = cv2.cvtColor(filled, cv2.COLOR_BGR2RGB)

    # GROUND TRUTH — what a real camera on the orbit actually sees
    gt, _ = raycast_scene(angle, orbit_distance=ORBIT_D)

    valid = ~holes
    score = psnr(warped, gt, valid)
    hole_pct = 100.0 * holes.mean()
    print(f"  valid-pixel PSNR vs ground truth: {score:.1f} dB "
          f"(>30 dB = geometrically correct)")
    print(f"  holes needing generative fill: {hole_pct:.1f}% of frame")

    row = np.hstack([
        label(rgb0,   "1. ORIGINAL photo"),
        label(shown,  f"2. REAL +{angle} deg view change (magenta = holes)"),
        label(filled, "3. holes filled (Nano Banana slot)"),
        label(gt,     f"4. GROUND TRUTH at +{angle} deg"),
    ])
    cv2.putText(row, f"valid-pixel PSNR {score:.1f} dB | holes {hole_pct:.1f}%",
                (10, H - 14), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                (0, 255, 80), 2, cv2.LINE_AA)
    return row, rgb0, shown, filled, gt


if __name__ == "__main__":
    rows = []
    for angle in (30, 45):
        row, rgb0, shown, filled, gt = run(angle)
        rows.append(row)
        save(f"out_{angle}_rotated_holes.png", shown)
        save(f"out_{angle}_filled.png", filled)
        save(f"out_{angle}_groundtruth.png", gt)

    save("out_original.png", rgb0)
    montage = np.vstack(rows)
    save("out_montage.png", montage)
    print("\nWrote: out_original.png, out_{30,45}_rotated_holes.png, "
          "out_{30,45}_filled.png, out_{30,45}_groundtruth.png, out_montage.png")
