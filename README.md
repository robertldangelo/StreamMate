# StreamMate

A native macOS app for streaming your screen or an individual window, with optional system audio, to a TV through its DLNA media-renderer service.

## Why I built it

I built StreamMate while travelling and staying at a hotel where the LG TV offered Miracast as its screen-sharing option. I wanted to get content from my Mac onto the room’s TV.

Investigating the TV revealed a reachable DLNA media-renderer service. StreamMate uses that service to ask the TV to play a live video stream served by the Mac.

**Testing is limited to one hotel TV, identified in the Wi-Fi list as `[LG] webOS TV UK760H0SD`.** Compatibility with other TVs, hotel configurations and firmware versions is unverified. A TV needs a reachable DLNA renderer that accepts the stream format described below.

## What it does

- Captures an entire display or an available application window.
- Offers 720p or 1080p output, targeting 30 frames per second.
- Offers video bitrates of 4, 6 or 10 Mbps.
- Optionally includes the Mac’s system audio.
- Finds the TV using its IPv4 address, with an optional explicit DLNA port.
- Provides a connection log and an optional stream sample for troubleshooting.

Whole-display capture currently crops the picture to fill a 16:9 TV. On a taller Mac screen, this can trim the menu bar and Dock. Window capture attempts to fit and centre the window within the output frame.

System audio can include sound from other applications even when a single window is selected.

## Requirements

- A Mac. Development and testing were carried out on an Apple Silicon MacBook Pro.
- A macOS version compatible with the build tools. The app’s declared minimum runtime is macOS 13.
- Xcode or Apple’s Command Line Tools with Swift 5.9 or newer and a compatible macOS SDK.
- A TV exposing a DLNA `MediaRenderer` with an `AVTransport:1` service.
- A network connection that lets the Mac and TV reach one another.
- Screen-recording permission for StreamMate and, when macOS requests it, local-network access.

The Swift package uses Apple frameworks without additional package dependencies. A normal build targets the architecture of the Mac that builds it.

## Build and install

Download or clone this repository, then open Terminal in its root folder.

If you need Apple’s Command Line Tools, run the following command and complete the installer. [Apple’s installation instructions](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)

```sh
xcode-select --install
```

Check the compiler and build the app.

```sh
swift --version
bash app/build.sh
```

The script builds a release executable, packages it with the icon as `app/StreamMate.app`, signs it locally and opens it.

To use it from Applications, quit the app that just opened. From the repository root, run the following commands, then approve permissions for the Applications copy.

```sh
ditto app/StreamMate.app /Applications/StreamMate.app
open /Applications/StreamMate.app
```

The build script uses an available code-signing identity when possible. Its fallback is ad-hoc signing, which also resets StreamMate’s screen-recording permission. The script performs local packaging and signing only. Distribution signing and notarization require a separate release process.

## Connect and cast

1. Turn on the TV and follow its instructions to make its sharing network available.
2. Connect the Mac to a network that can reach the TV. In the tested hotel setup, this meant joining the TV’s own Wi-Fi network, shown as `[LG] webOS TV UK760H0SD`. That network may provide only local connectivity.
3. Open StreamMate from Applications.
4. Enable StreamMate under **System Settings → Privacy & Security → Screen & System Audio Recording**. Older macOS versions may call this **Screen Recording**. Quit and reopen StreamMate after granting permission. [Apple’s permission guide](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac)
5. Enter the TV’s IPv4 address and click **Find TV**. The default, `192.168.49.1`, comes from the tested hotel setup. Use the address shown by your TV or its network information for a different setup.
6. Select a display or window under **What to cast**. Click **Refresh** if a newly opened window is missing.
7. Start with **720p** and **4 Mbps**. Enable **Send the Mac’s sound to the TV** if wanted.
8. Click **Start casting** and allow time for the TV to begin playback.
9. Click **Stop casting** to finish. Stop the cast before changing its source or quality.

The app opens a local HTTP stream on the Mac’s TCP port `8765`. If macOS asks about incoming connections, allow StreamMate so the TV can fetch the stream.

## Expected performance

In the tested setup, the screen-to-TV delay was approximately 15–20 seconds initially and about 13 seconds at 720p / 4 Mbps. These are observations from one setup, and latency can vary with content, network conditions and TV buffering.

The delay makes the current app best suited to viewing where several seconds of lag are acceptable. Audio and video were reported to be in sync during the original testing.

A VideoToolbox low-latency encoding experiment produced jumpy playback on this TV and was rolled back. The current source uses the earlier encoder configuration.

## Troubleshooting

### Screen-recording permission keeps asking

Rebuilding or switching between app copies can leave a permission entry that does not match the executable.

Quit StreamMate, then reset its screen-recording approval.

```sh
tccutil reset ScreenCapture com.streammate.app
```

Reopen `/Applications/StreamMate.app`. In **Screen & System Audio Recording**, enable StreamMate again. If it is missing, use **+** to add the Applications copy. Quit and reopen it after approval. Reopen System Settings if its list still shows the previous state.

### Find TV fails

Check that the TV is awake, the Mac is on the intended network and the address is correct. Hotel network isolation can prevent the TV from reaching the Mac’s stream even when both devices have network access.

The tested LG changed its DLNA service port between sessions. StreamMate tries discovery and previously found endpoints. For `192.168.49.1`, when the Mac has a `192.168.49.x` address, it also checks ports 1000–2000 for a renderer description.

If you know the current DLNA description port, enter the address as `IP:port`. For example, `192.168.49.1:1094` worked during one test. That port is an example and can change. Other addresses use discovery or the explicit port.

### Playback is delayed, jumpy or silent

- Stop casting and retry at 720p / 4 Mbps.
- Leave stream-sample saving off during normal use.
- Check the app’s log for connection failures or a message that the TV is falling behind.
- For audio, enable the sound option before starting and check the TV’s volume.
- If a particular app’s content appears blank, test with an ordinary desktop window to isolate whether the issue is specific to that content.

### Save a sample for diagnosis

Enable **Save a 20-second stream sample to Downloads (for troubleshooting)** before starting a cast. The file is written to `~/Downloads/streammate_sample.ts`.

Despite the checkbox wording, the current implementation stops after roughly 20 MB, so the recording’s duration depends on bitrate. Starting another sample overwrites that file.

A sample contains the captured screen and any enabled system audio. The live stream uses unauthenticated, unencrypted HTTP, and other devices able to reach the Mac’s listening port can request it while casting. Choose the capture source and network accordingly.

## How it works

```text
Mac display or window + optional system audio
    → ScreenCaptureKit capture
    → H.264 video + AAC audio encoding
    → MPEG transport stream
    → Local HTTP server
    → TV playback through DLNA / UPnP AVTransport
```

The TV fetches the stream from the Mac after StreamMate sends the playback URL. The app implements this DLNA path using ScreenCaptureKit, VideoToolbox, AVFoundation and Network.framework.

The repository also includes `streammate_dlna_test.py` and two test videos for checking playback separately from screen capture. That script requires Python 3 and accepts a TV IP address followed by its current description port. Running it starts test playback on the selected TV.

If you try another TV, a compatibility report should include its exact model, macOS version, resolution and bitrate, whether audio works, observed delay and relevant log messages.
