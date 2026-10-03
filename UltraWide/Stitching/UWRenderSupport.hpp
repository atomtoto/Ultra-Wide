#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace uw {

// Conservatively include every mask texel that can affect bilinear samples
// in this rectangle. False means all those samples are exactly zero.
inline bool MaskRegionHasWeight(const uint8_t *pixels, int width, int height,
                                size_t rowStride, double left, double top,
                                double right, double bottom) {
    if (!pixels || width <= 0 || height <= 0) return false;
    if (!std::isfinite(left) || !std::isfinite(top) ||
        !std::isfinite(right) || !std::isfinite(bottom)) return true;
    if (right < 0 || bottom < 0 || left > width - 1 || top > height - 1 ||
        right < left || bottom < top) return false;
    const int x0 = static_cast<int>(std::floor(std::max(0.0, left)));
    const int y0 = static_cast<int>(std::floor(std::max(0.0, top)));
    const int x1 = std::min(width - 1, static_cast<int>(std::floor(std::min<double>(width - 1, right))) + 1);
    const int y1 = std::min(height - 1, static_cast<int>(std::floor(std::min<double>(height - 1, bottom))) + 1);
    for (int y = y0; y <= y1; ++y) {
        const uint8_t *row = pixels + y * rowStride;
        for (int x = x0; x <= x1; ++x) if (row[x]) return true;
    }
    return false;
}

// A zero seam weight still contributes when it is the first real source at
// a pixel. Never skip a tile until that fallback coverage is already present.
inline bool HasUncoveredPixel(const uint16_t *weights, size_t rowStride,
                              int left, int top, int right, int bottom) {
    for (int y = top; y < bottom; ++y) {
        const uint16_t *row = weights + y * rowStride;
        for (int x = left; x < right; ++x) if (!row[x]) return true;
    }
    return false;
}

} // namespace uw
