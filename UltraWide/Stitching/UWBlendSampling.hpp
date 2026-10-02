#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace uw {

// Coordinates refer to mask pixel centers, matching the projection used to
// build the seam map. Respect row stride and return zero outside its canvas.
inline double BilinearMaskWeight(const uint8_t *pixels, int width, int height,
                                 size_t rowStride, double x, double y) {
    if (!pixels || !std::isfinite(x) || !std::isfinite(y) ||
        x < 0 || y < 0 || x > width - 1 || y > height - 1) return 0;
    const int x0 = static_cast<int>(std::floor(x)), y0 = static_cast<int>(std::floor(y));
    const int x1 = std::min(x0 + 1, width - 1), y1 = std::min(y0 + 1, height - 1);
    const double fx = x - x0, fy = y - y0;
    const double top = pixels[y0 * rowStride + x0] * (1 - fx) + pixels[y0 * rowStride + x1] * fx;
    const double bottom = pixels[y1 * rowStride + x0] * (1 - fx) + pixels[y1 * rowStride + x1] * fx;
    return top * (1 - fy) + bottom * fy;
}

} // namespace uw
