#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const UWStitcherErrorDomain;
FOUNDATION_EXPORT NSString * const UWStitcherRejectedIndexesKey;

typedef NS_ENUM(NSInteger, UWStitcherErrorCode) {
    UWStitcherErrorInsufficientImages = 1,
    UWStitcherErrorUnreadableImage = 2,
    UWStitcherErrorInsufficientOverlap = 3,
    UWStitcherErrorInvalidGeometry = 4,
    UWStitcherErrorIncompleteCoverage = 5,
    UWStitcherErrorExportFailed = 6,
    UWStitcherErrorCancelled = 7,
    UWStitcherErrorUnsupportedPlatform = 8,
};

@interface UWStitchFrame : NSObject
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) double yawRadians;
@property (nonatomic, readonly) double pitchRadians;
@property (nonatomic, readonly) double rollRadians;
@property (nonatomic, readonly) BOOL hasMotion;
/// Row-major source-normalized to target-normalized homography, both using a top-left origin.
@property (nonatomic, readonly, nullable) NSArray<NSNumber *> *normalizedHomography;
@property (nonatomic, readonly) NSInteger sourcePixelWidth;
@property (nonatomic, readonly) NSInteger sourcePixelHeight;
/// Scalar gain applied to linear-light RGB, after image decoding.
@property (nonatomic, readonly) double luminanceGain;

- (instancetype)initWithURL:(NSURL *)url
               yawRadians:(double)yawRadians
             pitchRadians:(double)pitchRadians
              rollRadians:(double)rollRadians
                hasMotion:(BOOL)hasMotion;
- (instancetype)initWithURL:(NSURL *)url
               yawRadians:(double)yawRadians
             pitchRadians:(double)pitchRadians
              rollRadians:(double)rollRadians
                hasMotion:(BOOL)hasMotion
     normalizedHomography:(nullable NSArray<NSNumber *> *)normalizedHomography
         sourcePixelWidth:(NSInteger)sourcePixelWidth
        sourcePixelHeight:(NSInteger)sourcePixelHeight;
- (instancetype)initWithURL:(NSURL *)url
               yawRadians:(double)yawRadians
             pitchRadians:(double)pitchRadians
              rollRadians:(double)rollRadians
                hasMotion:(BOOL)hasMotion
     normalizedHomography:(nullable NSArray<NSNumber *> *)normalizedHomography
         sourcePixelWidth:(NSInteger)sourcePixelWidth
        sourcePixelHeight:(NSInteger)sourcePixelHeight
            luminanceGain:(double)luminanceGain NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface UWStitchOutcome : NSObject
@property (nonatomic, readonly) NSURL *imageURL;
@property (nonatomic, readonly) NSInteger pixelWidth;
@property (nonatomic, readonly) NSInteger pixelHeight;
@property (nonatomic, readonly) NSArray<NSNumber *> *usedFrameIndexes;
@property (nonatomic, readonly) NSArray<NSNumber *> *rejectedFrameIndexes;
@property (nonatomic, readonly) BOOL reusedPreparedAlignment;
@end

/// Synchronous native worker. Call from a non-main actor. The progress block can cancel by returning NO.
/// preparedFocalRatio is the rectilinear focal length divided by target canvas height;
/// pass zero with unprepared frames to retain the complete legacy registration path.
@interface UWStitcher : NSObject
+ (nullable UWStitchOutcome *)stitchFrames:(NSArray<UWStitchFrame *> *)frames
                                  outputURL:(NSURL *)outputURL
                          maximumMegapixels:(NSInteger)maximumMegapixels
                          targetAspectRatio:(double)targetAspectRatio
                  minimumHorizontalFOVDegrees:(double)minimumHorizontalFOVDegrees
                    minimumVerticalFOVDegrees:(double)minimumVerticalFOVDegrees
                         preparedFocalRatio:(double)preparedFocalRatio
                                   progress:(nullable BOOL (^)(double fraction))progress
                                      error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
