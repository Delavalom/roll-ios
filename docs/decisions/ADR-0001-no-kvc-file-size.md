# ADR-0001: No KVC file size on PHAssetResource

**Status:** accepted, 2026-10-22

## Context

PhotoKit has no public API for an asset's file size. A widely copied trick reads `fileSize` from `PHAssetResource` through key-value coding. That key is undocumented, so relying on it is an App Review risk and can break in any iOS release.

## Decision

Roll does not use KVC on `PHAssetResource`. Sizes are estimates:

- photos: pixel count times a bytes-per-pixel factor chosen by type (HEIC, JPEG, PNG);
- videos: duration times a bitrate table keyed by resolution and frame rate.

The UI always says "about". When Squish runs it measures real bytes, so the post-squish number is exact.

## Consequences

Totals on the Home screen are approximate. In exchange the app uses only public API.
