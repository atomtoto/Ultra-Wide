#!/bin/zsh
set -euo pipefail

# Recreate the device-only framework committed under ThirdParty/OpenCV.
# The official release combines legacy iPhone and Intel simulator slices;
# this application links only its physical-iPhone arm64 slice.
SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
FRAMEWORK_DIR="${REPO_ROOT}/ThirdParty/OpenCV/opencv2.framework"
ARCHIVE_URL="https://github.com/opencv/opencv/releases/download/4.13.0/opencv-4.13.0-ios-framework.zip"
EXPECTED_SHA256="7ac1a77d21aa9556422e08d8b7ffcc30dfa9ebc0351a0ff32216395e8b14bede"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

curl --fail --location --output "${WORK_DIR}/opencv.zip" "${ARCHIVE_URL}"
ACTUAL_SHA256="$(shasum -a 256 "${WORK_DIR}/opencv.zip" | awk '{print $1}')"
if [[ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]]; then
    print -u2 "OpenCV archive checksum mismatch."
    exit 1
fi

unzip -q "${WORK_DIR}/opencv.zip" -d "${WORK_DIR}/unpacked"
mkdir -p "${REPO_ROOT}/ThirdParty/OpenCV"
rm -rf "${FRAMEWORK_DIR}"
ditto "${WORK_DIR}/unpacked/opencv2.framework" "${FRAMEWORK_DIR}"
lipo -thin arm64 "${FRAMEWORK_DIR}/Versions/A/opencv2" -output "${WORK_DIR}/opencv-arm64.a"
cp "${WORK_DIR}/opencv-arm64.a" "${FRAMEWORK_DIR}/Versions/A/opencv2"
lipo -info "${FRAMEWORK_DIR}/opencv2"
