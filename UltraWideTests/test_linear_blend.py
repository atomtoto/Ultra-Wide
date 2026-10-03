"""Exercise the export's actual linear-light color operations without an iPhone."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class LinearBlendTests(unittest.TestCase):
    def test_light_energy_rounding_dense_overlaps_and_in_place_encoding(self):
        compiler = shutil.which("clang++")
        self.assertIsNotNone(compiler)
        include = Path(__file__).resolve().parents[1] / "UltraWide" / "Stitching"
        source = r'''
#include "UWLinearBlend.hpp"
#include <cassert>
#include <random>
#include <vector>

int main() {
    const auto unity = uw::LinearGainLUT(1);
    const auto doubled = uw::LinearGainLUT(2);
    const auto &encoded = uw::LinearEncodeLUT();
    for (int value = 0; value < 256; ++value) {
        assert(encoded[unity[value]] == value);
        assert(std::abs(doubled[value] / 65535.0 -
            std::min(1.0, 2.0 * uw::LinearDecodeLUT()[value])) <= 0.5 / 65535.0 + 1e-8);
        assert(uw::BlendLinearSample(unity[value], unity[value], 96 * 256, 256) == unity[value]);
    }
    // The midpoint of black and white contains half the light: encoded 188,
    // not the dark 128 obtained by averaging gamma-encoded source bytes.
    assert(encoded[uw::BlendLinearSample(0, 65535, 256, 256)] == 188);
    assert(uw::BlendLinearSample(60000, 12345, 0, 1) == 12345);
    assert(uw::BlendLinearSample(12345, 60000, 1, 0) == 12345);
    assert(uw::BlendLinearSample(0, 0, 0, 0) == 0);

    std::mt19937 random(127);
    for (int trial = 0; trial < 1000; ++trial) {
        uint16_t actual = 0, weight = 0;
        uint64_t numerator = 0;
        for (int frame = 0; frame < 96; ++frame) {
            const uint16_t color = static_cast<uint16_t>(random());
            const uint16_t contribution = 1 + random() % 256;
            actual = uw::BlendLinearSample(actual, color, weight, contribution);
            weight += contribution;
            numerator += static_cast<uint64_t>(color) * contribution;
        }
        const double expected = static_cast<double>(numerator) / weight;
        // At most half a 16-bit unit per overlap, still below one export level.
        assert(std::abs(actual - expected) < 48);
        assert(std::abs(encoded[actual] - encoded[static_cast<uint16_t>(std::round(expected))]) <= 1);
    }

    constexpr size_t width = 71, height = 13;
    std::vector<uint16_t> buffer(width * height * 3);
    for (auto &value : buffer) value = static_cast<uint16_t>(random());
    const auto original = buffer;
    std::vector<float> gains(width * height);
    for (auto &gain : gains) gain = 0.85f + (random() % 30) / 100.0f;
    auto *bytes = reinterpret_cast<uint8_t *>(buffer.data());
    // The compacted destination increasingly precedes the source. Exercise
    // separate row calls as well as the first pixels whose bytes overlap.
    for (size_t y = 0; y < height; ++y) {
        uw::EncodeLinearRow(buffer.data() + y * width * 3, bytes + y * width * 4,
                            gains.data() + y * width, width);
    }
    for (size_t pixel = 0; pixel < width * height; ++pixel) {
        for (size_t channel = 0; channel < 3; ++channel) {
            const auto linear = static_cast<uint16_t>(std::round(std::clamp(
                original[pixel * 3 + channel] * gains[pixel], 0.0f, 65535.0f)));
            assert(bytes[pixel * 4 + channel] == encoded[linear]);
        }
        assert(bytes[pixel * 4 + 3] == 255);
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            cpp = Path(directory) / "test.cpp"
            binary = Path(directory) / "test"
            cpp.write_text(source)
            subprocess.run([compiler, "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror",
                            "-fsanitize=address,undefined", "-I", str(include), str(cpp), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
