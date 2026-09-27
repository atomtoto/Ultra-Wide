# OpenCV for iPhone

`opencv2.framework` is the arm64 iPhone slice of the official OpenCV 4.13.0
iOS framework release. It is statically linked into the iPhone app; the iOS
Simulator build excludes the native stitching bridge.

- Source: <https://github.com/opencv/opencv/releases/tag/4.13.0>
- Original archive SHA-256: `7ac1a77d21aa9556422e08d8b7ffcc30dfa9ebc0351a0ff32216395e8b14bede`
- License: [Apache License 2.0](LICENSE)
- Rebuild this folder: `scripts/prepare-opencv.sh`

The framework is kept in the repository so an iPhone build does not download
dependencies during Xcode compilation.
