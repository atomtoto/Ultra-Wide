"""Check the native render scheduler on macOS without an iPhone/OpenCV runtime."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ParallelRenderTests(unittest.TestCase):
    def test_disjoint_pixels_frame_order_worker_bound_and_exceptions(self):
        compiler = shutil.which("clang++")
        self.assertIsNotNone(compiler)
        include = Path(__file__).resolve().parents[1] / "UltraWide" / "Stitching"
        source = r'''
#include "UWParallelRender.hpp"
#include <atomic>
#include <cassert>
#include <stdexcept>

int main() {
    constexpr size_t width = 1031, height = 773, tileSide = 128;
    constexpr size_t columns = (width + tileSide - 1) / tileSide;
    constexpr size_t rows = (height + tileSide - 1) / tileSide;
    std::vector<unsigned> serial(width * height), parallel(width * height);
    auto render = [&](std::vector<unsigned> &pixels, size_t workers) {
        for (unsigned frame = 1; frame <= 12; ++frame) {
            uw::ParallelFor(columns * rows, workers, [&](size_t tile) {
                const size_t left = tile % columns * tileSide, top = tile / columns * tileSide;
                for (size_t y = top; y < std::min(height, top + tileSide); ++y) {
                    for (size_t x = left; x < std::min(width, left + tileSide); ++x) {
                        // Noncommutative, so missing, duplicate or reordered
                        // frame writes all change the expected output.
                        pixels[y * width + x] = pixels[y * width + x] * 13 + frame + x + 7 * y;
                    }
                }
            });
        }
    };
    render(serial, 1);
    for (size_t workers : {0, 2, 4, 100}) {
        std::fill(parallel.begin(), parallel.end(), 0);
        render(parallel, workers);
        assert(serial == parallel);
    }
    bool called = false;
    uw::ParallelFor(0, 4, [&](size_t) { called = true; });
    assert(!called);
    std::atomic<int> active{0};
    uw::ParallelFor(103, 4, [&](size_t) {
        const int concurrent = ++active;
        assert(concurrent <= 4);
        --active;
    });
    for (size_t workers : {1, 4}) {
        bool caught = false;
        try {
            uw::ParallelFor(17, workers, [&](size_t index) {
                if (index == 5) throw std::runtime_error("render failed");
            });
        } catch (const std::runtime_error &) { caught = true; }
        assert(caught);
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            cpp = Path(directory) / "test.cpp"
            binary = Path(directory) / "test"
            cpp.write_text(source)
            subprocess.run([compiler, "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror",
                            "-I", str(include), str(cpp), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
