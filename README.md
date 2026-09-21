# Caret Trail

System-wide smooth caret animation for macOS. A transparent overlay follows the text caret
of whatever app is frontmost and draws a short smear from where the caret was to where it
is now, then fades out on top of the real caret. The native caret is never hidden or replaced.

## Run

```sh
./build.sh
open build/CaretTrail.app
swift test   # spring maths
```

Then enable **Caret Trail** in System Settings → Privacy & Security → Accessibility.
The app polls for the grant and starts tracking as soon as it is on. Switch to any other
app and move the caret with arrows, clicks, or typing.

The bundle is signed with the Developer ID identity so the Accessibility grant survives
rebuilds. Override with `CODESIGN_IDENTITY=...`.

## How it works

- `CaretTracker` attaches an `AXObserver` to the frontmost app, listens for selection and
  focus changes, and polls every 200 ms to catch scrolling and apps that stay silent.
- Caret bounds come from the VoiceOver text-marker API when the app offers it (WebKit,
  Chromium, Electron), otherwise from `AXBoundsForRange` on the glyph next to the caret
  (AppKit). Zero-length ranges are only a last resort because AppKit reports them a line
  too high.
- `OverlayWindow` is a borderless, click-through window at screen-saver level that joins
  all Spaces. `CaretTrailView` puts each corner of a caret-shaped quad on its own damped
  spring: corners facing the direction of travel are stiff and land on the real caret within
  a frame or two without ever passing it, trailing corners are soft and lag. Velocity carries
  over between moves, so the trail has inertia. The further the tail is left behind, the
  narrower and more transparent it gets.
- The trail follows the system accent colour until a custom colour is picked in settings.
  Settings persist in `UserDefaults`.

Debug logging: `CARET_TRAIL_DEBUG=1 build/CaretTrail.app/Contents/MacOS/CaretTrail`.

## Known gaps

- Chromium's native address bar and other Views-toolkit fields report no caret bounds.
- Selections (non-empty ranges) hide the trail; it resumes when the selection collapses.
- No per-app exclusions yet, so editors with their own caret animation show both.
