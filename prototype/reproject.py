"""
Core of the hybrid angle-change pipeline: REAL geometric view change.

Given an RGB image + per-pixel depth + camera intrinsics, move the virtual
camera and re-render the image from the new viewpoint via 3D reprojection
with a z-buffer.

Two modes:
  * yaw only (orbit_distance=None): camera rotates in place. Pure rotation
    has no parallax — it is exact (a homography) and only reveals
    out-of-frame content.
  * orbit (orbit_distance=D): camera orbits the subject located D metres
    ahead, keeping it centred — this is what "see my photo from 30° to the
    side" actually means. Orbiting creates parallax, so areas hidden behind
    foreground objects become visible with NO image data: the disocclusion
    holes that stage 2 (Nano Banana + Street View reference) fills in.

No ML here. Pure projective geometry — deterministic and geometrically
correct by construction.
"""
import numpy as np


def intrinsics(w: int, h: int, fov_x_deg: float = 70.0):
    """Pinhole intrinsics from horizontal field of view (iPhone main cam ≈ 69-73°)."""
    fx = (w / 2.0) / np.tan(np.radians(fov_x_deg) / 2.0)
    return fx, fx, w / 2.0, h / 2.0


def rot_y(deg: float) -> np.ndarray:
    """Rotation around the vertical axis (camera yaw). +deg = look right."""
    t = np.radians(deg)
    c, s = np.cos(t), np.sin(t)
    return np.array([[c, 0.0, s],
                     [0.0, 1.0, 0.0],
                     [-s, 0.0, c]])


def camera_pose(yaw_deg: float, orbit_distance: float | None):
    """Pose (R, C) of the new camera in the original camera's frame.

    R: orientation (world->cam uses R^T), C: camera centre.
    Orbit: pivot P=(0,0,D); the camera stays at distance D from P,
    rotated yaw_deg around the vertical axis through P, looking at P.
    """
    R = rot_y(yaw_deg)
    if orbit_distance is None:
        C = np.zeros(3)
    else:
        P = np.array([0.0, 0.0, orbit_distance])
        C = P - R @ np.array([0.0, 0.0, orbit_distance])
    return R, C


def reproject(rgb: np.ndarray, depth: np.ndarray, yaw_deg: float,
              fov_x_deg: float = 70.0, orbit_distance: float | None = None):
    """
    Re-render `rgb` as seen by the camera at pose (R, C).

    Returns:
        out:   (H,W,3) uint8 — the new view (zeros where no data)
        holes: (H,W)  bool   — True where the new view has no source pixel
    """
    h, w = depth.shape
    fx, fy, cx, cy = intrinsics(w, h, fov_x_deg)

    # Back-project every pixel to a 3D point in the original camera frame
    us, vs = np.meshgrid(np.arange(w), np.arange(h))
    xn = (us - cx) / fx
    yn = (vs - cy) / fy
    pts = np.stack([xn * depth, yn * depth, depth], axis=-1).reshape(-1, 3)
    cols = rgb.reshape(-1, 3)

    ok = pts[:, 2] > 1e-6
    pts, cols = pts[ok], cols[ok]

    # Transform into the new camera frame: p_new = R^T (p - C)
    R, C = camera_pose(yaw_deg, orbit_distance)
    p2 = (pts - C) @ R          # (R.T @ x) for row vectors == x @ R
    z2 = p2[:, 2]
    front = z2 > 1e-6
    p2, cols, z2 = p2[front], cols[front], z2[front]

    # Project into the new image plane
    u2 = fx * p2[:, 0] / z2 + cx
    v2 = fy * p2[:, 1] / z2 + cy

    out = np.zeros((h, w, 3), np.uint8)
    zbuf = np.full((h, w), np.inf)

    u0 = np.floor(u2).astype(int)
    v0 = np.floor(v2).astype(int)

    # Pass 1: z-buffer — nearest depth wins at every target pixel.
    # Splatting into the 2x2 neighborhood closes sub-pixel resampling
    # cracks while leaving true disocclusions open.
    for du in (0, 1):
        for dv in (0, 1):
            ui, vi = u0 + du, v0 + dv
            m = (ui >= 0) & (ui < w) & (vi >= 0) & (vi < h)
            np.minimum.at(zbuf, (vi[m], ui[m]), z2[m])

    # Pass 2: write colors for the points that won the z-test
    for du in (0, 1):
        for dv in (0, 1):
            ui, vi = u0 + du, v0 + dv
            m = (ui >= 0) & (ui < w) & (vi >= 0) & (vi < h)
            sel = np.where(m)[0]
            keep = sel[z2[sel] <= zbuf[vi[sel], ui[sel]] * 1.002]
            out[vi[keep], ui[keep]] = cols[keep]

    holes = ~np.isfinite(zbuf)
    return out, holes
