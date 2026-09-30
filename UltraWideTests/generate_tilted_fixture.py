"""Render a textured plane seen by a tilted 16:9 camera for the native test.

Requires NumPy and Pillow. Generates synthetic scene data, not user photos.
"""
from pathlib import Path
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter


def generate():
    rng = np.random.default_rng(23)
    world = Image.fromarray(rng.integers(30, 220, (5000, 5000, 3), dtype=np.uint8))
    world = world.filter(ImageFilter.GaussianBlur(1.5))
    draw = ImageDraw.Draw(world)
    for _ in range(1200):
        x, y = rng.integers(0, 5000, 2)
        radius = int(rng.integers(5, 40))
        color = tuple(int(v) for v in rng.integers(10, 245, 3))
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)
    texture = np.asarray(world)
    width, height = 540, 960
    horizontal = 2 * math.atan(math.tan(math.radians(35)) / (16 / 9))
    focal = width / (2 * math.tan(horizontal / 2))
    ray_x, ray_y = np.meshgrid((np.arange(width) - width / 2) / focal,
                               (np.arange(height) - height / 2) / focal)
    positions = [(0, 0), (-32, -32), (0, -32), (32, -32),
                 (-32, 0), (32, 0), (-32, 32), (0, 32), (32, 32)]
    folder = Path(__file__).parent / "Fixtures" / "TiltedSweep"
    folder.mkdir(parents=True, exist_ok=True)
    for index, (yaw, pitch) in enumerate(positions):
        roll = math.radians(0 if index == 0 else 15)
        yaw, pitch = math.radians(yaw), math.radians(pitch)
        rx = ray_x * math.cos(roll) - ray_y * math.sin(roll)
        ry = ray_x * math.sin(roll) + ray_y * math.cos(roll)
        x = rx * math.cos(yaw) + (ry * math.sin(pitch) + math.cos(pitch)) * math.sin(yaw)
        y = ry * math.cos(pitch) - math.sin(pitch)
        z = -rx * math.sin(yaw) + (ry * math.sin(pitch) + math.cos(pitch)) * math.cos(yaw)
        mx, my = 2500 + x / z * 350, 2500 + y / z * 350
        assert z.min() > 0 and mx.min() >= 0 and my.min() >= 0
        assert mx.max() < 4999 and my.max() < 4999
        ix, iy = np.floor(mx).astype(int), np.floor(my).astype(int)
        fx, fy = (mx - ix)[..., None], (my - iy)[..., None]
        pixels = (texture[iy, ix] * (1 - fx) * (1 - fy)
                  + texture[iy, ix + 1] * fx * (1 - fy)
                  + texture[iy + 1, ix] * (1 - fx) * fy
                  + texture[iy + 1, ix + 1] * fx * fy)
        Image.fromarray(np.rint(pixels).astype(np.uint8)).save(folder / f"tilt{index:02}.jpg", quality=92)
    print(f"Rendered {len(positions)} tilted camera views in {folder}")


if __name__ == "__main__":
    generate()
