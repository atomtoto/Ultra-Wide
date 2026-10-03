#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace uw {

// Display P3 uses the sRGB transfer curve. Retain linear 16-bit values until
// the final encoding so repeated overlaps do not accumulate 8-bit rounding.
inline const std::array<float, 256> &LinearDecodeLUT() {
    static const auto values = [] {
        std::array<float, 256> result{};
        for (int value = 0; value < 256; ++value) {
            const double encoded = value / 255.0;
            result[value] = static_cast<float>(encoded <= 0.04045 ? encoded / 12.92
                : std::pow((encoded + 0.055) / 1.055, 2.4));
        }
        return result;
    }();
    return values;
}

inline std::array<uint16_t, 256> LinearGainLUT(double gain) {
    std::array<uint16_t, 256> result{};
    const auto &decoded = LinearDecodeLUT();
    for (int value = 0; value < 256; ++value) {
        result[value] = static_cast<uint16_t>(std::round(std::clamp(decoded[value] * gain, 0.0, 1.0) * 65535));
    }
    return result;
}

inline const std::array<uint8_t, 65536> &LinearEncodeLUT() {
    static const auto values = [] {
        std::array<uint8_t, 65536> result{};
        for (int value = 0; value < 65536; ++value) {
            const double linear = value / 65535.0;
            const double encoded = linear <= 0.0031308 ? linear * 12.92
                : 1.055 * std::pow(linear, 1.0 / 2.4) - 0.055;
            result[value] = static_cast<uint8_t>(std::round(encoded * 255));
        }
        return result;
    }();
    return values;
}

inline uint16_t BlendLinearSample(uint16_t previousColor, uint16_t sourceColor,
                                  uint16_t previousWeight, uint16_t contribution) {
    const uint32_t total = static_cast<uint32_t>(previousWeight) + contribution;
    if (!total) return 0;
    const uint64_t weighted = static_cast<uint64_t>(previousColor) * previousWeight
        + static_cast<uint64_t>(sourceColor) * contribution;
    return static_cast<uint16_t>((weighted + total / 2) / total);
}

// Forward conversion supports compacting a 6-byte linear BGR buffer in place
// into 4-byte encoded BGRA. Call rows in order; copy each source before writing.
inline void EncodeLinearRow(const uint16_t *source, uint8_t *destination,
                            const float *luminanceGains, size_t pixelCount) {
    const auto &encoded = LinearEncodeLUT();
    for (size_t pixel = 0; pixel < pixelCount; ++pixel) {
        const std::array<uint16_t, 3> color = {source[pixel * 3], source[pixel * 3 + 1], source[pixel * 3 + 2]};
        const float gain = luminanceGains ? luminanceGains[pixel] : 1;
        for (size_t channel = 0; channel < 3; ++channel) {
            const auto corrected = static_cast<uint16_t>(std::round(std::clamp(color[channel] * gain, 0.0f, 65535.0f)));
            destination[pixel * 4 + channel] = encoded[corrected];
        }
        destination[pixel * 4 + 3] = 255;
    }
}

} // namespace uw
