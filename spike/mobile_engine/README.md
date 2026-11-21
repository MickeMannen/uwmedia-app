# UWMedia mobile engine spike (option B)

A throwaway app that measures the phones' own media engines on the work
UWMedia will give them (spec §11, owner decision 2026-11-13: native
engines, Media3 Transformer on Android and AVFoundation on iOS). Nothing
here goes into the app as it is; the numbers decide how the mobile engine
is built.

## What it runs

Pick a video, then **Run all** (or one step at a time):

| Step | What | Engine call |
|---|---|---|
| F0 | the video's size, length, frame rate, codec | retriever / `AVAsset` |
| F1 | a frame grab (at 10 s, or the middle) | `MediaMetadataRetriever` / `AVAssetImageGenerator` |
| F3 | a 1080p downscale | `Presentation` / `AVAssetExportPreset1920x1080` |
| F4 | the app's own colour correction: the frame analysed by the app's colour engine, its 64³ LUT applied to the whole video | `SingleColorLut` / `CIColorCubeWithColorSpace` |
| F5 | an overlay picture a second (as the dive samples come) over the video at its own size, bottom left | `OverlayEffect` / Core Image compositing |
| F6 | the last output saved into a new album "UWMedia Spike" | `MediaStore` (`Movies/UWMedia Spike`) / `PHAssetCollection` |
| F7 | **Pick photos** (a few, including an iPhone HEIC or a Samsung JPEG from the camera): their format and whether their EXIF dates came through the picker, read by the app's own readers | `image_picker` + `heic_exif.dart` / `jpeg_exif.dart` |
| F8 | a copy of the first picked photo with its dates moved one hour by the app's own writers, saved into the album; the original untouched | `shiftUpdates` + the writers, `MediaStore` (`Pictures/…`) / `PHAssetChangeRequest` |

F0 also reports the video's own dates as the app's MP4 reader sees them
(did the picker keep them?). F7 and F8 run without a video: tap
**F7 Pick photos**, then **F8 Shifted copy**, and check in the gallery that
the album has the copy, an hour later, and that the original is as it
was.

Each line gives the time, the speed against real time, the file size and
the codec the engine chose. **Copy** puts all lines on the clipboard:
paste them back into the session, or into `docs/roadmap.md` section A.

Use a **4K clip of 1–2 minutes** from the phone's own camera (and, if you
have one, a clip from the action camera you dive with), so F4 and F5 run
at the size that matters.

## Running it

From this folder (`spike/mobile_engine`):

- **Samsung Galaxy S25:** Settings → About phone → Software information →
  tap *Build number* seven times; then Developer options → *USB
  debugging* on. Connect the phone, accept the prompt, then
  `flutter run --release -d <device>` (`flutter devices` lists it).
  Android Studio: open `spike/mobile_engine`, pick the phone, Run.
- **iPhone 18 Max:** open `ios/Runner.xcworkspace` in Xcode, select the
  *Runner* target → *Signing & Capabilities* → your Team (the bundle id
  is `org.christersson.uwmedia.spike`). On the phone turn on Settings →
  Privacy & Security → *Developer Mode*. Then `flutter run --release -d
  <device>`, or Run in Xcode. The first launch asks to trust the
  developer under Settings → General → VPN & Device Management.

Use `--release`: debug builds are much slower and the times would mean
nothing.

## Checked before handing over (2026-11-13)

- Both apps build (`flutter build apk`, `flutter build ios --no-codesign`).
- Every engine call ran on the iPhone 18 Pro Max simulator on a 1080p
  ffmpeg clip (`integration_test/engine_test.dart`): an all-red LUT gives
  red frames, the app's LUT the expected colours, the overlay sits at the
  bottom left. The simulator encodes in software, so its times are no
  guide. Android has no emulator here; the S25 is its first run.
- Size: the Media3 engine and the spike's Kotlin are about 1.6 MB of the
  release APK (`classes.dex`); AVFoundation is part of iOS. The 55 MB
  of the release builds is mostly the main app's assets (templates,
  fonts), which the spike pulls in with the colour engine.

Run the engine test on a device or simulator:

    flutter test integration_test -d <device> \
      --dart-define=CLIP=/path/to/clip.mp4 [--dart-define=OUT=/folder]
