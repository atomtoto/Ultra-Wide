"""Run UWStitcher's real seam/color C++ functions on macOS with OpenCV 4.13.

The Python wheel supplies the host OpenCV library; the production functions
are compiled from UWStitcher.mm against the project's bundled headers. HEIF
encoding and the complete iPhone export still require the device tests.
"""

import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin" and importlib.util.find_spec("cv2"),
                     "Requires macOS and opencv-python-headless 4.13.")
class NativeBlendPlanTests(unittest.TestCase):
    def test_uniform_tilted_wall_has_no_dark_seams_or_color_correction_bands(self):
        import cv2

        self.assertTrue(cv2.__version__.startswith("4.13."))
        root = Path(__file__).resolve().parents[1]
        native = (root / "UltraWide/Stitching/UWStitcher.mm").read_text()
        functions = native[native.index("static cv::Mat ProjectionTransform("):native.index("static bool EncodeHEIF(")]
        bounds = native[native.index("static cv::Rect2f Bounds("):native.index("static bool PreparedGeometry(")]
        source = r'''
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/stitching/detail/blenders.hpp>
#include <opencv2/stitching/detail/seam_finders.hpp>
#include "UWLinearBlend.hpp"
#include <iostream>
#include <vector>
struct FrameGeometry {
    long inputIndex;
    std::array<cv::Point2f, 4> worldCorners;
    cv::Rect2f worldBounds;
};
'''
        source += bounds + functions
        source += r'''
extern "C" int RunQualityCheck() {
    cv::setNumThreads(2);
    const cv::Vec3b color(97, 124, 80);
    const auto &encoded = uw::LinearEncodeLUT();
    const auto unity = uw::LinearGainLUT(1);
    const auto halved = uw::LinearGainLUT(0.5);
    const cv::Vec3b dark(encoded[halved[color[0]]], encoded[halved[color[1]]], encoded[halved[color[2]]]);
    std::vector<cv::Mat> thumbnails = {
        cv::Mat(640, 480, CV_8UC3, cv::Scalar(color[0], color[1], color[2])),
        cv::Mat(640, 480, CV_8UC3, cv::Scalar(dark[0], dark[1], dark[2]))
    };
    const std::array<cv::Matx33d, 2> matrices = {
        cv::Matx33d(0.9, 0.05, -0.12, -0.04, 1.25, -0.10, 0, 0, 1),
        cv::Matx33d(0.9, -0.05, 0.30, 0.04, 1.25, -0.14, 0, 0, 1)
    };
    const std::array<cv::Vec3d, 4> corners = {
        cv::Vec3d(0, 0, 1), cv::Vec3d(1, 0, 1), cv::Vec3d(1, 1, 1), cv::Vec3d(0, 1, 1)
    };
    std::vector<FrameGeometry> geometry;
    cv::Rect2f global;
    for (size_t i = 0; i < matrices.size(); ++i) {
        FrameGeometry frame;
        frame.inputIndex = i;
        for (size_t j = 0; j < corners.size(); ++j) {
            const auto mapped = matrices[i] * corners[j];
            frame.worldCorners[j] = cv::Point2f((mapped[0] / mapped[2] - 0.5) * 960,
                                                (mapped[1] / mapped[2] - 0.5) * 1280);
        }
        frame.worldBounds = Bounds(frame.worldCorners);
        global = geometry.empty() ? frame.worldBounds : global | frame.worldBounds;
        geometry.push_back(frame);
    }
    const BlendPlan plan = BuildBlendPlan(geometry, thumbnails, {1, 2}, global, true);
    const cv::Vec3f expected(unity[color[0]] / 65535.0f,
                            unity[color[1]] / 65535.0f, unity[color[2]] / 65535.0f);
    const cv::Rect2d crop(-480, -640, 960, 1280);
    // Different decode resolutions must project identical normalized scene
    // points to the same output pixel centers, including off-center details.
    for (size_t i = 0; i < geometry.size(); ++i) {
        for (const cv::Size size : {cv::Size(480, 640), cv::Size(960, 1280), cv::Size(3000, 4000)}) {
            const cv::Mat H = ProjectionTransform(geometry[i], size, crop.tl(), 1371.0 / 960, 1828.0 / 1280, true);
            const cv::Matx33d projection(H);
            for (double y : {0.15, 0.6, 0.9}) {
                for (double x : {0.15, 0.6, 0.9}) {
                    const auto actual = projection * cv::Vec3d(x * size.width - 0.5, y * size.height - 0.5, 1);
                    const auto expected = matrices[i] * cv::Vec3d(x, y, 1);
                    if (std::abs(actual[0] / actual[2] - (expected[0] / expected[2] * 1371 - 0.5)) > 0.002 ||
                        std::abs(actual[1] / actual[2] - (expected[1] / expected[2] * 1828 - 0.5)) > 0.002) return 3;
                }
            }
        }
    }
    constexpr int outputW = 768, outputH = 1024;
    const double scaleX = outputW / crop.width, scaleY = outputH / crop.height;
    std::vector<uint16_t> baseline(outputW * outputH * 3);
    for (size_t i = 0; i < baseline.size(); ++i) baseline[i] = unity[color[i % 3]];
    const cv::Mat correction = LowFrequencyCorrectionFromRenderedImage(
        plan, baseline.data(), outputW, outputH, crop, global, scaleX, scaleY);
    double worstColorError = 0, worstGainError = 0;
    for (double y : {0.01, 0.2, 0.5, 0.8, 0.99}) {
        for (double x : {0.01, 0.2, 0.5, 0.8, 0.99}) {
            const int px = std::lround((crop.x + x * crop.width - global.x) * plan.scale - 0.5);
            const int py = std::lround((crop.y + y * crop.height - global.y) * plan.scale - 0.5);
            if (!plan.multibandMask.at<uint8_t>(py, px)) return 1;
            const auto actual = plan.multibandPreview.at<cv::Vec3f>(py, px);
            for (int channel = 0; channel < 3; ++channel) {
                worstColorError = std::max(worstColorError, static_cast<double>(std::abs(actual[channel] - expected[channel])));
            }
            worstGainError = std::max(worstGainError, std::abs(correction.at<float>(py, px) - 1.0));
        }
    }
    std::cout << "Maximum linear color error: " << worstColorError
              << "; maximum residual gain error: " << worstGainError << std::endl;
    return worstColorError < 0.004 && worstGainError < 0.015 ? 0 : 2;
}
'''
        library = next(Path(cv2.__file__).parent.glob("*.so"))
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            (directory / "opencv2").symlink_to(root / "ThirdParty/OpenCV/opencv2.framework/Headers", target_is_directory=True)
            cpp, bundle = directory / "check.cpp", directory / "check.bundle"
            cpp.write_text(source)
            subprocess.run([shutil.which("clang++"), "-std=c++17", "-O2", "-bundle", "-undefined", "dynamic_lookup",
                            "-I", str(directory), "-I", str(root / "UltraWide/Stitching"),
                            str(cpp), "-o", str(bundle)], check=True)
            # Open the wheel globally so the bundle resolves its OpenCV symbols
            # in the same Python process, including the wheel's Python imports.
            loader = """import ctypes, cv2, sys
ctypes.CDLL(sys.argv[1], mode=ctypes.RTLD_GLOBAL)
check = ctypes.CDLL(sys.argv[2])
sys.exit(check.RunQualityCheck())
"""
            subprocess.run([sys.executable, "-c", loader, str(library), str(bundle)], check=True)


if __name__ == "__main__":
    unittest.main()
