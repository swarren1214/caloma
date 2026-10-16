"""Renders Caloma's stock screensaver wallpapers at iPad Pro resolution (2732 x 2048).

Each scene is painted from gradients, fractal noise ridgelines, light and haze, so they're
original artwork with no outside images. Run: python3 render.py [out_dir] [scale]
"""
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "out")
SCALE = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
W, H = int(2732 * SCALE), int(2048 * SCALE)
OUT.mkdir(parents=True, exist_ok=True)


# ---------- color helpers ----------

def hexrgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)], dtype=np.float32)


def to_lin(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def gradient(stops, t):
    """stops: [(pos, '#hex')], t: array 0..1 -> (..., 3) linear color."""
    pos = np.array([p for p, _ in stops], dtype=np.float32)
    cols = np.stack([to_lin(hexrgb(c)) for _, c in stops])
    t = np.clip(t, pos[0], pos[-1])
    out = np.empty(t.shape + (3,), dtype=np.float32)
    for k in range(3):
        out[..., k] = np.interp(t, pos, cols[:, k])
    return out


def lin(h):
    return to_lin(hexrgb(h))


# ---------- noise ----------

rng_master = np.random.default_rng(7)


def fbm1d(n, octaves=6, seed=0, base=4, persistence=0.5):
    rng = np.random.default_rng(seed)
    x = np.linspace(0, 1, n, dtype=np.float32)
    total = np.zeros(n, dtype=np.float32)
    amp, freq, norm = 1.0, base, 0.0
    for _ in range(octaves):
        pts = rng.random(int(freq) + 3).astype(np.float32)
        xs = x * freq
        i = np.floor(xs).astype(int)
        f = xs - i
        f = f * f * (3 - 2 * f)
        total += amp * (pts[i] * (1 - f) + pts[i + 1] * f)
        norm += amp
        amp *= persistence
        freq *= 2
    return total / norm


def fit(a, h=None, w=None):
    """Resample a 2D array to exactly h x w."""
    h = H if h is None else h
    w = W if w is None else w
    out = ndimage.zoom(a, (h / a.shape[0], w / a.shape[1]), order=1)
    out = out[:h, :w]
    if out.shape != (h, w):
        out = np.pad(out, ((0, h - out.shape[0]), (0, w - out.shape[1])), mode="edge")
    return out


def fbm2d(h, w, octaves=6, seed=0, base=3, persistence=0.5):
    rng = np.random.default_rng(seed)
    total = np.zeros((h, w), dtype=np.float32)
    amp, freq, norm = 1.0, base, 0.0
    for _ in range(octaves):
        gh, gw = int(freq * h / max(h, w)) + 3, int(freq * w / max(h, w)) + 3
        grid = rng.random((gh, gw)).astype(np.float32)
        layer = ndimage.zoom(grid, (h / (gh - 2), w / (gw - 2)), order=3)[:h, :w]
        if layer.shape != (h, w):
            layer = np.pad(layer, ((0, h - layer.shape[0]), (0, w - layer.shape[1])), mode="edge")
        total += amp * layer
        norm += amp
        amp *= persistence
        freq *= 2
    return total / norm


# ---------- shapes ----------

def polygon_mask(polys, ss=3, blur=0.0):
    img = Image.new("L", (W * ss, H * ss), 0)
    d = ImageDraw.Draw(img)
    for poly in polys:
        d.polygon([(x * ss, y * ss) for x, y in poly], fill=255)
    img = img.resize((W, H), Image.LANCZOS)
    if blur:
        img = img.filter(ImageFilter.GaussianBlur(blur * SCALE))
    return np.asarray(img, dtype=np.float32) / 255


def ridge(y_base, amp, seed, octaves=7, base=3, persistence=0.52, sharp=False):
    xs = np.arange(W + 1)
    n = fbm1d(W + 1, octaves, seed, base, persistence)
    if sharp:
        n = 1 - np.abs(n * 2 - 1)
    ys = y_base - (n - 0.5) * 2 * amp
    return ys


def ridge_poly(ys):
    pts = [(float(x), float(y)) for x, y in zip(range(len(ys)), ys)]
    return pts + [(W, H + 4), (0, H + 4)]


def blend(img, color, alpha):
    a = alpha[..., None] if alpha.ndim == 2 else alpha
    return img * (1 - a) + color * a


def vertical(stops, y0=0.0, y1=1.0):
    t = (np.arange(H, dtype=np.float32) / H - y0) / max(y1 - y0, 1e-6)
    col = gradient(stops, t)
    return np.broadcast_to(col[:, None, :], (H, W, 3)).copy()


YY, XX = np.mgrid[0:H, 0:W].astype(np.float32)


def glow(cx, cy, radius, color, strength=1.0, power=2.0):
    d = np.sqrt((XX - cx * W) ** 2 + (YY - cy * H) ** 2) / (radius * W)
    g = np.exp(-d ** power) * strength
    return g[..., None] * lin(color)


def layer_fill(mask, top_color, bottom_color, top_y, bottom_y):
    t = np.clip((YY - top_y) / max(bottom_y - top_y, 1), 0, 1)
    c = gradient([(0, top_color), (1, bottom_color)], t)
    return c, mask


def trees_along(ys, count, height, seed, x_from=0, x_to=None, jitter=0.6):
    rng = np.random.default_rng(seed)
    x_to = W if x_to is None else x_to
    polys = []
    xs = np.sort(rng.uniform(x_from, x_to, count))
    for x in xs:
        h = height * rng.uniform(1 - jitter / 2, 1 + jitter / 2)
        base_y = ys[int(np.clip(x, 0, W))] + h * 0.08
        w = h * rng.uniform(0.26, 0.34)
        tiers = 5
        pts_left, pts_right = [], []
        for k in range(tiers + 1):
            ty = base_y - h * k / tiers
            tw = w * (1 - k / tiers) ** 0.9
            pts_left.append((x - tw * (1.0 if k % 2 == 0 else 0.62), ty))
            pts_right.append((x + tw * (1.0 if k % 2 == 0 else 0.62), ty))
        poly = pts_left + [(x, base_y - h * 1.04)] + pts_right[::-1]
        polys.append(poly)
        polys.append([(x - w * 0.06, base_y), (x + w * 0.06, base_y), (x + w * 0.06, base_y + h * 0.12), (x - w * 0.06, base_y + h * 0.12)])
    return polys


def stars(img, count, seed, ymax=0.7, bright=1.0, sky_mask=None):
    rng = np.random.default_rng(seed)
    layer = np.zeros((H, W), dtype=np.float32)
    xs = rng.integers(0, W, count)
    ys = (rng.random(count) ** 1.4 * ymax * H).astype(int)
    mags = rng.random(count) ** 6
    np.add.at(layer, (ys, xs), 0.35 + mags * 2.2)
    layer = ndimage.gaussian_filter(layer, 0.7 * SCALE + 0.3) * 6
    big = mags > 0.6
    halo = np.zeros((H, W), dtype=np.float32)
    np.add.at(halo, (ys[big], xs[big]), mags[big] * 3)
    halo = ndimage.gaussian_filter(halo, 4 * SCALE) * 30
    s = (layer + halo) * bright
    if sky_mask is not None:
        s = s * sky_mask
    tint = np.stack([s * 0.95, s * 0.97, s * 1.05], -1)
    return img + tint


def finish(img, name, grain=0.012, vignette=0.22, seed=0):
    rng = np.random.default_rng(seed + 99)
    d = np.sqrt(((XX / W) - 0.5) ** 2 + ((YY / H) - 0.5) ** 2) / 0.72
    img = img * (1 - vignette * np.clip(d, 0, 1) ** 2.2)[..., None]
    srgb = to_srgb(img)
    srgb = srgb + rng.normal(0, grain, srgb.shape).astype(np.float32)
    out = (np.clip(srgb, 0, 1) * 255 + 0.5).astype(np.uint8)
    im = Image.fromarray(out, "RGB")
    path = OUT / f"{name}.jpg"
    im.save(path, quality=90, optimize=True, progressive=True, subsampling=0)
    print("wrote", path, f"{path.stat().st_size / 1e6:.2f} MB")


def reflect(img, horizon, water_top, water_bottom, ripple=6.0, seed=0, sun_x=None, sun_color="#FFD9A0"):
    """Mirror the scene above the horizon into water below it."""
    hz = int(horizon)
    rows = H - hz
    rng = np.random.default_rng(seed)
    out = img.copy()
    noise = fbm2d(rows, W, 5, seed + 3, base=6)
    for r in range(rows):
        src = hz - 1 - int(r * 0.92)
        if src < 0:
            src = 0
        depth = r / rows
        shift = (np.sin(np.arange(W) / (14 * SCALE + depth * 40 * SCALE) + r * 0.37) * ripple * SCALE * (0.3 + depth * 2)
                 + (noise[r] - 0.5) * ripple * 5 * SCALE * (0.2 + depth))
        idx = np.clip((np.arange(W) + shift).astype(int), 0, W - 1)
        out[hz + r] = img[src, idx]
    t = np.clip((YY - hz) / rows, 0, 1)
    water = gradient([(0, water_top), (1, water_bottom)], t)
    mix = (0.38 + 0.4 * t)[..., None]
    below = (YY >= hz)[..., None]
    out = np.where(below, out * (1 - mix) * 0.92 + water * mix, out)
    if sun_x is not None:
        streak_w = (0.025 + 0.12 * t) * W
        streak = np.exp(-((XX - sun_x * W) / streak_w) ** 2) * (1 - t) ** 1.2
        full = np.zeros((H, W), dtype=np.float32)
        full[hz:] = noise
        sparkle = (full > 0.62).astype(np.float32) * ((np.sin(YY * 0.9 / SCALE) > 0.3).astype(np.float32))
        spark = streak * (0.25 + 1.4 * sparkle) * (YY >= hz)
        out = out + spark[..., None] * lin(sun_color) * 0.55
    # A thin bright line where the water meets the land.
    edge = np.exp(-((YY - hz) / (2.5 * SCALE)) ** 2) * 0.12
    out = out + edge[..., None] * lin("#FFFFFF")
    return out


# ---------- scenes ----------

def dusk_lake():
    img = vertical([(0, "#141533"), (0.22, "#2E2A5C"), (0.42, "#6B4677"), (0.56, "#C76B6B"), (0.63, "#F2955E"), (0.68, "#FBC88A")])
    img += glow(0.63, 0.6, 0.22, "#FFD08A", 0.9, 1.4)
    img += glow(0.63, 0.6, 0.05, "#FFF1D2", 1.6, 2.0)
    clouds = fbm2d(H, W, 6, 11, base=4)
    band = np.exp(-((YY / H - 0.33) / 0.09) ** 2)
    stretch = fit(fbm2d(H // 4, W // 4, 5, 12, base=3))
    c = np.clip((clouds * 0.6 + stretch * 0.6 - 0.62) * 4, 0, 1) * band
    img = blend(img, lin("#F4A487") * 0.8, c * 0.55)
    img = stars(img, 500, 3, ymax=0.22, bright=0.22)
    horizon = 0.665 * H
    far = ridge(0.53 * H, 0.09 * H, 21, sharp=True)
    img = blend(img, lin("#8E5A7E"), polygon_mask([ridge_poly(far)]) * 0.9)
    mid = ridge(0.585 * H, 0.07 * H, 22, sharp=True, base=4)
    img = blend(img, lin("#5B3A5E"), polygon_mask([ridge_poly(mid)]))
    near = ridge(0.64 * H, 0.035 * H, 23, base=5)
    m = polygon_mask([ridge_poly(near)])
    img = blend(img, lin("#2C1E35"), m)
    tr = trees_along(near, 70, 0.05 * H, 24)
    img = blend(img, lin("#1E1427"), polygon_mask(tr))
    haze = np.exp(-((YY - 0.6 * H) / (0.05 * H)) ** 2)[..., None] * lin("#F7A77A") * 0.18
    img += haze
    img = reflect(img, horizon, "#C9705A", "#120C1C", ripple=5, seed=25, sun_x=0.63)
    return img


def alpine_morning():
    img = vertical([(0, "#7FA8C9"), (0.35, "#B9D3E0"), (0.55, "#E9EEE4"), (0.62, "#F5EBD8")])
    img += glow(0.28, 0.42, 0.35, "#FFF4D8", 0.6, 1.3)
    layers = [
        (0.47, 0.10, "#A4BCC6", 31, True, 0),
        (0.53, 0.085, "#86A3AE", 32, True, 0),
        (0.6, 0.07, "#62868F", 33, False, 90),
        (0.68, 0.06, "#3F6467", 34, False, 140),
        (0.78, 0.05, "#26453F", 35, False, 200),
        (0.9, 0.04, "#14281F", 36, False, 260),
    ]
    mist = fbm2d(H, W, 6, 37, base=5)
    for i, (yb, amp, col, seed, sharp, ntrees) in enumerate(layers):
        ys = ridge(yb * H, amp * H, seed, sharp=sharp, base=3 + i)
        m = polygon_mask([ridge_poly(ys)])
        # Each layer darkens a little toward its foot.
        shade = np.clip((YY - ys.min()) / (H * 0.25), 0, 1)[..., None]
        color = lin(col) * (1 - 0.25 * shade)
        img = blend(img, color, m)
        if ntrees:
            tr = trees_along(ys, ntrees, (0.035 + i * 0.012) * H, seed + 100)
            img = blend(img, lin(col) * 0.72, polygon_mask(tr))
        # Mist pooled in the valley above the next layer.
        band = np.exp(-((YY - (yb + 0.03) * H) / (0.035 * H)) ** 2)
        a = band * np.clip(mist * 1.6 - 0.35, 0, 1) * (0.55 - i * 0.06)
        img = blend(img, lin("#EEF2EC"), np.clip(a, 0, 1))
    rays = np.clip(np.sin((np.arctan2(YY - 0.42 * H, XX - 0.28 * W)) * 26) * 0.5 + 0.5, 0, 1) ** 6
    rays *= np.exp(-np.sqrt((XX - 0.28 * W) ** 2 + (YY - 0.42 * H) ** 2) / (0.5 * W)) * (YY > 0.42 * H)
    rays *= np.clip((0.6 * H - YY) / (0.12 * H), 0, 1)
    img += rays[..., None] * lin("#FFF2D0") * 0.035
    return img


def red_rock():
    img = vertical([(0, "#2B5E7C"), (0.28, "#6FA3B4"), (0.5, "#E8C49A"), (0.6, "#F4A564"), (0.66, "#F08A4B")])
    img += glow(0.78, 0.6, 0.25, "#FFC27A", 0.7, 1.5)
    img += glow(0.78, 0.6, 0.04, "#FFF0CC", 1.4, 2.0)

    def mesa(y_top, amp, seed, base=3):
        n = fbm1d(W + 1, 7, seed, base, 0.55)
        plateau = np.clip((n - 0.45) * 8, 0, 1)
        plateau = ndimage.gaussian_filter1d(plateau, 6 * SCALE)
        rough = (fbm1d(W + 1, 6, seed + 1, 40, 0.5) - 0.5) * amp * 0.08
        return y_top + (1 - plateau) * amp + rough

    far = mesa(0.5 * H, 0.1 * H, 41)
    img = blend(img, lin("#C98A73"), polygon_mask([ridge_poly(far)]) * 0.85)
    mid = mesa(0.56 * H, 0.1 * H, 42, base=4)
    m = polygon_mask([ridge_poly(mid)])
    strata = (np.sin(YY / (9 * SCALE) + fbm2d(H, W, 4, 43, base=8) * 6) * 0.5 + 0.5)
    face = lin("#A9482C") * (0.85 + 0.15 * strata[..., None])
    img = blend(img, face, m)
    lit = np.clip((XX / W - 0.35) * 2, 0, 1) * m * (YY < mid[np.clip(XX.astype(int), 0, W)] + 0.05 * H)
    img += lit[..., None] * lin("#FF9A5C") * 0.12
    near = mesa(0.68 * H, 0.05 * H, 44, base=5)
    img = blend(img, lin("#6E2A1A"), polygon_mask([ridge_poly(near)]))
    floor = np.clip((YY - 0.72 * H) / (0.28 * H), 0, 1)
    ground = gradient([(0, "#8C3A22"), (1, "#3A160E")], floor)
    gm = polygon_mask([ridge_poly(ridge(0.74 * H, 0.008 * H, 45, base=6))])
    img = blend(img, ground, gm)
    brush = fbm2d(H, W, 5, 46, base=40)
    dots = np.clip((brush - 0.66) * 6, 0, 1) * gm * (YY > 0.76 * H)
    img = blend(img, lin("#3E2A18"), dots * 0.7)
    img += np.exp(-((YY - 0.69 * H) / (0.03 * H)) ** 2)[..., None] * lin("#FFB07A") * 0.08
    return img


def aurora():
    img = vertical([(0, "#03060F"), (0.4, "#08142A"), (0.7, "#11284A"), (0.78, "#1C3B5E")])
    sky = np.ones((H, W), dtype=np.float32)
    img = stars(img, 2200, 51, ymax=0.78, bright=0.8)
    # Curtains: vertical streaks along a wandering ribbon.
    path = 0.3 * H + (fbm1d(W, 6, 52, 2, 0.5) - 0.5) * 0.35 * H
    streak = fbm1d(W, 6, 53, 120, 0.6)
    for k, (col, off, width, strength) in enumerate([("#3DF2A2", 0, 0.12, 1.0), ("#2BD0C8", 0.06, 0.09, 0.6), ("#A05BFF", -0.09, 0.07, 0.45)]):
        center = path + off * H
        dy = (YY - center[None, :]) / (width * H)
        body = np.exp(-np.clip(dy, 0, None) ** 2 * 1.2) * np.exp(-np.clip(-dy, 0, None) ** 2 * 6)
        rays = np.clip(streak[None, :] * 1.8 - 0.4, 0, 1) ** 1.5
        flicker = fbm2d(H, W, 4, 54 + k, base=5)
        a = body * (0.35 + 0.65 * rays) * (0.6 + 0.6 * flicker) * strength
        img += a[..., None] * lin(col) * 0.75
    img += glow(0.5, 0.82, 0.6, "#2E5F7E", 0.25, 1.2)
    hills = ridge(0.8 * H, 0.05 * H, 55, base=2, persistence=0.4)
    hm = polygon_mask([ridge_poly(hills)])
    snow_t = np.clip((YY - hills.min()) / (0.25 * H), 0, 1)
    snow = gradient([(0, "#9DB7D3"), (0.4, "#5C7A9B"), (1, "#26384F")], snow_t)
    img = blend(img, snow, hm)
    tr = trees_along(hills, 60, 0.07 * H, 56)
    img = blend(img, lin("#060A12"), polygon_mask(tr))
    near = ridge(0.92 * H, 0.03 * H, 57, base=3, persistence=0.4)
    img = blend(img, gradient([(0, "#7F9BBB"), (1, "#30445C")], np.clip((YY - 0.9 * H) / (0.1 * H), 0, 1)), polygon_mask([ridge_poly(near)]))
    cx, cy = 0.24 * W, hills[int(0.24 * W)] + 0.005 * H
    cabin = [(cx - 0.035 * W, cy), (cx - 0.035 * W, cy - 0.04 * H), (cx, cy - 0.075 * H), (cx + 0.035 * W, cy - 0.04 * H), (cx + 0.035 * W, cy)]
    img = blend(img, lin("#0B0F18"), polygon_mask([cabin]))
    win = [(cx - 0.012 * W, cy - 0.012 * H), (cx - 0.012 * W, cy - 0.032 * H), (cx + 0.004 * W, cy - 0.032 * H), (cx + 0.004 * W, cy - 0.012 * H)]
    img = blend(img, lin("#FFC46B") * 1.3, polygon_mask([win]))
    img += glow(cx / W, (cy - 0.022 * H) / H, 0.05, "#FFB04A", 0.45, 1.6)
    return img


def ocean_calm():
    img = vertical([(0, "#5D86B8"), (0.3, "#9EBBD9"), (0.5, "#E9D4D2"), (0.58, "#F7DCC4")])
    img += glow(0.42, 0.57, 0.3, "#FFE6C8", 0.6, 1.4)
    cl = fbm2d(H, W, 7, 61, base=3)
    cl2 = fit(fbm2d(H // 3, W // 3, 5, 62, base=2))
    band = np.exp(-((YY / H - 0.3) / 0.12) ** 2)
    density = np.clip((cl * 0.5 + cl2 * 0.7 - 0.73) * 6.5, 0, 1) * band
    top_lit = np.clip(1 - (ndimage.gaussian_filter(density, 6 * SCALE) - density) * 6, 0.6, 1.05)
    base_col = gradient([(0, "#8F86A8"), (0.6, "#E4CCD4"), (1, "#FFF6EE")], np.clip(top_lit - 0.4, 0, 1) / 0.65)
    under = np.clip(ndimage.shift(density, (-10 * SCALE, 0), order=1) - density * 0.5, 0, 1)
    cloud = base_col * (1 - 0.35 * under[..., None])
    img = blend(img, cloud, density * 0.95)
    horizon = 0.585 * H
    t = np.clip((YY - horizon) / (H - horizon), 0, 1)
    sea = gradient([(0, "#A9B9D0"), (0.25, "#5F86AE"), (1, "#173A5E")], t)
    waves = fbm2d(H, W, 6, 63, base=8)
    lines = np.sin(YY / (2.2 * SCALE + t * 14 * SCALE) + waves * 9) * 0.5 + 0.5
    sea = sea * (0.92 + 0.12 * lines[..., None])
    streak = np.exp(-((XX - 0.42 * W) / ((0.03 + 0.16 * t) * W)) ** 2) * (1 - t) ** 1.4
    glint = streak * np.clip(lines * 2 - 1.2, 0, 1)
    sea += glint[..., None] * lin("#FFE9CC") * 0.9
    img = np.where((YY >= horizon)[..., None], sea, img)
    img += np.exp(-((YY - horizon) / (3 * SCALE)) ** 2)[..., None] * lin("#FFFFFF") * 0.15
    return img


def autumn_hills():
    img = vertical([(0, "#E7B88A"), (0.35, "#F2CFA3"), (0.5, "#F7DDBA")])
    img += glow(0.7, 0.32, 0.3, "#FFF0D2", 0.55, 1.3)
    cols = ["#D9A27D", "#C97B4F", "#B3562F", "#8F3B22", "#6A2717", "#3E160D"]
    fog = fbm2d(H, W, 6, 71, base=4)
    for i, col in enumerate(cols):
        yb = 0.42 + i * 0.09
        ys = ridge(yb * H, (0.05 + i * 0.008) * H, 72 + i, base=2 + i * 0.5, persistence=0.45)
        # Tree canopy: a bumpy edge along the top of each hill.
        bumps = np.abs(np.sin(np.arange(W + 1) / ((5 + i * 3) * SCALE) + fbm1d(W + 1, 3, 200 + i, 30) * 8))
        ys = ys - bumps * (0.003 + i * 0.0015) * H
        m = polygon_mask([ridge_poly(ys)])
        canopy = fbm2d(H, W, 5, 80 + i, base=12 + i * 4)
        tex = (0.93 + 0.14 * canopy)[..., None]
        # The top of each hill catches the light; its foot sits in shade.
        ridge_top = np.clip((YY - ys[np.clip(XX.astype(int), 0, W)]) / (0.12 * H), 0, 1)[..., None]
        shade = 1.08 - 0.3 * ridge_top
        color = lin(col) * tex * shade
        img = blend(img, color, m)
        band = np.exp(-((YY - (yb + 0.04) * H) / (0.03 * H)) ** 2)
        img = blend(img, lin("#F6E3C8"), np.clip(band * (fog * 1.4 - 0.3) * (0.45 - i * 0.06), 0, 1))
    return img


def hearth_glow():
    img = np.zeros((H, W, 3), dtype=np.float32) + lin("#2A0F1E")
    blobs = [
        (0.22, 0.28, 0.42, "#E0284F", 0.9),
        (0.72, 0.22, 0.38, "#FF7A59", 0.85),
        (0.55, 0.7, 0.5, "#7A2A6B", 0.9),
        (0.12, 0.85, 0.35, "#FF9F0A", 0.55),
        (0.9, 0.78, 0.33, "#C2185B", 0.7),
        (0.45, 0.42, 0.25, "#FFC2A6", 0.45),
    ]
    warp = fbm2d(H, W, 4, 91, base=2)
    for cx, cy, r, col, s in blobs:
        d = np.sqrt(((XX / W - cx) * 1.0 + (warp - 0.5) * 0.25) ** 2 + ((YY / H - cy) * 0.75 + (warp - 0.5) * 0.2) ** 2) / r
        a = np.exp(-d ** 2 * 2.2) * s
        img = img * (1 - a[..., None] * 0.6) + lin(col) * a[..., None]
    sheen = np.clip(np.sin((XX / W * 3 + YY / H * 2 + warp * 3) * math.pi) * 0.5 + 0.5, 0, 1) ** 8
    img += sheen[..., None] * lin("#FFE2D6") * 0.0
    return img


def milky_way():
    img = vertical([(0, "#02030A"), (0.55, "#070C1F"), (0.8, "#162244"), (0.86, "#3A3150")])
    img = stars(img, 2600, 101, ymax=0.85, bright=0.7)
    # A band running corner to corner.
    # A band running from the lower left up to the top right, in screen-shaped units.
    px, py = XX / W, YY / W
    ax, ay, bx, by = 0.12, 0.72, 0.9, -0.05
    dx, dy = bx - ax, by - ay
    length = math.hypot(dx, dy)
    u = ((px - ax) * dx + (py - ay) * dy) / length ** 2
    v = 0.48 + ((px - ax) * dy - (py - ay) * dx) / length
    band = np.exp(-((v - 0.48) / 0.085) ** 2)
    dust = fbm2d(H, W, 7, 102, base=6)
    lanes = np.clip((fbm2d(H, W, 6, 103, base=10) - 0.48) * 4, 0, 1)
    glowc = band * (0.35 + dust * 0.9) * (1 - lanes * 0.75 * np.exp(-((v - 0.48) / 0.05) ** 2))
    img += glowc[..., None] * (lin("#AEB8F0") * 0.42 + lin("#FFD2A6") * 0.3 * np.exp(-((u - 0.45) / 0.25) ** 2)[..., None])
    extra = np.random.default_rng(104)
    img = stars(img, 6000, 105, ymax=0.85, bright=0.35, sky_mask=np.clip(band * 1.5, 0, 1))
    img += glow(0.62, 0.9, 0.5, "#6B4E7A", 0.35, 1.2)
    far = ridge(0.8 * H, 0.06 * H, 106, sharp=True)
    img = blend(img, lin("#1A1830"), polygon_mask([ridge_poly(far)]))
    near = ridge(0.88 * H, 0.05 * H, 107, base=4)
    img = blend(img, lin("#07060E"), polygon_mask([ridge_poly(near)]))
    tr = trees_along(near, 40, 0.06 * H, 108)
    img = blend(img, lin("#050409"), polygon_mask(tr))
    return img


SCENES = {
    "wallpaper-dusk-lake": dusk_lake,
    "wallpaper-alpine-morning": alpine_morning,
    "wallpaper-red-rock": red_rock,
    "wallpaper-northern-lights": aurora,
    "wallpaper-ocean-calm": ocean_calm,
    "wallpaper-autumn-hills": autumn_hills,
    "wallpaper-hearth-glow": hearth_glow,
    "wallpaper-milky-way": milky_way,
}

if __name__ == "__main__":
    only = sys.argv[3].split(",") if len(sys.argv) > 3 else None
    for i, (name, fn) in enumerate(SCENES.items()):
        if only and name not in only:
            continue
        finish(fn(), name, seed=i, vignette=0.12 if "hearth" in name else 0.22)
