#include <TargetConditionals.h>
#if !TARGET_OS_SIMULATOR
#include <opencv2/opencv.hpp>
#include <opencv2/stitching.hpp>
#include <opencv2/stitching/detail/warpers.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <fcntl.h>
#include <limits>
#include <numeric>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#endif

#import "UWStitcher.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSErrorDomain const UWStitcherErrorDomain = @"com.ultrawide.stitching";
NSString * const UWStitcherRejectedIndexesKey = @"rejectedFrameIndexes";

@implementation UWStitchFrame
- (instancetype)initWithURL:(NSURL *)url
               yawRadians:(double)yawRadians
             pitchRadians:(double)pitchRadians
              rollRadians:(double)rollRadians
                hasMotion:(BOOL)hasMotion {
    if ((self = [super init])) {
        _url = [url copy];
        _yawRadians = yawRadians;
        _pitchRadians = pitchRadians;
        _rollRadians = rollRadians;
        _hasMotion = hasMotion;
    }
    return self;
}
@end

@interface UWStitchOutcome ()
@property (nonatomic, readwrite) NSURL *imageURL;
@property (nonatomic, readwrite) NSInteger pixelWidth;
@property (nonatomic, readwrite) NSInteger pixelHeight;
@property (nonatomic, readwrite) NSArray<NSNumber *> *usedFrameIndexes;
@property (nonatomic, readwrite) NSArray<NSNumber *> *rejectedFrameIndexes;
@end
@implementation UWStitchOutcome
@end

static NSError *UWError(UWStitcherErrorCode code, NSString *message, NSArray<NSNumber *> * _Nullable rejected) {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message} mutableCopy];
    if (rejected.count) info[UWStitcherRejectedIndexesKey] = rejected;
    return [NSError errorWithDomain:UWStitcherErrorDomain code:code userInfo:info];
}

#if !TARGET_OS_SIMULATOR
namespace {

constexpr int kThumbnailLongestSide = 1280;
constexpr int kTileSide = 512;

struct MappedFile {
    int fd = -1;
    void *bytes = MAP_FAILED;
    size_t length = 0;
    std::string path;

    bool create(size_t byteCount) {
        NSString *templatePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ultrawide-XXXXXX"];
        const char *utf8Path = templatePath.UTF8String;
        std::vector<char> mutablePath(utf8Path, utf8Path + strlen(utf8Path) + 1);
        fd = mkstemp(mutablePath.data());
        if (fd < 0) return false;
        path = mutablePath.data();
        length = byteCount;
        if (ftruncate(fd, static_cast<off_t>(length)) != 0) return false;
        bytes = mmap(nullptr, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        return bytes != MAP_FAILED;
    }

    ~MappedFile() {
        if (bytes != MAP_FAILED) munmap(bytes, length);
        if (fd >= 0) close(fd);
        if (!path.empty()) unlink(path.c_str());
    }
};

struct FrameGeometry {
    NSInteger inputIndex;
    std::array<cv::Point2f, 4> worldCorners;
    cv::Rect2f worldBounds;
};

static cv::Mat ReadBGR(NSURL *url, int maximumSide) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    if (!source) return {};
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(maximumSide),
        (id)kCGImageSourceShouldCacheImmediately: @NO
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!image) return {};

    const size_t width = CGImageGetWidth(image);
    const size_t height = CGImageGetHeight(image);
    if (!width || !height || width > 16000 || height > 16000) {
        CGImageRelease(image);
        return {};
    }
    cv::Mat rgba(static_cast<int>(height), static_cast<int>(width), CV_8UC4);
    // Keep the entire 8-bit SDR working and export pipeline in Display P3.
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    CGContextRef context = CGBitmapContextCreate(
        rgba.data, width, height, 8, rgba.step[0], colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        CGImageRelease(image);
        return {};
    }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    CGImageRelease(image);
    cv::Mat bgr;
    cv::cvtColor(rgba, bgr, cv::COLOR_RGBA2BGR);
    return bgr;
}

static cv::Size OrientedPixelSize(NSURL *url) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    if (!source) return {};
    CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr);
    CFRelease(source);
    if (!props) return {};
    NSDictionary *dictionary = (__bridge_transfer NSDictionary *)props;
    int width = [dictionary[(id)kCGImagePropertyPixelWidth] intValue];
    int height = [dictionary[(id)kCGImagePropertyPixelHeight] intValue];
    int orientation = [dictionary[(id)kCGImagePropertyOrientation] intValue];
    if (orientation >= 5 && orientation <= 8) std::swap(width, height);
    return {width, height};
}

static bool Report(BOOL (^progress)(double), double value, NSError **error) {
    if (!progress || progress(value)) return true;
    if (error) *error = UWError(UWStitcherErrorCancelled, @"Assembly was cancelled.", nil);
    return false;
}

static bool FinitePoint(const cv::Point2f &point) {
    return std::isfinite(point.x) && std::isfinite(point.y) &&
           std::abs(point.x) < 100000 && std::abs(point.y) < 100000;
}

static cv::Rect2f Bounds(const std::array<cv::Point2f, 4> &points) {
    float minX = points[0].x, maxX = points[0].x;
    float minY = points[0].y, maxY = points[0].y;
    for (const auto &p : points) {
        minX = std::min(minX, p.x); maxX = std::max(maxX, p.x);
        minY = std::min(minY, p.y); maxY = std::max(maxY, p.y);
    }
    return {minX, minY, maxX - minX, maxY - minY};
}

static bool FindCoveredRectangle(const cv::Mat &mask, double aspect, cv::Rect &result) {
    cv::Mat integral;
    cv::integral(mask, integral, CV_32S);
    // The mask contains 0 or 1. A rectangle is valid only when every pixel has real input coverage.
    auto rectangleAtWidth = [&](int width, cv::Rect &candidate) {
        const int height = static_cast<int>(std::round(width / aspect));
        if (height < 1 || height > mask.rows || width > mask.cols) return false;
        const int *base = integral.ptr<int>();
        const int stride = static_cast<int>(integral.step1());
        const int required = width * height;
        bool found = false;
        double bestDistance = std::numeric_limits<double>::max();
        for (int y = 0; y <= mask.rows - height; ++y) {
            const int *top = base + y * stride;
            const int *bottom = base + (y + height) * stride;
            for (int x = 0; x <= mask.cols - width; ++x) {
                const int covered = bottom[x + width] - bottom[x] - top[x + width] + top[x];
                if (covered != required) continue;
                const double dx = x + width * 0.5 - mask.cols * 0.5;
                const double dy = y + height * 0.5 - mask.rows * 0.5;
                const double distance = dx * dx + dy * dy;
                if (distance < bestDistance) {
                    bestDistance = distance;
                    candidate = cv::Rect(x, y, width, height);
                    found = true;
                }
            }
        }
        return found;
    };

    int lower = 1;
    int upper = std::min(mask.cols, static_cast<int>(mask.rows * aspect) + 1);
    cv::Rect best;
    while (lower <= upper) {
        const int width = lower + (upper - lower) / 2;
        cv::Rect candidate;
        if (rectangleAtWidth(width, candidate)) {
            best = candidate;
            lower = width + 1;
        } else {
            upper = width - 1;
        }
    }
    if (best.width < 80 || best.height < 80) return false;
    result = best;
    return true;
}

static std::vector<std::array<double, 3>> EstimateExposureGains(
    const std::vector<FrameGeometry> &geometry,
    const std::vector<cv::Mat> &thumbnails,
    const cv::Rect2f &globalBounds,
    int previewW,
    int previewH,
    double previewScale
) {
    cv::Mat mosaic(previewH, previewW, CV_8UC3, cv::Scalar());
    cv::Mat counts(previewH, previewW, CV_8U, cv::Scalar());
    std::vector<std::array<double, 3>> gains;
    gains.reserve(geometry.size());
    for (const auto &frame : geometry) {
        const cv::Mat &thumbnail = thumbnails[frame.inputIndex];
        std::array<cv::Point2f, 4> sourceCorners = {
            cv::Point2f(0, 0),
            cv::Point2f(static_cast<float>(thumbnail.cols - 1), 0),
            cv::Point2f(static_cast<float>(thumbnail.cols - 1), static_cast<float>(thumbnail.rows - 1)),
            cv::Point2f(0, static_cast<float>(thumbnail.rows - 1))
        };
        std::array<cv::Point2f, 4> destinationCorners;
        for (int j = 0; j < 4; ++j) {
            destinationCorners[j] = cv::Point2f(
                static_cast<float>((frame.worldCorners[j].x - globalBounds.x) * previewScale),
                static_cast<float>((frame.worldCorners[j].y - globalBounds.y) * previewScale)
            );
        }
        cv::Mat transform = cv::getPerspectiveTransform(sourceCorners.data(), destinationCorners.data());
        cv::Mat warped, mask;
        cv::warpPerspective(thumbnail, warped, transform, cv::Size(previewW, previewH),
                            cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar());
        cv::Mat sourceMask(thumbnail.size(), CV_8U, cv::Scalar(255));
        cv::warpPerspective(sourceMask, mask, transform, cv::Size(previewW, previewH),
                            cv::INTER_NEAREST, cv::BORDER_CONSTANT, cv::Scalar());

        std::array<std::vector<double>, 3> ratios;
        for (int y = 3; y < previewH - 3; y += 3) {
            const cv::Vec3b *oldRow = mosaic.ptr<cv::Vec3b>(y);
            const cv::Vec3b *newRow = warped.ptr<cv::Vec3b>(y);
            const uint8_t *countRow = counts.ptr<uint8_t>(y);
            const uint8_t *maskRow = mask.ptr<uint8_t>(y);
            for (int x = 3; x < previewW - 3; x += 3) {
                if (!countRow[x] || !maskRow[x]) continue;
                for (int channel = 0; channel < 3; ++channel) {
                    const int oldValue = oldRow[x][channel];
                    const int newValue = newRow[x][channel];
                    if (oldValue > 24 && oldValue < 235 && newValue > 24 && newValue < 235) {
                        ratios[channel].push_back(static_cast<double>(oldValue) / newValue);
                    }
                }
            }
        }
        std::array<double, 3> gain = {1, 1, 1};
        for (int channel = 0; channel < 3; ++channel) {
            auto &values = ratios[channel];
            if (values.size() < 100) continue;
            auto middle = values.begin() + values.size() / 2;
            std::nth_element(values.begin(), middle, values.end());
            gain[channel] = std::clamp(*middle, 0.72, 1.38);
        }
        gains.push_back(gain);

        for (int y = 0; y < previewH; ++y) {
            cv::Vec3b *oldRow = mosaic.ptr<cv::Vec3b>(y);
            const cv::Vec3b *newRow = warped.ptr<cv::Vec3b>(y);
            uint8_t *countRow = counts.ptr<uint8_t>(y);
            const uint8_t *maskRow = mask.ptr<uint8_t>(y);
            for (int x = 0; x < previewW; ++x) {
                if (!maskRow[x]) continue;
                const int previous = countRow[x];
                for (int channel = 0; channel < 3; ++channel) {
                    const int corrected = std::clamp(
                        static_cast<int>(std::round(newRow[x][channel] * gain[channel])), 0, 255
                    );
                    oldRow[x][channel] = static_cast<uint8_t>(
                        (oldRow[x][channel] * previous + corrected) / (previous + 1)
                    );
                }
                countRow[x] = static_cast<uint8_t>(std::min(previous + 1, 255));
            }
        }
    }
    return gains;
}

struct BlendPlan {
    double scale = 1;
    std::vector<cv::Mat> seamWeights; // Soft graph-cut masks in global preview coordinates.
    cv::Mat multibandPreview;         // CV_32FC3, low-resolution reference for final color.
    cv::Mat multibandMask;            // Valid reference pixels; transparent edges must not darken the export.
};

static BlendPlan BuildBlendPlan(
    const std::vector<FrameGeometry> &geometry,
    const std::vector<cv::Mat> &thumbnails,
    const std::vector<std::array<double, 3>> &gains,
    const cv::Rect2f &globalBounds
) {
    BlendPlan plan;
    plan.scale = std::min(1.0, 256.0 / std::max(globalBounds.width, globalBounds.height));
    const int width = std::max(1, static_cast<int>(std::ceil(globalBounds.width * plan.scale)) + 2);
    const int height = std::max(1, static_cast<int>(std::ceil(globalBounds.height * plan.scale)) + 2);
    std::vector<cv::Mat> projectedImages, originalMasks;
    std::vector<cv::UMat> seamImages, seamMasks;
    std::vector<cv::Point> origins(geometry.size(), cv::Point());
    projectedImages.reserve(geometry.size());
    originalMasks.reserve(geometry.size());
    seamImages.reserve(geometry.size());
    seamMasks.reserve(geometry.size());

    for (size_t i = 0; i < geometry.size(); ++i) {
        const auto &frame = geometry[i];
        const cv::Mat &thumbnail = thumbnails[frame.inputIndex];
        const std::array<cv::Point2f, 4> sourceCorners = {
            cv::Point2f(0, 0),
            cv::Point2f(static_cast<float>(thumbnail.cols - 1), 0),
            cv::Point2f(static_cast<float>(thumbnail.cols - 1), static_cast<float>(thumbnail.rows - 1)),
            cv::Point2f(0, static_cast<float>(thumbnail.rows - 1))
        };
        std::array<cv::Point2f, 4> destinationCorners;
        for (int j = 0; j < 4; ++j) {
            destinationCorners[j] = cv::Point2f(
                static_cast<float>((frame.worldCorners[j].x - globalBounds.x) * plan.scale),
                static_cast<float>((frame.worldCorners[j].y - globalBounds.y) * plan.scale)
            );
        }
        cv::Mat transform = cv::getPerspectiveTransform(sourceCorners.data(), destinationCorners.data());
        cv::Mat projected, mask;
        cv::warpPerspective(thumbnail, projected, transform, cv::Size(width, height),
                            cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar());
        cv::Mat sourceMask(thumbnail.size(), CV_8U, cv::Scalar(255));
        cv::warpPerspective(sourceMask, mask, transform, cv::Size(width, height),
                            cv::INTER_NEAREST, cv::BORDER_CONSTANT, cv::Scalar());
        for (int y = 0; y < height; ++y) {
            cv::Vec3b *row = projected.ptr<cv::Vec3b>(y);
            const uint8_t *maskRow = mask.ptr<uint8_t>(y);
            for (int x = 0; x < width; ++x) {
                if (!maskRow[x]) continue;
                for (int channel = 0; channel < 3; ++channel) {
                    row[x][channel] = static_cast<uint8_t>(std::clamp(
                        static_cast<int>(std::round(row[x][channel] * gains[i][channel])), 0, 255
                    ));
                }
            }
        }
        cv::Mat floatImage;
        projected.convertTo(floatImage, CV_32FC3);
        cv::UMat seamImage, seamMask;
        floatImage.copyTo(seamImage);
        mask.copyTo(seamMask);
        seamImages.push_back(std::move(seamImage));
        seamMasks.push_back(std::move(seamMask));
        projectedImages.push_back(std::move(projected));
        originalMasks.push_back(std::move(mask));
    }

    try {
        // Solve seams on a compact preview. The source frame geometry and
        // full-resolution render retain their original precision.
        cv::detail::GraphCutSeamFinder finder(cv::detail::GraphCutSeamFinderBase::COST_COLOR_GRAD);
        finder.find(seamImages, origins, seamMasks);
    } catch (const cv::Exception &) {
        // Voronoi still assigns a single source where graph-cut cannot converge.
        seamMasks.clear();
        for (const auto &mask : originalMasks) {
            cv::UMat seamMask;
            mask.copyTo(seamMask);
            seamMasks.push_back(std::move(seamMask));
        }
        cv::detail::VoronoiSeamFinder fallback;
        fallback.find(seamImages, origins, seamMasks);
    }

    cv::detail::MultiBandBlender blender(false, 5, CV_16S);
    blender.prepare(cv::Rect(0, 0, width, height));
    for (size_t i = 0; i < geometry.size(); ++i) {
        cv::Mat seam = seamMasks[i].getMat(cv::ACCESS_READ).clone();
        cv::Mat shortImage;
        projectedImages[i].convertTo(shortImage, CV_16SC3);
        blender.feed(shortImage, seam, cv::Point());
        cv::Mat soft;
        cv::GaussianBlur(seam, soft, cv::Size(11, 11), 1.6);
        plan.seamWeights.push_back(std::move(soft));
    }
    cv::Mat multiband, blendedMask;
    blender.blend(multiband, blendedMask);
    multiband.convertTo(plan.multibandPreview, CV_32FC3);
    plan.multibandMask = std::move(blendedMask);
    return plan;
}

static cv::Mat LowFrequencyCorrectionFromRenderedImage(
    const BlendPlan &plan,
    const uint8_t *pixels,
    int outputW,
    int outputH,
    const cv::Rect2d &cropWorld,
    const cv::Rect2f &globalBounds,
    double scaleX,
    double scaleY
) {
    const int previewW = plan.multibandPreview.cols;
    const int previewH = plan.multibandPreview.rows;
    cv::Mat difference(previewH, previewW, CV_32FC3, cv::Scalar());
    cv::Mat valid(previewH, previewW, CV_32F, cv::Scalar());
    const double sampleSpanX = scaleX / plan.scale;
    const double sampleSpanY = scaleY / plan.scale;
    for (int y = 0; y < previewH; ++y) {
        const double worldY = globalBounds.y + y / plan.scale;
        const double centerY = (worldY - cropWorld.y) * scaleY;
        if (centerY < 0 || centerY >= outputH) continue;
        cv::Vec3f *differenceRow = difference.ptr<cv::Vec3f>(y);
        float *validRow = valid.ptr<float>(y);
        for (int x = 0; x < previewW; ++x) {
            if (!plan.multibandMask.at<uint8_t>(y, x)) continue;
            const double worldX = globalBounds.x + x / plan.scale;
            const double centerX = (worldX - cropWorld.x) * scaleX;
            if (centerX < 0 || centerX >= outputW) continue;
            cv::Vec3f baseline(0, 0, 0);
            for (int sy = 0; sy < 4; ++sy) {
                const int outputY = std::clamp(
                    static_cast<int>(std::floor(centerY + ((sy + 0.5) / 4.0 - 0.5) * sampleSpanY)),
                    0, outputH - 1
                );
                for (int sx = 0; sx < 4; ++sx) {
                    const int outputX = std::clamp(
                        static_cast<int>(std::floor(centerX + ((sx + 0.5) / 4.0 - 0.5) * sampleSpanX)),
                        0, outputW - 1
                    );
                    const uint8_t *pixel = pixels +
                        (static_cast<size_t>(outputY) * outputW + outputX) * 4;
                    baseline += cv::Vec3f(pixel[0], pixel[1], pixel[2]);
                }
            }
            baseline *= 1.0f / 16.0f;
            differenceRow[x] = plan.multibandPreview.at<cv::Vec3f>(y, x) - baseline;
            validRow[x] = 1;
        }
    }
    cv::Mat smoothedDifference, smoothedValid;
    cv::GaussianBlur(difference, smoothedDifference, cv::Size(), 3.0);
    cv::GaussianBlur(valid, smoothedValid, cv::Size(), 3.0);
    for (int y = 0; y < previewH; ++y) {
        cv::Vec3f *row = smoothedDifference.ptr<cv::Vec3f>(y);
        const float *weightRow = smoothedValid.ptr<float>(y);
        for (int x = 0; x < previewW; ++x) {
            if (weightRow[x] > 0.01f) row[x] *= 1.0f / weightRow[x];
            else row[x] = cv::Vec3f();
        }
    }
    return smoothedDifference;
}

static bool EncodeHEIF(const uint8_t *bytes, int width, int height, NSURL *url) {
    auto releaseBytes = [](void *, const void *, size_t) {};
    CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, bytes,
                                                              static_cast<size_t>(width) * height * 4,
                                                              releaseBytes);
    if (!provider) return false;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    CGImageRef image = CGImageCreate(width, height, 8, 32, static_cast<size_t>(width) * 4,
                                    colorSpace,
                                    kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
                                    provider, nullptr, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    if (!image) return false;
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, (__bridge CFStringRef)UTTypeHEIC.identifier, 1, nullptr
    );
    if (!destination) {
        CGImageRelease(image);
        return false;
    }
    NSDictionary *properties = @{(id)kCGImageDestinationLossyCompressionQuality: @0.94};
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    const bool succeeded = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    return succeeded;
}

} // namespace
#endif

@implementation UWStitcher

+ (nullable UWStitchOutcome *)stitchFrames:(NSArray<UWStitchFrame *> *)frames
                                  outputURL:(NSURL *)outputURL
                          maximumMegapixels:(NSInteger)maximumMegapixels
                          targetAspectRatio:(double)targetAspectRatio
                  minimumHorizontalFOVDegrees:(double)minimumHorizontalFOVDegrees
                    minimumVerticalFOVDegrees:(double)minimumVerticalFOVDegrees
                                   progress:(BOOL (^)(double))progress
                                      error:(NSError **)error {
#if TARGET_OS_SIMULATOR
    if (error) *error = UWError(UWStitcherErrorUnsupportedPlatform,
                                @"Photo assembly requires an iPhone.", nil);
    return nil;
#else
    if (frames.count < 2) {
        if (error) *error = UWError(UWStitcherErrorInsufficientImages,
                                    @"At least two photos are required.", nil);
        return nil;
    }
    if (frames.count > 96) {
        if (error) *error = UWError(UWStitcherErrorInvalidGeometry,
                                    @"A sweep supports up to 96 selected frames.", nil);
        return nil;
    }
    if (!Report(progress, 0, error)) return nil;
    std::string stage = "decode";
    try {
        const int frameCount = static_cast<int>(frames.count);
        std::vector<cv::Mat> thumbnails;
        thumbnails.reserve(frameCount);
        std::vector<cv::Size> fullSizes;
        fullSizes.reserve(frameCount);
        BOOL isPortrait = NO;
        for (int i = 0; i < frameCount; ++i) {
            @autoreleasepool {
                UWStitchFrame *frame = frames[i];
                cv::Size fullSize = OrientedPixelSize(frame.url);
                cv::Mat thumbnail = ReadBGR(frame.url, kThumbnailLongestSide);
                if (fullSize.empty() || thumbnail.empty()) {
                    if (error) *error = UWError(UWStitcherErrorUnreadableImage,
                                                @"A captured photo could not be decoded.", @[@(i)]);
                    return nil;
                }
                if (i == 0) isPortrait = thumbnail.rows > thumbnail.cols;
                if ((thumbnail.rows > thumbnail.cols) != isPortrait) {
                    if (error) *error = UWError(UWStitcherErrorInvalidGeometry,
                                                @"All photos in a sweep must have the same orientation.", @[@(i)]);
                    return nil;
                }
                fullSizes.push_back(fullSize);
                thumbnails.push_back(std::move(thumbnail));
            }
            if (!Report(progress, 0.03 + 0.12 * (i + 1) / frameCount, error)) return nil;
        }

        const double aspect = targetAspectRatio > 0 ? targetAspectRatio : (isPortrait ? 0.75 : 4.0 / 3.0);
        if (!std::isfinite(aspect) || aspect < 0.5 || aspect > 2.0) {
            if (error) *error = UWError(UWStitcherErrorInvalidGeometry,
                                        @"The requested output ratio is invalid.", nil);
            return nil;
        }
        if (!std::isfinite(minimumHorizontalFOVDegrees) ||
            !std::isfinite(minimumVerticalFOVDegrees) ||
            minimumHorizontalFOVDegrees < 0 || minimumHorizontalFOVDegrees > 170 ||
            minimumVerticalFOVDegrees < 0 || minimumVerticalFOVDegrees > 170) {
            if (error) *error = UWError(UWStitcherErrorInvalidGeometry,
                                        @"The requested field of view is invalid.", nil);
            return nil;
        }

        stage = "registration";
        cv::Ptr<cv::Stitcher> stitcher = cv::Stitcher::create(cv::Stitcher::PANORAMA);
        stitcher->setFeaturesFinder(cv::SIFT::create(1800));
        stitcher->setRegistrationResol(0.6);
        stitcher->setPanoConfidenceThresh(0.65);
        stitcher->setWaveCorrection(false);
        stitcher->setWarper(cv::makePtr<cv::PlaneWarper>());
        // A free sweep may revisit the same area and yields many closely
        // spaced video frames. Matching every pair becomes quadratic and
        // gives repeated texture many chances to form a false connection.
        // Keep temporal neighbors plus the closest views in motion space.
        if (frameCount > 20) {
            bool hasAllMotion = true;
            for (UWStitchFrame *frame in frames) hasAllMotion &= frame.hasMotion;
            if (hasAllMotion) {
                cv::Mat matchingMask(frameCount, frameCount, CV_8U, cv::Scalar(0));
                for (int i = 0; i < frameCount; ++i) {
                    matchingMask.at<uint8_t>(i, i) = 1;
                    for (int j = std::max(0, i - 3); j <= std::min(frameCount - 1, i + 3); ++j) {
                        matchingMask.at<uint8_t>(i, j) = 1;
                        matchingMask.at<uint8_t>(j, i) = 1;
                    }
                    std::vector<std::pair<double, int>> neighbors;
                    neighbors.reserve(frameCount - 1);
                    const UWStitchFrame *first = frames[i];
                    for (int j = 0; j < frameCount; ++j) {
                        if (i == j) continue;
                        const UWStitchFrame *second = frames[j];
                        const double distance = std::hypot(
                            first.yawRadians - second.yawRadians,
                            first.pitchRadians - second.pitchRadians
                        );
                        if (std::isfinite(distance)) neighbors.emplace_back(distance, j);
                    }
                    const size_t count = std::min<size_t>(16, neighbors.size());
                    std::partial_sort(neighbors.begin(), neighbors.begin() + count, neighbors.end());
                    for (size_t j = 0; j < count; ++j) {
                        const int neighbor = neighbors[j].second;
                        matchingMask.at<uint8_t>(i, neighbor) = 1;
                        matchingMask.at<uint8_t>(neighbor, i) = 1;
                    }
                }
                stitcher->setMatchingMask(matchingMask.getUMat(cv::ACCESS_READ));
            }
        }
        cv::Stitcher::Status status = stitcher->estimateTransform(thumbnails);
        if (status != cv::Stitcher::OK) {
            NSLog(@"[UltraWide Stitch] registration failed: status=%d frames=%d",
                  static_cast<int>(status), frameCount);
            UWStitcherErrorCode code = status == cv::Stitcher::ERR_NEED_MORE_IMGS
                ? UWStitcherErrorInsufficientOverlap : UWStitcherErrorInvalidGeometry;
            if (error) *error = UWError(code,
                                        @"OpenCV could not find a reliable alignment between the photos.", nil);
            return nil;
        }
        if (!Report(progress, 0.35, error)) return nil;

        const std::vector<int> component = stitcher->component();
        const std::vector<cv::detail::CameraParams> cameras = stitcher->cameras();
        if (component.size() < 2 || component.size() != cameras.size()) {
            if (error) *error = UWError(UWStitcherErrorInsufficientOverlap,
                                        @"The photos do not form one connected image.", nil);
            return nil;
        }
        for (size_t i = 0; i < component.size(); ++i) {
            if (component[i] < 0 || component[i] >= frameCount ||
                cameras[i].R.rows != 3 || cameras[i].R.cols != 3) {
                if (error) *error = UWError(UWStitcherErrorInvalidGeometry,
                                            @"Camera alignment returned invalid frame geometry.", nil);
                return nil;
            }
        }
        NSMutableArray<NSNumber *> *used = [NSMutableArray arrayWithCapacity:component.size()];
        NSMutableArray<NSNumber *> *rejected = [NSMutableArray array];
        std::vector<bool> included(frameCount, false);
        for (int index : component) {
            included[index] = true;
            [used addObject:@(index)];
        }
        for (int i = 0; i < frameCount; ++i) if (!included[i]) [rejected addObject:@(i)];

        const double workScale = stitcher->workScale();
        if (!std::isfinite(workScale) || workScale <= 0) {
            if (error) *error = UWError(UWStitcherErrorInvalidGeometry,
                                        @"Camera calibration failed.", rejected);
            return nil;
        }
        // Camera parameters and component indexes above are value copies. The
        // estimator's feature and match caches are no longer needed for export.
        stitcher.release();
        std::vector<double> focals;
        focals.reserve(cameras.size());
        for (const auto &camera : cameras) focals.push_back(camera.focal / workScale);
        std::nth_element(focals.begin(), focals.begin() + focals.size() / 2, focals.end());
        const double focal = focals[focals.size() / 2];
        if (!std::isfinite(focal) || focal < 100 || focal > 50000) {
            if (error) *error = UWError(UWStitcherErrorInvalidGeometry,
                                        @"Camera calibration produced an invalid focal length.", rejected);
            return nil;
        }
        // Bundle adjustment only determines relative camera rotations. Its
        // absolute orientation is arbitrary, even when the first photograph
        // points at the center of the requested image. A plane projected in
        // that arbitrary frame can put the whole mosaic near its horizon;
        // measuring atan(x / focal) there dramatically underestimates the
        // covered field of view and may distort or reject a complete sweep.
        // Rebase all cameras on the captured center view before projection.
        size_t centerCamera = 0;
        double centerDistance = std::numeric_limits<double>::infinity();
        for (size_t i = 0; i < component.size(); ++i) {
            const UWStitchFrame *frame = frames[component[i]];
            if (!frame.hasMotion) continue;
            const double distance = std::hypot(frame.yawRadians, frame.pitchRadians);
            if (std::isfinite(distance) && distance < centerDistance) {
                centerDistance = distance;
                centerCamera = i;
            }
        }
        cv::Mat referenceRotation;
        stage = "reference rotation";
        cameras[centerCamera].R.convertTo(referenceRotation, CV_32F);
        const cv::Mat referenceInverse = referenceRotation.t();
        stage = "projection";
        cv::detail::PlaneWarper warper(static_cast<float>(focal));
        std::vector<FrameGeometry> geometry;
        geometry.reserve(component.size());
        cv::Rect2f globalBounds;
        for (size_t i = 0; i < component.size(); ++i) {
            stage = "projection frame " + std::to_string(i);
            const int inputIndex = component[i];
            const cv::Mat &thumbnail = thumbnails[inputIndex];
            cv::detail::CameraParams camera = cameras[i];
            camera.focal /= workScale;
            camera.ppx /= workScale;
            camera.ppy /= workScale;
            cv::Mat K;
            camera.K().convertTo(K, CV_32F); // PlaneWarper requires float intrinsics.
            cv::Mat R;
            camera.R.convertTo(R, CV_32F);
            R = referenceInverse * R;
            std::array<cv::Point2f, 4> corners = {
                cv::Point2f(0, 0),
                cv::Point2f(static_cast<float>(thumbnail.cols - 1), 0),
                cv::Point2f(static_cast<float>(thumbnail.cols - 1), static_cast<float>(thumbnail.rows - 1)),
                cv::Point2f(0, static_cast<float>(thumbnail.rows - 1))
            };
            for (auto &corner : corners) {
                stage = "projection point in frame " + std::to_string(i);
                corner = warper.warpPoint(corner, K, R);
                if (!FinitePoint(corner)) {
                    if (error) *error = UWError(UWStitcherErrorInvalidGeometry,
                                                @"An image projects outside the rectilinear canvas.", rejected);
                    return nil;
                }
            }
            stage = "projection geometry in frame " + std::to_string(i);
            const cv::Rect2f bounds = Bounds(corners);
            const double projectedArea = std::abs(cv::contourArea(std::vector<cv::Point2f>(corners.begin(), corners.end())));
            const double sourceArea = static_cast<double>(thumbnail.cols) * thumbnail.rows;
            if (!cv::isContourConvex(std::vector<cv::Point2f>(corners.begin(), corners.end())) ||
                projectedArea < sourceArea * 0.08 || projectedArea > sourceArea * 30.0) {
                if (error) *error = UWError(UWStitcherErrorInvalidGeometry,
                                            @"The rectilinear projection is too distorted.", rejected);
                return nil;
            }
            geometry.push_back({inputIndex, corners, bounds});
            globalBounds = i == 0 ? bounds : (globalBounds | bounds);
        }
        stage = "projection coverage";
        if (globalBounds.width <= 0 || globalBounds.height <= 0 ||
            globalBounds.width > 30000 || globalBounds.height > 30000) {
            if (error) *error = UWError(UWStitcherErrorInvalidGeometry,
                                        @"The projected sweep is too large.", rejected);
            return nil;
        }

        const double previewScale = std::min(1.0, 800.0 / std::max(globalBounds.width, globalBounds.height));
        const int previewW = std::max(1, static_cast<int>(std::ceil(globalBounds.width * previewScale)) + 2);
        const int previewH = std::max(1, static_cast<int>(std::ceil(globalBounds.height * previewScale)) + 2);
        cv::Mat coverage(previewH, previewW, CV_8U, cv::Scalar(0));
        for (const auto &frame : geometry) {
            std::vector<cv::Point> polygon;
            for (const auto &corner : frame.worldCorners) {
                polygon.emplace_back(
                    static_cast<int>(std::round((corner.x - globalBounds.x) * previewScale)),
                    static_cast<int>(std::round((corner.y - globalBounds.y) * previewScale))
                );
            }
            cv::fillConvexPoly(coverage, polygon, cv::Scalar(1));
        }
        cv::erode(coverage, coverage, cv::Mat(), cv::Point(-1, -1), 2);
        cv::Rect cropPreview;
        stage = "projection crop";
        if (!FindCoveredRectangle(coverage, aspect, cropPreview)) {
            NSLog(@"[UltraWide Stitch] no fully covered crop: frames=%d used=%zu rejected=%lu canvas=%dx%d aspect=%.3f",
                  frameCount, component.size(), static_cast<unsigned long>(rejected.count),
                  previewW, previewH, aspect);
            if (error) *error = UWError(UWStitcherErrorIncompleteCoverage,
                                        @"The sweep has gaps inside the requested image.", rejected);
            return nil;
        }
        const cv::Rect2d cropWorld(
            globalBounds.x + cropPreview.x / previewScale,
            globalBounds.y + cropPreview.y / previewScale,
            cropPreview.width / previewScale,
            cropPreview.height / previewScale
        );
        const double radiansToDegrees = 180.0 / std::acos(-1.0);
        const double actualHorizontalFOV =
            (std::atan((cropWorld.x + cropWorld.width) / focal) -
             std::atan(cropWorld.x / focal)) * radiansToDegrees;
        const double actualVerticalFOV =
            (std::atan((cropWorld.y + cropWorld.height) / focal) -
             std::atan(cropWorld.y / focal)) * radiansToDegrees;
        constexpr double kFieldTolerance = 0.92;
        if ((minimumHorizontalFOVDegrees > 0 &&
             actualHorizontalFOV < minimumHorizontalFOVDegrees * kFieldTolerance) ||
            (minimumVerticalFOVDegrees > 0 &&
             actualVerticalFOV < minimumVerticalFOVDegrees * kFieldTolerance)) {
            NSLog(@"[UltraWide Stitch] field too narrow: actual=%.1f°×%.1f° target=%.1f°×%.1f° used=%zu rejected=%lu",
                  actualHorizontalFOV, actualVerticalFOV,
                  minimumHorizontalFOVDegrees, minimumVerticalFOVDegrees,
                  component.size(), static_cast<unsigned long>(rejected.count));
            if (error) *error = UWError(UWStitcherErrorIncompleteCoverage,
                                        @"The completed crop is narrower than the requested field of view.",
                                        rejected);
            return nil;
        }
        if (!Report(progress, 0.43, error)) return nil;

        stage = "projection export dimensions";
        std::vector<double> nativeScales;
        for (size_t i = 0; i < component.size(); ++i) {
            const int index = component[i];
            nativeScales.push_back(std::min(
                static_cast<double>(fullSizes[index].width) / thumbnails[index].cols,
                static_cast<double>(fullSizes[index].height) / thumbnails[index].rows
            ));
        }
        std::nth_element(nativeScales.begin(), nativeScales.begin() + nativeScales.size() / 2, nativeScales.end());
        const double nativeScale = nativeScales[nativeScales.size() / 2];
        const unsigned long long physicalMemory = NSProcessInfo.processInfo.physicalMemory;
        const NSInteger memoryCap = physicalMemory < 5ULL * 1024 * 1024 * 1024 ? 20
                                  : physicalMemory < 7ULL * 1024 * 1024 * 1024 ? 32 : 48;
        const double maxPixels = static_cast<double>(
            std::min(std::clamp<NSInteger>(maximumMegapixels, 1, 48), memoryCap)
        ) * 1'000'000;
        const double scale = std::min(nativeScale, std::sqrt(maxPixels / cropWorld.area()));
        int outputW, outputH;
        if (std::abs(aspect - 4.0 / 3.0) < 0.0001) {
            const int unit = static_cast<int>(std::floor(std::min(cropWorld.width * scale / 4.0,
                                                                 cropWorld.height * scale / 3.0)));
            outputW = unit * 4; outputH = unit * 3;
        } else if (std::abs(aspect - 3.0 / 4.0) < 0.0001) {
            const int unit = static_cast<int>(std::floor(std::min(cropWorld.width * scale / 3.0,
                                                                 cropWorld.height * scale / 4.0)));
            outputW = unit * 3; outputH = unit * 4;
        } else {
            outputW = static_cast<int>(std::floor(std::min(cropWorld.width * scale,
                                                           cropWorld.height * scale * aspect)));
            outputH = static_cast<int>(std::floor(outputW / aspect));
        }
        if (outputW < 256 || outputH < 256 || static_cast<double>(outputW) * outputH > maxPixels) {
            NSLog(@"[UltraWide Stitch] export crop too small: %dx%d crop=%.0fx%.0f",
                  outputW, outputH, cropWorld.width, cropWorld.height);
            if (error) *error = UWError(UWStitcherErrorIncompleteCoverage,
                                        @"The complete area is too small to export.", rejected);
            return nil;
        }
        const double scaleX = outputW / cropWorld.width;
        const double scaleY = outputH / cropWorld.height;
        const size_t pixelCount = static_cast<size_t>(outputW) * outputH;
        const size_t colorBytes = pixelCount * 4;
        const size_t weightBytes = pixelCount * sizeof(uint16_t);
        NSDictionary *disk = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSTemporaryDirectory() error:nil];
        const unsigned long long freeBytes = [disk[NSFileSystemFreeSize] unsignedLongLongValue];
        if (freeBytes && freeBytes < (colorBytes + weightBytes) * 2) {
            if (error) *error = UWError(UWStitcherErrorExportFailed,
                                        @"Not enough free storage to assemble the image.", rejected);
            return nil;
        }
        MappedFile colorFile, weightFile;
        if (!colorFile.create(colorBytes) || !weightFile.create(weightBytes)) {
            if (error) *error = UWError(UWStitcherErrorExportFailed,
                                        @"The temporary image buffer could not be created.", rejected);
            return nil;
        }
        auto *pixels = static_cast<uint8_t *>(colorFile.bytes);
        auto *weights = static_cast<uint16_t *>(weightFile.bytes);
        stage = "seams and color";
        const auto exposureGains = EstimateExposureGains(
            geometry, thumbnails, globalBounds, previewW, previewH, previewScale
        );
        if (!Report(progress, 0.46, error)) return nil;
        const BlendPlan blendPlan = BuildBlendPlan(geometry, thumbnails, exposureGains, globalBounds);
        if (!Report(progress, 0.49, error)) return nil;
        std::vector<cv::Size> thumbnailSizes;
        thumbnailSizes.reserve(thumbnails.size());
        for (const auto &thumbnail : thumbnails) thumbnailSizes.push_back(thumbnail.size());
        thumbnails.clear();
        thumbnails.shrink_to_fit();
        if (!Report(progress, 0.50, error)) return nil;

        const double seamStartX = (cropWorld.x - globalBounds.x) * blendPlan.scale;
        const double seamStartY = (cropWorld.y - globalBounds.y) * blendPlan.scale;
        const double seamStepX = blendPlan.scale / scaleX;
        const double seamStepY = blendPlan.scale / scaleY;
        std::vector<int> seamColumns(outputW);
        for (int x = 0; x < outputW; ++x) {
            seamColumns[x] = static_cast<int>(std::round(seamStartX + x * seamStepX));
        }

        stage = "full-resolution render";
        for (size_t frameNumber = 0; frameNumber < geometry.size(); ++frameNumber) {
            @autoreleasepool {
                const FrameGeometry &frame = geometry[frameNumber];
                const int index = static_cast<int>(frame.inputIndex);
                const cv::Size thumbnailSize = thumbnailSizes[index];
                const int decodeSide = std::min(
                    std::max(fullSizes[index].width, fullSizes[index].height),
                    static_cast<int>(std::ceil(std::max(thumbnailSize.width, thumbnailSize.height) *
                                               std::max(scaleX, scaleY) * 1.02))
                );
                cv::Mat source = ReadBGR(frames[index].url, std::max(256, decodeSide));
                if (source.empty()) {
                    if (error) *error = UWError(UWStitcherErrorUnreadableImage,
                                                @"A captured photo could not be decoded for export.", @[@(index)]);
                    return nil;
                }
                std::array<cv::Point2f, 4> sourceCorners = {
                    cv::Point2f(0, 0),
                    cv::Point2f(static_cast<float>(source.cols - 1), 0),
                    cv::Point2f(static_cast<float>(source.cols - 1), static_cast<float>(source.rows - 1)),
                    cv::Point2f(0, static_cast<float>(source.rows - 1))
                };
                std::array<cv::Point2f, 4> destinationCorners;
                for (size_t j = 0; j < 4; ++j) {
                    destinationCorners[j] = cv::Point2f(
                        static_cast<float>((frame.worldCorners[j].x - cropWorld.x) * scaleX),
                        static_cast<float>((frame.worldCorners[j].y - cropWorld.y) * scaleY)
                    );
                }
                cv::Mat H = cv::getPerspectiveTransform(sourceCorners.data(), destinationCorners.data());
                cv::Mat inverseH = H.inv();
                const cv::Rect2f imageBounds = Bounds(destinationCorners);
                const int left = std::max(0, static_cast<int>(std::floor(imageBounds.x)));
                const int top = std::max(0, static_cast<int>(std::floor(imageBounds.y)));
                const int right = std::min(outputW, static_cast<int>(std::ceil(imageBounds.br().x)));
                const int bottom = std::min(outputH, static_cast<int>(std::ceil(imageBounds.br().y)));
                const double h00 = inverseH.at<double>(0, 0), h01 = inverseH.at<double>(0, 1), h02 = inverseH.at<double>(0, 2);
                const double h10 = inverseH.at<double>(1, 0), h11 = inverseH.at<double>(1, 1), h12 = inverseH.at<double>(1, 2);
                const double h20 = inverseH.at<double>(2, 0), h21 = inverseH.at<double>(2, 1), h22 = inverseH.at<double>(2, 2);
                const double featherWidth = std::max(8.0, std::min(source.cols, source.rows) * 0.09);
                const cv::Mat &seamWeight = blendPlan.seamWeights[frameNumber];
                std::array<std::array<uint8_t, 256>, 3> colorLUT;
                for (int channel = 0; channel < 3; ++channel) {
                    for (int value = 0; value < 256; ++value) {
                        colorLUT[channel][value] = static_cast<uint8_t>(std::clamp(
                            static_cast<int>(std::round(value * exposureGains[frameNumber][channel])),
                            0, 255
                        ));
                    }
                }

                for (int tileY = top / kTileSide * kTileSide; tileY < bottom; tileY += kTileSide) {
                    for (int tileX = left / kTileSide * kTileSide; tileX < right; tileX += kTileSide) {
                        const int tileW = std::min(kTileSide, outputW - tileX);
                        const int tileH = std::min(kTileSide, outputH - tileY);
                        cv::Mat tile;
                        cv::Mat translation = (cv::Mat_<double>(3, 3) <<
                            1, 0, -tileX,
                            0, 1, -tileY,
                            0, 0, 1);
                        cv::warpPerspective(source, tile, translation * H, cv::Size(tileW, tileH),
                                            cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar());
                        for (int y = std::max(top, tileY); y < std::min(bottom, tileY + tileH); ++y) {
                            const cv::Vec3b *row = tile.ptr<cv::Vec3b>(y - tileY);
                            const int seamY = static_cast<int>(std::round(seamStartY + y * seamStepY));
                            const uint8_t *seamRow = seamY >= 0 && seamY < seamWeight.rows
                                ? seamWeight.ptr<uint8_t>(seamY) : nullptr;
                            for (int x = std::max(left, tileX); x < std::min(right, tileX + tileW); ++x) {
                                const double denominator = h20 * x + h21 * y + h22;
                                if (std::abs(denominator) < 1e-8) continue;
                                const double sourceX = (h00 * x + h01 * y + h02) / denominator;
                                const double sourceY = (h10 * x + h11 * y + h12) / denominator;
                                if (sourceX < 0.5 || sourceY < 0.5 ||
                                    sourceX >= source.cols - 1.5 || sourceY >= source.rows - 1.5) continue;
                                const double edge = std::min({sourceX, sourceY,
                                                              source.cols - 1.0 - sourceX,
                                                              source.rows - 1.0 - sourceY});
                                const size_t offset = static_cast<size_t>(y) * outputW + x;
                                const uint16_t previous = weights[offset];
                                const int seamX = seamColumns[x];
                                const uint8_t softMask = seamRow && seamX >= 0 && seamX < seamWeight.cols
                                    ? seamRow[seamX] : 0;
                                if (!softMask && previous) continue;
                                const uint16_t contribution = static_cast<uint16_t>(std::clamp(
                                    256.0 * edge / featherWidth *
                                    (softMask ? softMask / 255.0 : 1.0 / 256.0), 1.0, 256.0
                                ));
                                const uint16_t total = previous + contribution;
                                const cv::Vec3b &color = row[x - tileX];
                                uint8_t *pixel = pixels + offset * 4;
                                if (previous == 0) {
                                    for (int channel = 0; channel < 3; ++channel) {
                                        pixel[channel] = colorLUT[channel][color[channel]];
                                    }
                                    pixel[3] = 255;
                                } else {
                                    for (int channel = 0; channel < 3; ++channel) {
                                        const uint32_t corrected = colorLUT[channel][color[channel]];
                                        pixel[channel] = static_cast<uint8_t>(
                                            (static_cast<uint32_t>(pixel[channel]) * previous +
                                             corrected * contribution + total / 2) / total
                                        );
                                    }
                                }
                                weights[offset] = total;
                            }
                        }
                    }
                }
            }
            if (!Report(progress, 0.50 + 0.40 * (frameNumber + 1) / geometry.size(), error)) return nil;
        }

        // No inpainting: an incomplete pixel invalidates the export before color correction.
        for (size_t i = 0; i < pixelCount; ++i) {
            if (weights[i] == 0) {
                NSLog(@"[UltraWide Stitch] uncovered output pixel: x=%zu y=%zu size=%dx%d",
                      i % outputW, i / outputW, outputW, outputH);
                if (error) *error = UWError(UWStitcherErrorIncompleteCoverage,
                                            @"The selected image still contains an uncovered pixel.", rejected);
                return nil;
            }
        }
        // Compare OpenCV's multiband preview with the actual weighted full-resolution
        // mosaic. This avoids applying a single-source correction twice at soft seams.
        const cv::Mat correctionMap = LowFrequencyCorrectionFromRenderedImage(
            blendPlan, pixels, outputW, outputH, cropWorld, globalBounds, scaleX, scaleY
        );
        constexpr int kCorrectionRows = 128;
        for (int firstY = 0; firstY < outputH; firstY += kCorrectionRows) {
            const int rowCount = std::min(kCorrectionRows, outputH - firstY);
            const cv::Mat destinationToPreview = (cv::Mat_<double>(2, 3) <<
                seamStepX, 0, seamStartX,
                0, seamStepY, seamStartY + firstY * seamStepY
            );
            cv::Mat correctionTile;
            cv::warpAffine(correctionMap, correctionTile, destinationToPreview,
                           cv::Size(outputW, rowCount), cv::INTER_LINEAR | cv::WARP_INVERSE_MAP,
                           cv::BORDER_REPLICATE);
            for (int localY = 0; localY < rowCount; ++localY) {
                const int y = firstY + localY;
                const cv::Vec3f *correctionRow = correctionTile.ptr<cv::Vec3f>(localY);
                for (int x = 0; x < outputW; ++x) {
                    const size_t offset = static_cast<size_t>(y) * outputW + x;
                    uint8_t *pixel = pixels + offset * 4;
                    for (int channel = 0; channel < 3; ++channel) {
                        pixel[channel] = static_cast<uint8_t>(std::clamp(
                            static_cast<int>(std::round(pixel[channel] +
                                std::clamp(correctionRow[x][channel], -40.0f, 40.0f))),
                            0, 255
                        ));
                    }
                }
            }
            if (!Report(progress, 0.90 + 0.04 * (firstY + rowCount) / outputH, error)) return nil;
        }
        if (!Report(progress, 0.94, error)) return nil;
        stage = "HEIF export";
        NSURL *directory = [outputURL URLByDeletingLastPathComponent];
        NSError *directoryError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:directory
                                      withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
            if (error) *error = UWError(UWStitcherErrorExportFailed,
                                        directoryError.localizedDescription ?: @"The output directory could not be created.",
                                        rejected);
            return nil;
        }
        NSURL *temporaryURL = [directory URLByAppendingPathComponent:
                               [NSString stringWithFormat:@".%@.heic", NSUUID.UUID.UUIDString]];
        if (!EncodeHEIF(pixels, outputW, outputH, temporaryURL)) {
            [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
            if (error) *error = UWError(UWStitcherErrorExportFailed,
                                        @"HEIF export failed.", rejected);
            return nil;
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:outputURL.path]) {
            [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
            if (error) *error = UWError(UWStitcherErrorExportFailed,
                                        @"The output file already exists.", rejected);
            return nil;
        }
        NSError *moveError = nil;
        if (![[NSFileManager defaultManager] moveItemAtURL:temporaryURL toURL:outputURL error:&moveError]) {
            [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
            if (error) *error = UWError(UWStitcherErrorExportFailed,
                                        moveError.localizedDescription ?: @"The image could not be written.", rejected);
            return nil;
        }
        Report(progress, 1, nullptr);
        UWStitchOutcome *outcome = [UWStitchOutcome new];
        outcome.imageURL = outputURL;
        outcome.pixelWidth = outputW;
        outcome.pixelHeight = outputH;
        outcome.usedFrameIndexes = used;
        outcome.rejectedFrameIndexes = rejected;
        return outcome;
    } catch (const cv::Exception &exception) {
        if (error) *error = UWError(UWStitcherErrorInvalidGeometry,
                                    [NSString stringWithUTF8String:exception.what()], nil);
        return nil;
    } catch (const std::exception &exception) {
        NSLog(@"[UltraWide Stitch] %s exception: %s", stage.c_str(), exception.what());
        if (error) *error = UWError(UWStitcherErrorExportFailed,
                                    [NSString stringWithFormat:@"%s: %s", stage.c_str(), exception.what()], nil);
        return nil;
    }
#endif
}
@end
