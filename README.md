# Caret Trail

System-wide smooth caret animation for macOS. A transparent overlay follows the text caret
of whatever app is frontmost and draws a short smear from where the caret was to where it
is now, then fades out on top of the real caret. The native caret is never hidden or replaced.

## Run

```sh
./build.sh
open build/CaretTrail.app
swift test   # motion, notification scheduling, and rendering checks
```

Then enable **Caret Trail** in System Settings → Privacy & Security → Accessibility.
The app polls for the grant and starts tracking as soon as it is on. Switch to any other
app and move the caret with arrows, clicks, or typing.

The bundle is signed with the Developer ID identity so the Accessibility grant survives
rebuilds. Override with `CODESIGN_IDENTITY=...`.

## How it works

- `CaretTracker` attaches an `AXObserver` to the frontmost app and its focused text field.
  Selection notifications from the field reuse the cached focus; bursts share one lookup on the
  next main-loop turn. Focus changes always recheck the field. It polls every 200 ms while it is
  following a caret (to catch scrolling and apps that stay silent) and once a second while there
  is none. It deliberately ignores layout,
  move, and resize notifications: web content posts a layout change on every hover, and each one
  used to cost the browser a burst of synchronous accessibility calls.
- Caret bounds come from the VoiceOver text-marker API when the app offers it (WebKit,
  Chromium, Electron), otherwise from `AXBoundsForRange` on the glyph next to the caret
  (AppKit). Zero-length ranges are only a last resort because AppKit reports them a line
  too high.
- `OverlayWindow` is a borderless, click-through window at screen-saver level that exists only
  while a trail is on screen and is sized to the trail. Between moves nothing sits above other
  apps. `CaretTrailView` rides four independent springs, one per caret corner, in screen
  coordinates and maps them into the window when it draws. The window expands if spring
  overshoot needs more room, keeping the glow unclipped on long jumps.
- The display link is prepared in a paused state, then runs only during animation. Starting a
  trail advances the springs immediately by one display interval, so the first frame already
  shows motion. A smooth fade blends into the native caret; explicit shadow geometry and Retina
  layer scales keep the glow inexpensive and sharp.
- Disabling stops tracking and hides the overlay immediately. Re-enabling restarts immediately;
  permission loss and application shutdown also stop tracking. Settings persist in `UserDefaults`.

Debug logging: `CARET_TRAIL_DEBUG=1 build/CaretTrail.app/Contents/MacOS/CaretTrail`.

## Known gaps

- Chromium's native address bar and other Views-toolkit fields report no caret bounds.
- Selections (non-empty ranges) hide the trail; it resumes when the selection collapses.
- No per-app exclusions yet, so editors with their own caret animation show both.
