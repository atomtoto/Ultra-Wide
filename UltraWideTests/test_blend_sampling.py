"""Exercise the native export's seam sampler directly, without an iPhone."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class BlendSamplingTests(unittest.TestCase):
    def test_enlarged_seams_are_continuous_and_respect_stride_and_edges(self):
        compiler = shutil.which("clang++")
        self.assertIsNotNone(compiler, "A C++ compiler is required for the native sampler regression.")
        include = Path(__file__).resolve().parents[1] / "UltraWide" / "Stitching"
        source = r'''
#include "UWBlendSampling.hpp"
#include <cassert>
#include <limits>

int main() {
    // Padding must never leak into the seam; sample in both axes.
    const uint8_t mask[] = {0, 100, 222, 222, 100, 200, 222, 222};
    auto sample = [&](double x, double y) {
        return uw::BilinearMaskWeight(mask, 2, 2, 4, x, y);
    };
    assert(std::abs(sample(0.25, 0.5) - 75) < 1e-9);
    assert(std::abs(sample(0.75, 0.25) - 100) < 1e-9);
    // A 16x enlargement must advance at each output pixel, including on
    // either side of the old nearest-neighbor jump at x = 0.5.
    double previous = sample(0, 0.25);
    for (int x = 1; x <= 16; ++x) {
        const double current = sample(x / 16.0, 0.25);
        assert(std::abs((current - previous) - 6.25) < 1e-9);
        previous = current;
    }
    assert(sample(1, 1) == 200);
    assert(sample(-0.01, 0) == 0);
    assert(sample(1.01, 0) == 0);
    assert(sample(0, -0.01) == 0);
    assert(sample(0, 1.01) == 0);
    assert(sample(std::numeric_limits<double>::quiet_NaN(), 0) == 0);
    assert(uw::BilinearMaskWeight(nullptr, 2, 2, 4, 0, 0) == 0);
    const uint8_t singleton[] = {137};
    assert(uw::BilinearMaskWeight(singleton, 1, 1, 1, 0, 0) == 137);
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
