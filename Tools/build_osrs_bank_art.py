"""Generate crisp OSRS Bank textures inside the public Organiser module."""
from __future__ import annotations

import math
import random
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
ART_DIR = ROOT / "Modules" / "Organiser" / "art"


def _noise_panel(w: int, h: int, base: tuple[int, int, int], seed: int, variance: int = 5) -> Image.Image:
    rng = random.Random(seed)
    img = Image.new("RGBA", (w, h), (*base, 255))
    px = img.load()
    for y in range(h):
        for x in range(w):
            delta = rng.randint(-variance, variance)
            # Subtle coarse mottled patches
            patch = ((x // 4 + y // 4 * 7 + seed) % 5) - 2
            r = max(0, min(255, base[0] + delta + patch))
            g = max(0, min(255, base[1] + delta + patch))
            b = max(0, min(255, base[2] + delta + patch))
            px[x, y] = (r, g, b, 255)
    return img


def _bevel(img: Image.Image, hi: tuple[int, int, int, int], lo: tuple[int, int, int, int], outer: tuple[int, int, int, int], thickness: int = 2, open_bottom: bool = False) -> Image.Image:
    w, h = img.size
    d = ImageDraw.Draw(img)
    # 1px dark outer outline
    d.line([(0, 0), (w - 1, 0)], fill=outer)
    d.line([(0, 0), (0, h - 1)], fill=outer)
    d.line([(w - 1, 0), (w - 1, h - 1)], fill=outer)
    if not open_bottom:
        d.line([(0, h - 1), (w - 1, h - 1)], fill=outer)
    # Bevel highlights / shadows
    for t in range(1, thickness + 1):
        d.line([(t, t), (w - 1 - t, t)], fill=hi)
        d.line([(t, t), (t, h - 1 - (0 if open_bottom else t))], fill=hi)
        d.line([(w - 1 - t, t), (w - 1 - t, h - 1 - (0 if open_bottom else t))], fill=lo)
        if not open_bottom:
            d.line([(t, h - 1 - t), (w - 1 - t, h - 1 - t)], fill=lo)
    return img


def build_all() -> list[Path]:
    ART_DIR.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []

    # 1. Main OSRS bank stone frame
    frame = _noise_panel(256, 256, (73, 64, 52), seed=101, variance=6)
    _bevel(frame, (116, 102, 83, 255), (42, 35, 28, 255), (22, 18, 14, 255), thickness=3)
    p = ART_DIR / "osrs_bank_frame.png"
    frame.save(p)
    written.append(p)

    # 2. Tabs (idle & active with open bottom border)
    tab_idle = _noise_panel(64, 48, (64, 55, 44), seed=202, variance=4)
    _bevel(tab_idle, (96, 84, 68, 255), (36, 30, 23, 255), (22, 18, 14, 255), thickness=2, open_bottom=False)
    p = ART_DIR / "osrs_bank_tab_idle.png"
    tab_idle.save(p)
    written.append(p)

    tab_act = _noise_panel(64, 48, (86, 75, 61), seed=203, variance=4)
    _bevel(tab_act, (132, 116, 95, 255), (48, 40, 31, 255), (22, 18, 14, 255), thickness=2, open_bottom=True)
    p = ART_DIR / "osrs_bank_tab_active.png"
    tab_act.save(p)
    written.append(p)

    # 3. Recessed item slot & warm gold hover/active slot
    slot = _noise_panel(64, 64, (58, 50, 40), seed=301, variance=3)
    _bevel(slot, (41, 35, 28, 255), (84, 73, 59, 255), (30, 25, 19, 255), thickness=1)
    p = ART_DIR / "osrs_bank_slot.png"
    slot.save(p)
    written.append(p)

    slot_hot = _noise_panel(64, 64, (96, 78, 54), seed=302, variance=3)
    _bevel(slot_hot, (226, 178, 72, 255), (140, 102, 34, 255), (42, 28, 14, 255), thickness=2)
    p = ART_DIR / "osrs_bank_slot_hot.png"
    slot_hot.save(p)
    written.append(p)

    # 4. OSRS stone button & crimson active button
    btn = _noise_panel(128, 36, (72, 62, 50), seed=401, variance=4)
    _bevel(btn, (118, 104, 86, 255), (40, 33, 25, 255), (20, 16, 12, 255), thickness=2)
    p = ART_DIR / "osrs_bank_btn_stone.png"
    btn.save(p)
    written.append(p)

    btn_red = _noise_panel(128, 36, (148, 34, 28), seed=402, variance=5)
    _bevel(btn_red, (198, 66, 56, 255), (84, 18, 14, 255), (32, 8, 6, 255), thickness=2)
    p = ART_DIR / "osrs_bank_btn_red.png"
    btn_red.save(p)
    written.append(p)

    # 5. Crisp infinity (ALL tab) icon
    inf = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    idraw = ImageDraw.Draw(inf)
    pts: list[tuple[int, int]] = []
    for step in range(180):
        t = (step / 180.0) * 2.0 * math.pi
        denom = 1.0 + math.sin(t) ** 2
        x = 16.0 + 10.5 * math.cos(t) / denom
        y = 16.0 + 7.5 * math.sin(t) * math.cos(t) / denom
        pts.append((round(x), round(y)))
    for px_x, px_y in pts:
        idraw.ellipse([px_x - 2, px_y - 2, px_x + 2, px_y + 2], fill=(22, 18, 14, 255))
    for px_x, px_y in pts:
        idraw.ellipse([px_x - 1, px_y - 1, px_x + 1, px_y + 1], fill=(214, 210, 200, 255))
    p = ART_DIR / "osrs_bank_infinity.png"
    inf.save(p)
    written.append(p)

    # 6. Crisp OSRS deposit bag icon (brown pouch + green arrow)
    bag = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bag)
    bd.ellipse([4, 9, 22, 27], fill=(128, 86, 48, 255), outline=(22, 16, 10, 255), width=2)
    bd.polygon([(8, 10), (18, 10), (16, 5), (10, 5)], fill=(154, 108, 64, 255), outline=(22, 16, 10, 255))
    bd.line([(9, 10), (17, 10)], fill=(232, 188, 72, 255), width=2)
    # Green deposit arrow bottom-right
    bd.polygon([(17, 19), (24, 19), (24, 15), (30, 22), (24, 29), (24, 25), (17, 25)],
               fill=(78, 206, 86, 255), outline=(14, 48, 16, 255))
    p = ART_DIR / "osrs_bank_deposit.png"
    bag.save(p)
    written.append(p)

    # 7. Crisp OSRS search magnifying glass
    srch = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    sd = ImageDraw.Draw(srch)
    sd.line([(17, 17), (27, 27)], fill=(20, 15, 10, 255), width=6)
    sd.line([(17, 17), (26, 26)], fill=(150, 104, 58, 255), width=3)
    sd.ellipse([4, 4, 20, 20], fill=(176, 206, 224, 230), outline=(36, 32, 28, 255), width=3)
    sd.arc([7, 7, 17, 17], start=200, end=290, fill=(255, 255, 255, 220), width=2)
    p = ART_DIR / "osrs_bank_search.png"
    srch.save(p)
    written.append(p)

    # 8. Seamless mottled OSRS stone background tile (no baked borders so bevels never stretch)
    stone_bg = _noise_panel(256, 256, (73, 64, 52), seed=107, variance=5)
    p = ART_DIR / "osrs_bank_stone_bg.png"
    stone_bg.save(p)
    written.append(p)

    # 9. Crisp OSRS wrench settings icon
    wr = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    wd = ImageDraw.Draw(wr)
    wd.line([(8, 24), (20, 12)], fill=(18, 14, 10, 255), width=7)
    wd.line([(8, 24), (20, 12)], fill=(176, 176, 182, 255), width=4)
    wd.ellipse([16, 4, 28, 16], fill=(176, 176, 182, 255), outline=(18, 14, 10, 255), width=2)
    wd.polygon([(21, 5), (27, 11), (25, 13), (19, 7)], fill=(0, 0, 0, 0))
    p = ART_DIR / "osrs_bank_wrench.png"
    wr.save(p)
    written.append(p)

    # 10. Crisp OSRS gold padlock / pin icon
    pin = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    pd = ImageDraw.Draw(pin)
    pd.arc([9, 4, 23, 18], start=180, end=360, fill=(22, 16, 10, 255), width=5)
    pd.arc([10, 5, 22, 17], start=180, end=360, fill=(228, 182, 62, 255), width=2)
    pd.rectangle([7, 13, 25, 27], fill=(228, 182, 62, 255), outline=(22, 16, 10, 255), width=2)
    pd.ellipse([14, 17, 18, 21], fill=(22, 16, 10, 255))
    pd.rectangle([15, 19, 17, 24], fill=(22, 16, 10, 255))
    p = ART_DIR / "osrs_bank_pin.png"
    pin.save(p)
    written.append(p)

    # 11. Crisp OSRS stone X close icon
    cls_ic = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    cd = ImageDraw.Draw(cls_ic)
    cd.line([(8, 8), (24, 24)], fill=(20, 14, 10, 255), width=6)
    cd.line([(24, 8), (8, 24)], fill=(20, 14, 10, 255), width=6)
    cd.line([(8, 8), (24, 24)], fill=(214, 172, 118, 255), width=3)
    cd.line([(24, 8), (8, 24)], fill=(214, 172, 118, 255), width=3)
    p = ART_DIR / "osrs_bank_close.png"
    cls_ic.save(p)
    written.append(p)

    return written


if __name__ == "__main__":
    out = build_all()
    print(f"Generated {len(out)} OSRS Bank textures in {ART_DIR}")
