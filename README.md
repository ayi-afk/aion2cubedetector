# Cube Watch

Windows tray app (V port of `cube_watch.py`) that watches AION 2 server
traffic through Npcap and alerts when a cube spawns nearby.

## Features

- Lists every detected cube with X / Y / Z, time seen, planar distance and
  height relative to your character (newest first). Rows update while you move.
- Decodes your own character position from the same packets, auto-detects
  your entity id, and shows how far away the newest cube is, whether you are
  getting closer, and the dX / dY offset.
- Alert sound: Windows "Exclamation" sound, the original beep melody, a
  custom `.wav` / `.mp3` / `.wma` file, or off. "Test" plays it.
- Opacity slider (20-100 %) and "Always on top" so it can sit over the game.
- Runs in the background: closing the window hides it to the tray (tray
  balloon on new cubes while hidden). Tray right-click: Show / Always on
  top / Exit. Only one instance runs at a time.
- If Npcap is missing, an "Install Npcap" button opens
  https://npcap.com/#download; the app picks Npcap up automatically once
  it is installed.
- Settings are stored in `%APPDATA%\CubeWatch\settings.json`.

Start with `cube_watch.exe --tray` to launch straight into the tray.

Dark mode follows the Windows app theme until you tick "Dark mode" (window
or tray menu); after that your choice is kept.

## Compass

The compass shows an arrow for each of the 3 nearest cubes that can still
be collected, each in the cube's own color (the list rows use the same
color); the nearest has the longest arrow. Below the dial a legend lists
each arrow: color square, cube number, direction (N / NE / E / ...),
distance and a small up/down triangle with the height difference. A `!`
means another player is opening that cube. Arrows fade when your last known
position is older than 10 s.

Entering an instance gives your character a new entity id. When your
position is older than 15 s, Cube Watch detects your character again
automatically (every 15 s until a fresh position arrives) and keeps the
last position on screen meanwhile; "Re-detect player" does it right away.

Position freshness (square next to your X / Y on the compass, ring around
your arrow on the map overlay): green = updated in the last 5 s, yellow =
up to 15 s, red = older. While re-detecting, the last X / Y / Z stay on
screen in yellow until a new position arrives.

Cubes farther away than "Compass range" (next to "Copy XYZ": 10,000 /
20,000 / 30,000 / 50,000 / 100,000 units or Unlimited, default 30,000) get
no arrow; the legend counts them as "too far" and they stay in the list.
Cubes are announced from roughly 15,000 units away.

Your X / Y / Z are shown in the top-left corner of the compass with the age
of the fix; the square next to them turns green for a second whenever a new
position arrives.

Opened or vanished cubes turn grey and are removed from the list 20 s later.

"Compact view" (button next to "Re-detect player", or the tray menu)
shrinks the window to your position, the compass and a "Standard view"
button - handy with "Always on top" and lower opacity over the game. Each
view remembers its own window size.

Map north is world -Y and east is world +X (measured in game by walking up
and right on the minimap), so the compass matches the minimap out of the
box. If it ever does not (e.g. a zone with a rotated map), click
"Calibrate north" (also in the tray menu), walk straight up on the minimap
for a few seconds and stop. The game reports your new position when you
stop, and that walk direction becomes north (snapped to the nearest world
axis when within 20 degrees). "Rotate" turns the compass a quarter turn
counter-clockwise as a quick manual fix. East is always 90 degrees clockwise
from north (Unreal's world is left-handed), so no mirroring option exists.

Opened or vanished cubes turn grey and are removed from the list 20 s later.

"Compact view" (button next to "Re-detect player", or the tray menu)
shrinks the window to your position, the compass and a "Standard view"
button - handy with "Always on top" and lower opacity over the game. Each
view remembers its own window size.

## Map overlay

"Map overlay" (bottom row, or the tray menu) lays a transparent,
click-through window over the game's minimap and marks each cube in its
list color (nearest is larger; cubes beyond the minimap edge get an arrow
on the rim; cubes outside "Compass range" are left out). Each marker has a
small label: an up / down triangle when the cube is above / below you and
the flat (north-south / east-west) distance, e.g. "2.7k" - height is not
included. A bold "!" above a marker means someone is opening that cube
(warning color: another player, white: you); a red X marks a cube that was
just taken and disappears after 5 s. The game must run
in borderless / windowed mode - nothing can draw over exclusive fullscreen.

- "Game UI": your in-game Edit HUD > UI Proportion (Smaller 88 %, Small
  94 %, Medium 100 %, Large ~109 % (estimated), Larger 118 %). The default
  spot is the minimap's top-right position with outer margin "None", as a
  share of the primary screen's height, so it fits any resolution.
- "Unlock": drag the overlay onto the minimap, drag edges to resize; the
  cross marks the player arrow. Right-click it or "Lock" to make it
  click-through again. The position is kept as a share of the screen;
  "Reset" goes back to the default spot.
- "Map zoom": world units across the minimap width. To set it exactly:
  unlock, walk away from a recognizable spot and stop; a white X marks
  where you started - scroll the mouse wheel over the overlay until the X
  sits on that spot of the minimap (5 % per notch).
- "Opacity": marker transparency.

All overlay options (on/off, Game UI, zoom, opacity, position) are saved
with the other settings and restored on the next start.

Markers move when the game reports your position (on stop / landing).

## Replay

- `cube_watch.exe --replay capture.pcapng` plays a saved capture into the
  window in real time (does not touch your settings).
- `tools\replay\replay.exe capture.pcapng` prints the decoded events in the
  console (`v -o tools\replay\replay.exe tools\replay` to build it).

## Protocol notes

Server -> client messages are plain (LZ4 bundles aside); client -> server
messages are encrypted, so the player's own position comes only from the
server, and only occasionally (on stop, landing, corrections).

| Opcode | Meaning | Layout after opcode |
|--------|---------|---------------------|
| `34 36` | object spawn (cube template `0x0013DACF`) | id, 2 bytes, template u32, x y z |
| `35 36` | object removed (`04` = destroyed, `01` = out of view) | id, reason |
| `38 36` | player starts opening object | object id, player id |
| `3a 36` | player finished opening object | object id, player id, ... |
| `1e 56` | loot from an opened object | ..., object id u32, object xyz, drop xyz |
| `2a 38` / `2b 38` | local player position (self-id discriminator) | id, ..., id, `01 00`/`01 02`, x y z |
| `1a 37` | entity position (used for the local player id) | id, 2 bytes, x y z |

## Build

Requires V (tested with V 0.5.0 and its bundled tcc). No other SDK needed.

```bat
build.bat
```

`build.bat` also packs the exe into `cube_watch_<yyyy-MM-dd_HHmm>.rar`
(needs `rar` on PATH or WinRAR installed) for distribution; the exe keeps
the name `cube_watch.exe`. Close Cube Watch before building - a running
exe cannot be overwritten.

or manually:

```bat
v test proto
v run tools\stamp build_stamp.v
v -subsystem windows -o cube_watch.exe .
```

## Upload

`upload.bat` posts the newest `cube_watch_*.rar` to the Discord channel
(webhook URL in `.env` as `DISCORD_WEBHOOK=...`; `.env` is git-ignored,
keep it private) with the message
"Build new version: <date>" and the list from `fixes.txt` (one fix per
line). After a successful upload `fixes.txt` is cleared; on failure it is
kept. `upload.bat --dry-run` only shows the message.

## Trial

Each build runs for 7 days from the moment it was built. `build.bat`
(through `tools\stamp`) writes `build_stamp.v` with the build time encoded
under fresh random keys and an integrity check, so every build restarts the
trial. Do not edit or commit `build_stamp.v`; the app does not compile
without it.

At startup the app takes the current time from the `Date` header of
`www.google.com`, `www.cloudflare.com`, `www.microsoft.com` or
`www.apple.com` - never from the PC clock. The TLS connection trusts only
the root certificates pinned in `trial_pins.v` (GTS Root R1-R4 for Google /
Cloudflare, DigiCert Global Root G2 for Microsoft / Apple), not the Windows
certificate store, and checks the host name, so a proxy, an added root or a
fake time server is rejected. Plain NTP is not used (it cannot be
authenticated). Without a verified internet time it refuses to start; once
running it keeps running offline, counting on the monotonic clock (and
re-syncing every hour when possible), and closes with a message once the
trial is over. The title bar shows the days left. Logic: `trial.v`.

If a source moves to a different root CA, add that root (PEM) to
`trial_pins.v` and rebuild. The pinned roots are valid until 2036 / 2038.

## Layout

- `proto/` - TCP reassembly, frame / LZ4 bundle parsing, cube and player
  decoding (unit tested, no Windows dependencies).
- `capture.v` - Npcap loading, adapter selection, capture thread.
- `app.v`, `icon.v`, `win32.v` - Win32 GUI and tray.
- `sound.v`, `settings.v` - alerts and persisted preferences.
- `trial.v`, `trial_pins.v`, `tools/stamp/` - 7-day trial check, pinned
  root certificates for the time sources, build stamp generator.

## Notes

- The title bar shows the privilege check, e.g.
  `Cube Watch - standard user | Npcap: all users`. If Npcap was installed
  with "Restrict Npcap driver's access to Administrators only" (registry
  `HKLM\SYSTEM\CurrentControlSet\Services\npcap\Parameters\AdminOnly`), or
  the adapter cannot be opened, a "Run as administrator" button restarts
  Cube Watch elevated through the UAC prompt.
- Supported adapter link types: Ethernet, loopback/NULL and raw IP (some
  VPN / tunnel adapters).
