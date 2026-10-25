# Trail Tracker

An offline iPhone app for tracking your group on the trail with TIDRADIO TD-H9 radios.
Each radio beacons its own GPS position over APRS. The app connects to your radio over
Bluetooth, decodes everyone it hears, and puts them on a topo map that works with no cell signal.

- **Offline maps:** download USGS topo or satellite maps for an area ahead of time.
- **Private:** the app never sends anything to the internet. With "Use internet for maps" off it makes no network connections at all.
- **Add riders without setup:** anyone whose radio beacons on your frequency shows up automatically. Give them a name and color on the Riders tab.
- **Demo mode:** fake riders to try everything before the radios arrive (Radio tab).

## Installing on your iPhone (free, no developer account)

The app is built in the cloud by GitHub Actions on every push to `main`. The installable file
is published as `TrailTracker.ipa` on the [latest release](../../releases/tag/latest).

You sign it with your own free Apple ID using **AltStore**:

1. On the MacBook, install **AltServer** from [altstore.io](https://altstore.io) and run it (it lives in the menu bar).
2. Plug the iPhone into the Mac with a cable. On the phone, tap **Trust**.
3. From the AltServer menu choose **Install AltStore → your iPhone**, and sign in with your Apple ID.
4. On the iPhone: Settings → General → VPN & Device Management → trust your Apple ID.
   Also turn on Settings → Privacy & Security → **Developer Mode** (the phone restarts).
5. Download `TrailTracker.ipa` on the phone (Safari, from the latest release link above), tap Share → **AltStore**, or open AltStore → My Apps → **+** and pick the file.
6. Repeat for your friend's phone. They can use their own Apple ID or yours.

**Free installs expire after 7 days.** Refresh in AltStore (My Apps → Refresh All) with the
phone on the same Wi-Fi as the Mac running AltServer. Do it the night before the trip and
you're covered for up to a week. Refreshing needs internet, so it can't be done on the trail.

## On your Windows computer

There's also a computer version with the same map, riders, offline maps, trail lines and navigation.
It runs in Microsoft Edge (or Chrome) and installs like a normal app:

1. Open **https://bowerman2018-collab.github.io/junglemachinetrack/** in Edge.
2. Click the **Install** icon at the right end of the address bar (a little screen with a +), then **Install**.
   Trail Tracker now has its own window, a Start menu entry and a taskbar icon.
3. **Maps tab → Maps where I live:** type your town or ZIP, pick how far around it, and click **Download my area**.
   **Download all 13 trail systems** saves the Hatfield-McCoy maps the same way.
4. **Maps tab → Trail lines → Import trail map…** and pick the Hatfield-McCoy KMZ (or the .zip it came in).
5. **Radio tab → Demo riders** to try it without radios.

Once maps are saved it works with no internet. Turn off **Use internet for maps** and it makes no connections at all.
Saved maps and settings stay in Edge on that computer; nothing is uploaded.

Radio: **Bluetooth…** connects to the radio over Bluetooth (Edge/Chrome), and **COM port…** reads a radio or TNC that
Windows shows as a COM port. Like the iPhone app, it shows what the radio sends in the raw log until the H9's format is confirmed.

Code: `web/` (no build step). Checks: `node web/test/check.mjs`. Published by `.github/workflows/web.yml`.

## Radio setup (both radios)

1. **Same APRS frequency on every radio.** Pick a quiet simplex frequency instead of 144.390 so internet gateways don't pick up your beacons and post them publicly.
2. **Callsign plus a different SSID** on each radio, e.g. `KD8ABC-7` and `KD8XYZ-9`.
3. **GNSS on, Timed Beacon on**, every 30 to 60 seconds. PTT beacon off.
4. **No digipeating:** empty path, or `NOGATE` if the radio allows it.
5. **Bluetooth on** in the radio's menu, and close the ODmaster app (the radio allows one connection at a time).
6. In the app: Radio tab → **Find my radio** → tap it. After that it reconnects on its own.

Note: anyone nearby listening on that exact frequency can still hear the beacons (encryption
isn't allowed on ham bands), but nothing gets posted online.

## If the radio connects but no riders show up

TIDRADIO doesn't document what the H9 sends over Bluetooth, so the app listens to everything
and shows it on the Radio tab. Screenshot **What the radio offers** and share the **Raw data log**,
and the decoder can be adjusted to match.

## Project layout

- `Packages/APRSCore`: the APRS decoder (KISS, AX.25, text packets, plain/compressed/Mic-E positions, NMEA). Has unit tests: `swift test`.
- `App/`: the SwiftUI app (Bluetooth, maps, screens).
- `project.yml`: the Xcode project definition for [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- `.github/workflows/build.yml`: the cloud build.
- `web/`: the computer version (published to GitHub Pages by `.github/workflows/web.yml`).

Maps: USGS The National Map (public domain).
