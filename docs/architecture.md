# How Caret Trail works

Caret Trail draws a transparent overlay that follows the text caret of the frontmost app.
It leaves a short smear from the caret’s previous position to its new one, then fades out
on top of the real caret. The native caret is never hidden or replaced.

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


## Build and signing

```sh
CODESIGN_IDENTITY=- ./build.sh
open build/CaretTrail.app
swift test
```

`CODESIGN_IDENTITY=-` uses ad-hoc signing for a local build. After rebuilding, macOS may ask
you to grant Accessibility permission again.

By default, `build.sh` uses the maintainer’s Developer ID identity so the Accessibility grant
survives rebuilds. Set `CODESIGN_IDENTITY` to your own signing identity to use it instead.

The tests cover motion, notification scheduling, and rendering.

For debug logging:

```sh
CARET_TRAIL_DEBUG=1 build/CaretTrail.app/Contents/MacOS/CaretTrail
```
