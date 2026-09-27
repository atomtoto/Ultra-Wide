"""Functional regression for the camera gauge used by UWStitcher.mm.

Run with: python3 -m pip install opencv-python-headless numpy
          python3 UltraWideTests/test_stitch_projection.py

OpenCV's bundle adjustment chooses an arbitrary absolute rotation. Projecting
its matrices without rebasing on the center frame used to reject an otherwise
complete 0.5x sweep as missing the edges. This test uses OpenCV 4.13's
Stitcher and PlaneWarper geometry. Python's Stitcher binding does not expose
the iPhone engine's SIFT finder. The final HEIF path still needs an on-device
integration test.
"""

import math
import unittest

import cv2
import numpy as np


def vertical_fov(horizontal_degrees, aspect):
    return math.degrees(
        2 * math.atan(math.tan(math.radians(horizontal_degrees / 2)) / aspect)
    )


def make_frames(portrait):
    np.random.seed(17)
    if portrait:
        width, height = 960, 1280
        source_horizontal = vertical_fov(70, 4 / 3)
        source_vertical = 70
        target_vertical = math.degrees(2 * math.atan(math.tan(math.radians(35)) / 0.5))
        target_horizontal = vertical_fov(target_vertical, 4 / 3)
        output_aspect = 3 / 4
    else:
        width, height = 1280, 720  # Video's narrower 16:9 vertical field.
        source_horizontal = 70
        source_vertical = vertical_fov(source_horizontal, 16 / 9)
        target_horizontal = math.degrees(2 * math.atan(math.tan(math.radians(35)) / 0.5))
        target_vertical = vertical_fov(target_horizontal, 4 / 3)
        output_aspect = 4 / 3

    world = np.random.default_rng(17).integers(0, 255, (3000, 3000, 3), np.uint8)
    world = cv2.GaussianBlur(world, (0, 0), 2)
    for _ in range(400):
        x, y = np.random.randint(0, 3000, 2)
        cv2.circle(
            world,
            (int(x), int(y)),
            int(np.random.randint(3, 35)),
            tuple(int(v) for v in np.random.randint(10, 245, 3)),
            -1,
        )

    focal = width / (2 * math.tan(math.radians(source_horizontal / 2)))
    rays_x, rays_y = np.meshgrid(
        (np.arange(width) - width / 2) / focal,
        (np.arange(height) - height / 2) / focal,
    )
    yaw_span = target_horizontal - source_horizontal
    pitch_span = target_vertical - source_vertical
    # One session follows the former slot order and the video session takes
    # the remaining views in a free, non-raster order.
    positions = ([(0, 0), (-1, -1), (0, -1), (1, -1), (-1, 0),
                  (1, 0), (-1, 1), (0, 1), (1, 1)] if portrait else
                 [(0, 0), (-1, -1), (1, 0), (0, 1), (1, -1), (-1, 1),
                  (0, -1), (-1, 0), (1, 1)])
    frames = []
    for column, row in positions:
        yaw = math.radians(column * yaw_span / 2)
        pitch = math.radians(row * pitch_span / 2)
        x = rays_x * math.cos(yaw) + (
            rays_y * math.sin(pitch) + math.cos(pitch)
        ) * math.sin(yaw)
        y = rays_y * math.cos(pitch) - math.sin(pitch)
        z = -rays_x * math.sin(yaw) + (
            rays_y * math.sin(pitch) + math.cos(pitch)
        ) * math.cos(yaw)
        map_x = (1500 + x / z * 700).astype(np.float32)
        map_y = (1500 + y / z * 700).astype(np.float32)
        frames.append(cv2.remap(world, map_x, map_y, cv2.INTER_LINEAR))
    return frames, (target_horizontal, target_vertical), output_aspect


def registered_crop(frames, aspect, rebase, tilt_reference=False):
    cv2.setRNGSeed(19)
    stitcher = cv2.Stitcher_create(cv2.Stitcher_PANORAMA)
    stitcher.setRegistrationResol(0.8)
    stitcher.setPanoConfidenceThresh(0.65)
    stitcher.setWaveCorrection(False)
    status = stitcher.estimateTransform(frames)
    if status != cv2.Stitcher_OK:
        raise AssertionError(f"OpenCV registration failed: {status}")
    cameras = stitcher.cameras()
    component = stitcher.component()
    if len(component) != len(frames):
        raise AssertionError(f"OpenCV rejected a synthetic frame: {component}")
    work_scale = stitcher.workScale()
    focal = float(np.median([camera.focal / work_scale for camera in cameras]))
    warper = cv2.PyRotationWarper("plane", focal)
    if tilt_reference:
        # Bundle adjustment may choose *any* common rotation. Apply a known
        # valid 25°/15° gauge so this regression is independent of the one
        # OpenCV happens to choose on this host.
        yaw, pitch = math.radians(25), math.radians(15)
        yaw_rotation = np.array([[math.cos(yaw), 0, math.sin(yaw)],
                                 [0, 1, 0],
                                 [-math.sin(yaw), 0, math.cos(yaw)]])
        pitch_rotation = np.array([[1, 0, 0],
                                   [0, math.cos(pitch), -math.sin(pitch)],
                                   [0, math.sin(pitch), math.cos(pitch)]])
        gauge = yaw_rotation @ pitch_rotation @ cameras[0].R.T
    else:
        gauge = np.eye(3)
    rotations = [gauge @ camera.R for camera in cameras]
    reference_inverse = rotations[0].T if rebase else np.eye(3)
    polygons = []
    for index, camera, absolute_rotation in zip(component, cameras, rotations):
        height, width = frames[index].shape[:2]
        intrinsics = camera.K().astype(np.float32)
        intrinsics[:2, :3] /= work_scale
        intrinsics[2, 2] = 1
        rotation = (reference_inverse @ absolute_rotation).astype(np.float32)
        corners = [(0, 0), (width - 1, 0), (width - 1, height - 1), (0, height - 1)]
        polygons.append(np.array([
            warper.warpPoint(point, intrinsics, rotation) for point in corners
        ], np.float32))

    origin = np.min(np.concatenate(polygons), axis=0)
    extent = np.max(np.concatenate(polygons), axis=0) - origin
    preview_scale = min(1, 800 / max(extent))
    preview_width, preview_height = np.ceil(extent * preview_scale).astype(int) + 2
    mask = np.zeros((preview_height, preview_width), np.uint8)
    for polygon in polygons:
        cv2.fillConvexPoly(mask, np.rint((polygon - origin) * preview_scale).astype(np.int32), 1)
    mask = cv2.erode(mask, None, iterations=2)
    integral = cv2.integral(mask)

    lower, upper = 1, min(preview_width, int(preview_height * aspect) + 1)
    crop = None
    while lower <= upper:
        crop_width = (lower + upper) // 2
        crop_height = round(crop_width / aspect)
        if crop_height > preview_height:
            upper = crop_width - 1
            continue
        sums = (integral[crop_height:, crop_width:] - integral[:-crop_height, crop_width:]
                - integral[crop_height:, :-crop_width] + integral[:-crop_height, :-crop_width])
        ys, xs = np.where(sums == crop_width * crop_height)
        if len(xs):
            nearest = np.argmin(
                (xs + crop_width / 2 - preview_width / 2) ** 2
                + (ys + crop_height / 2 - preview_height / 2) ** 2
            )
            crop = (int(xs[nearest]), int(ys[nearest]), crop_width, crop_height)
            lower = crop_width + 1
        else:
            upper = crop_width - 1
    if crop is None:
        raise AssertionError("The synthetic sweep has no covered crop")

    x, y, crop_width, crop_height = crop
    left, top = origin + np.array([x, y]) / preview_scale
    right, bottom = origin + np.array([x + crop_width, y + crop_height]) / preview_scale
    horizontal = math.degrees(math.atan(right / focal) - math.atan(left / focal))
    vertical = math.degrees(math.atan(bottom / focal) - math.atan(top / focal))

    # Check that the chosen crop is really covered after the source images are
    # projected, not merely in a low-resolution polygon approximation.
    output_width = 800
    output_height = round(output_width / aspect)
    occupied = np.zeros((output_height, output_width), np.uint8)
    for index, polygon in zip(component, polygons):
        source_height, source_width = frames[index].shape[:2]
        source = np.array([(0, 0), (source_width - 1, 0),
                           (source_width - 1, source_height - 1), (0, source_height - 1)], np.float32)
        destination = np.column_stack((
            (polygon[:, 0] - left) * output_width / (right - left),
            (polygon[:, 1] - top) * output_height / (bottom - top),
        )).astype(np.float32)
        transform = cv2.getPerspectiveTransform(source, destination)
        occupied |= cv2.warpPerspective(
            np.ones((source_height, source_width), np.uint8), transform,
            (output_width, output_height), flags=cv2.INTER_NEAREST,
        )
    return horizontal, vertical, int((occupied == 0).sum())


class StitchProjectionRegression(unittest.TestCase):
    def test_centered_photo_sweep(self):
        frames, target, aspect = make_frames(portrait=True)
        old_horizontal, _, _ = registered_crop(frames, aspect, rebase=False,
                                                tilt_reference=True)
        self.assertLess(old_horizontal / target[0], 0.92)
        horizontal, vertical, uncovered = registered_crop(frames, aspect, rebase=True,
                                                           tilt_reference=True)
        self.assertGreaterEqual(horizontal / target[0], 0.92)
        self.assertGreaterEqual(vertical / target[1], 0.92)
        self.assertEqual(uncovered, 0)

    def test_free_order_video_16_by_9_to_photo_4_by_3(self):
        frames, target, aspect = make_frames(portrait=False)
        horizontal, vertical, uncovered = registered_crop(frames, aspect, rebase=True)
        self.assertGreaterEqual(horizontal / target[0], 0.92)
        self.assertGreaterEqual(vertical / target[1], 0.92)
        self.assertEqual(uncovered, 0)


if __name__ == "__main__":
    unittest.main()
