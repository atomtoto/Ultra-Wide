"""Check that export tile culling preserves soft seams and fallback coverage."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class RenderSupportTests(unittest.TestCase):
    def test_culled_render_matches_all_pixels_including_bilinear_edges_and_holes(self):
        compiler = shutil.which("clang++")
        self.assertIsNotNone(compiler)
        include = Path(__file__).resolve().parents[1] / "UltraWide" / "Stitching"
        source = r'''
#include "UWBlendSampling.hpp"
#include "UWRenderSupport.hpp"
#include <cassert>
#include <limits>
#include <vector>

int main() {
    // Padding must never count as a visible seam. Include the neighboring
    // texel when the sample lies just before a nonzero mask pixel.
    const uint8_t mask[] = {0, 0, 255, 255, 0, 100, 255, 255};
    assert(!uw::MaskRegionHasWeight(mask, 2, 2, 4, -2, -2, -0.1, -0.1));
    assert(!uw::MaskRegionHasWeight(mask, 2, 2, 4, 2, 2, 3, 3));
    assert(uw::MaskRegionHasWeight(mask, 2, 2, 4, 0.01, 0.01, 0.02, 0.02));
    const uint8_t paddedZero[] = {0, 0, 255, 255, 0, 0, 255, 255};
    assert(!uw::MaskRegionHasWeight(paddedZero, 2, 2, 4, 0, 0, 1, 1));
    assert(uw::MaskRegionHasWeight(mask, 2, 2, 4,
        std::numeric_limits<double>::quiet_NaN(), 0, 1, 1));

    constexpr int width = 259, height = 197, side = 32;
    constexpr int maskWidth = 19, maskHeight = 15, stride = 23;
    constexpr double step = 0.08, startX = -1.25, startY = -1.125;
    std::vector<uint16_t> expected(width * height, 17), actual = expected;
    // Uncovered pixels must receive the real source even when its graph-cut
    // seam mask is empty, including at partial tiles and outside the mask.
    for (int y : {0, 61, height - 1}) {
        for (int x : {0, 126, width - 1}) {
            expected[y * width + x] = 0;
            actual[y * width + x] = 0;
        }
    }
    size_t skipped = 0, scheduled = 0;
    for (int frame = 0; frame < 5; ++frame) {
        std::vector<uint8_t> seam(stride * maskHeight, 255);
        for (int y = 0; y < maskHeight; ++y) {
            for (int x = 0; x < maskWidth; ++x) {
                seam[y * stride + x] = frame != 0 && x >= frame * 3 && x < frame * 3 + 2
                    && y >= 4 && y < 7 ? static_cast<uint8_t>(17 + 40 * frame) : 0;
            }
        }
        auto contribution = [&](int x, int y, uint16_t previous) {
            const double weight = uw::BilinearMaskWeight(seam.data(), maskWidth, maskHeight,
                stride, startX + x * step, startY + y * step);
            if (!weight && previous) return previous;
            return static_cast<uint16_t>(previous + (weight ? 1 + static_cast<int>(weight) : 1));
        };
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                expected[y * width + x] = contribution(x, y, expected[y * width + x]);
            }
        }
        for (int top = 0; top < height; top += side) {
            for (int left = 0; left < width; left += side) {
                const int right = std::min(width, left + side), bottom = std::min(height, top + side);
                ++scheduled;
                if (!uw::MaskRegionHasWeight(seam.data(), maskWidth, maskHeight, stride,
                        startX + left * step, startY + top * step,
                        startX + (right - 1) * step, startY + (bottom - 1) * step)
                    && !uw::HasUncoveredPixel(actual.data(), width, left, top, right, bottom)) {
                    ++skipped;
                    continue;
                }
                for (int y = top; y < bottom; ++y) {
                    for (int x = left; x < right; ++x) {
                        actual[y * width + x] = contribution(x, y, actual[y * width + x]);
                    }
                }
            }
        }
        assert(expected == actual);
    }
    assert(skipped > scheduled * 3 / 4);
    assert(!uw::HasUncoveredPixel(actual.data(), width, 0, 0, width, height));
}
'''
        with tempfile.TemporaryDirectory() as directory:
            cpp = Path(directory) / "test.cpp"
            binary = Path(directory) / "test"
            cpp.write_text(source)
            subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(include), str(cpp), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
