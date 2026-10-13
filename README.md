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

Changing zone or entering an instance gives your character a new entity
id. Cube Watch picks it up as soon as the game connects to the new zone's
server. As a fallback, when your position is older than 15 s it also lets
another character take over (it keeps following yours until one shows up)
and keeps the last position on screen meanwhile; "Re-detect player" forgets
your character right away.

The game server does not send your position while you simply walk or run.
It arrives when something happens to your character: landing, a jump or
glide, entering a zone, any effect put on you (your own buffs and dash
skills, effects from other players and monsters) and every skill a monster
aims at you. Between those the last known position is shown.

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

Markers move when the game reports your position (see "Compass").

### Overlay extras (last row)

- "XYZ": your position in small text centred just above the minimap,
  colored like the freshness ring (green / yellow / red). The slider next
  to it sets its opacity (default 60 %); the drop-down sets the axis order
  (also for the compass corner) - the one marked with a star reads like the
  map: east-west axis, north-south axis, height.
- "Ring" and its slider: show / hide the freshness ring around your arrow
  and set its radius (rightmost = the default and largest, leftmost = 1 px).
- "Auto-clear" slider: cubes older than this leave the list (default
  20 min, far left = off). "Clear list" (or "Clear cubes" in the tray menu)
  empties it at once, e.g. for a cube stuck under the ground.
- "History on map": a small dot (70 % opacity) wherever cubes appeared
  before - green when they were mostly taken by you, red when mostly by
  others, grey when nobody was seen taking them.

## Map overlay 2 (the large map)

"Map overlay 2" (last row, or the tray menu) is a second transparent,
click-through window, meant for the game's large see-through map (the one
with the "Map Opacity" slider), which keeps your character in its middle.
It shows:

- the cubes Cube Watch sees itself, in their list colors with the distance,
  and a red X where one was just taken - as on the minimap overlay;
- what the backend knows to be there right now on your game server: a full
  dot with a white rim, in the color of its group;
- "History": every place something was seen at before - small faint dots,
  with the time until the next one ("12m", "due") where the backend expects
  one. Without a backend the places of this PC's own history files;
- "Players": the other Cube Watch players on your game server and map, with
  their names.

"Unlock" to place it: drag it over the game's map (edges resize) until the
cross sits on your arrow, then set the zoom with the mouse wheel (or the
"Zoom" list: world units across the overlay) until the marks sit on their
places of the map; right-click or "Lock" when done. The game's map can be
zoomed too - the overlay's zoom has to follow it. "Opacity" and "Reset" work
as for the first overlay. The backend only sends this while the overlay is
on (the other players every 2 seconds), and an older backend sends nothing:
then only your own cubes are drawn.

## Cube history

Every cube is written to `data\cubes_<8 random letters>.csv` next to
`cube_watch.exe` (one file per session) once its fate is known: taken,
destroyed, cleared or when the app exits. Columns:

| Column | Meaning |
|--------|---------|
| `appeared` | local date and time it was first seen |
| `spawned_in_range` | 1 = it appeared already inside view range (it spawned while we were there), 0 = we came into range of it; estimated from the distance at first sight (closer than 12,000 = 1), empty if our position was unknown |
| `x`, `y`, `z` | position |
| `taken_by_us` | 1 = we opened it, 0 = another player, empty = unknown (vanished / cleared) |
| `distance` | flat distance at first sight, to re-check `spawned_in_range` later |
| `map` | id of the map you were on, empty if unknown (see "Objects tab"); missing in files of older versions |

All `data\cubes_*.csv` files are loaded at start. Tick "History" (next to
"Compass range") to see them instead of the cube list. Replays do not write
history.

## Objects tab

The "Cubes" / "Objects" buttons above the list switch what it shows.
"Objects" lists every object and NPC the game server reports in view
(cubes included), nearest first:

| Column | Meaning |
|--------|---------|
| Name | the name you gave this ID ("Cube" is built in); empty until named |
| Type | Object (cubes, gatherables, chests, ...) or NPC (monsters and other NPCs) |
| ID | the template: what kind of thing it is - the same for every one of its sort |
| Entity | this one's id on the current server (changes every time) |
| Distance / Height | flat distance and height relative to you |
| X, Y, Z | position; NPCs are followed while they walk |
| Info | NPC: HP when it came into view; object: how long ago the server created it |
| Flags | flag bytes of its spawn message whose meaning is not known yet |
| Seen | when it came into view |

Double-click a row (or select it and press F2), type a name and press
Enter: the name belongs to the ID, so every row of that sort gets it, now
and in later sessions. An empty name removes it. To find out what an ID is,
stand next to the thing in the game - it is the first row.

"Clear list" and "Copy XYZ" work on the tab that is shown. The list empties
by itself when the game connects to another server (zone / instance
change). Other players are not listed.

Two files next to `cube_watch.exe` keep what was learned:

- `data\names.csv` - `type,template,name`: your names. You can edit it (or
  share it) while Cube Watch is closed.
- `data\db.csv` - where every ID was seen:
  `map,type,template,name,x,y,z,flags,max_hp,first_seen,last_seen,times_seen`.
  One row per place: on the same map, objects within 200 units and NPCs
  within 2,000 units of an earlier sighting count as the same place
  (`times_seen` goes up).
  Written every 30 s and on exit; the name column is filled in from
  `names.csv`. Keep it closed in Excel while Cube Watch runs, or it cannot
  be written. Replays do not add places.

### Map id

The map id is the number the server sends when it places your character
on a map (zone or instance change); it is shown after your position
("| map 1110") and saved with every row of `db.csv` and of the cube
history. It stays empty until the first such change after Cube Watch was
started, because the server does not repeat it.

Nothing from another map is laid over the one you are on:

- a cube left behind on another map turns grey with the state "other map"
  and loses its compass arrow and overlay marker (it comes back when you
  return and the server shows it again);
- "History on map" draws only the cubes recorded on the current map.

Only what is known to be elsewhere is hidden: history rows without a map
id (written by older versions, or before the first map change of a
session) are still drawn everywhere, and so is everything while the
current map is not known yet.

## Backend

Cube Watch can report to a backend (`server/`, see `server/README.md`) that
shows a live map in the browser: where the connected characters are, where
cubes (and other things its admin named) are right now, who took them last
and when the next one is expected.

- The backend's address is fixed in the exe at build time: `REMOTE_ADDR=`
  in `.env` (and `REMOTE_KEY=` when the backend has a `--client-key`); see
  `.env.example`. `host:port` is the backend itself; a host name alone (or
  `wss://host`) is a backend behind HTTPS - a reverse proxy like nginx -
  and is reached with TLS on port 443. Without `REMOTE_ADDR` Cube Watch
  connects nowhere.
- The connection is made in the background. When the backend cannot be
  reached Cube Watch simply works as before and tries again every 20 - 30
  seconds. The player line shows `hub online` / `hub offline`, and the
  status line says once why it is offline.
- With TLS the proxy's certificate is not checked against a list of
  authorities (Cube Watch carries none); the messages inside are sealed
  with the key only Cube Watch and the backend have.
- It sends: a random id of this installation (made on the first run, kept
  in the settings; the backend uses it to show that several characters
  belong to one player), your character's name and game server (learned
  when the character enters a zone, remembered in the settings - until then
  you are on the map as "Unknown-xxxx" and the player line says so), your
  last known position (when it changes, at most once a second, and every 10
  seconds),
  and for the kinds the backend tracks - when one comes into view (with the
  time the game server created it), when a player opens it (and whether it
  was you) and when it is destroyed. Nothing else leaves the PC; in
  particular not the account string of the login message.
- Everything Cube Watch and the backend say to each other is encrypted
  (ChaCha20-Poly1305 with a key both programs carry, see `wire/seal.v`),
  so client and backend have to be built from the same source.
- The backend sends the kinds it tracks with their names; they are shown in
  the Objects tab for IDs you have not named yourself. Its admin can also
  ask what is around you: Cube Watch then answers with the objects and NPCs
  in view (type, ID, position, distance), so that new things can be named
  there.
- Replays are not reported, unless started with `--replay-remote`.

## Save packets

Cube Watch always keeps the last 60 seconds of game server packets in
memory (only frames with data from the game server port; nothing else on
the adapter, at most 64 MB). "Save packets" (first row under the list, or
the tray menu) writes them to `data\packets_<date>_<time>.pcap` next to
`cube_watch.exe` and opens that folder with the file selected, ready to be
sent. Click it right after something the app did not recognize (e.g. a new
kind of cube) and analyze the file later in Wireshark or with the replay
tools below. The buffer survives Stop / Start and is cleared when another
adapter type is selected.

Each packet is saved whole and unchanged (Ethernet / IP / TCP headers and
all data), so the file holds everything the server sent in that minute -
chat included - plus the PC's local IP and network card address. Send it
only to people you trust. Packets from the game client are not captured
(they are encrypted).

## Replay

- `cube_watch.exe --replay capture.pcapng` plays a saved capture into the
  window in real time (does not touch your settings).
- `tools\replay\replay.exe capture.pcapng` prints the decoded events in the
  console (`v -o tools\replay\replay.exe tools\replay` to build it).

### Finding unknown objects

`tools\replay\replay.exe --analyze data\packets_....pcap` is for objects
Cube Watch does not show yet (e.g. cubes of another world, other items):

- every spawned template (`34 36`) with the number of spawns, how many of
  its objects a player opened and how many were destroyed, and the distance
  from you to the nearest one. Cubes get opened and destroyed, so their
  template is listed first; the known cube is marked.
- every opcode with its count and message size.
- every message that carries a position within `--near` units (default
  1,000) of you, as opcode and byte offset - this also finds objects sent
  with another opcode. Without a player position in the capture pass yours
  with `--at x,y,z`.

The spawn message is sent when the object comes into view (about 15,000
units away), so save the packets within a minute of that - e.g. right after
arriving next to the object, or walk out of range and back.

## Protocol notes

Server -> client messages are plain (LZ4 bundles aside); client -> server
messages are encrypted, so the player's own position comes only from the
server, and only when something happens to the character (effects, skills
aimed at it, landing) - never for plain walking.

A message is a size varint followed by `size - 4` bytes (2-byte opcode and
data), whatever the width of the varint. A bundle is a message with opcode
`ff ff`: decoded size u32, then an LZ4 block of more messages.

| Opcode | Meaning | Layout after opcode |
|--------|---------|---------------------|
| `15 36` | first message of a game server connection | 2 bytes, two clock values, 3 bytes, account string, game server id as a string (e.g. `2304`), ... |
| `21 36` | own character is placed on a map (once per zone / instance change) | u32, map id u32, u32, u32, x y z, heading f32, ... |
| `33 36` | own character enters a zone | id, three small numbers, name (length byte first), ... (stats) |
| `34 36` | object spawn (cube template `0x0013DACF`) | id, 2 bytes, template u32, x y z |
| `35 36` | object removed (`04` = destroyed, `01` = out of view) | id, reason |
| `38 36` | player starts opening object | object id, player id |
| `3a 36` | player finished opening object | object id, player id, ... |
| `1e 56` | loot from an opened object | ..., object id u32, object xyz, drop xyz |
| `2a 38` | status effect put on a target (buff, debuff, landing, dash, ...) | caster id, 1 byte, mask, effect number (varint), effect id u32, duration u32, u32, time u64, target id, level, skill u32 if mask & 2, flag, target x y z |
| `2b 38` | status effect refreshed | same without the byte after the caster id; x y z is the target's current position only with flag `02` |
| `02 38` / `09 38` | skill used on a target / cast started | caster id, 1 byte, skill u32, sequence, flag, target id, heading f32, target x y z if flag is `02`, ... |
| `1a 37` | entity position (used for the local player id) | id, 2 bytes, x y z |
| `1b 37` / `1c 37` | entity starts moving / keeps moving (about once a second) | id, 1 byte, x y z, ... |
| `41 36` | NPC spawn | id, 3 flag bytes, template u32, 2 flag bytes, x y z, heading f32, 2 bytes, `01`, HP varint, max HP varint, ... |
| `42 36` | NPC removed (`01` = out of view, `03` seen when one died) | id, 1 byte, reason |
| `00 36` | server clock, 20 times a second | ms u64 |

After the position an object spawn (`34 36`) continues with 4 zero bytes,
heading f32, 3 state bytes and the server clock value (ms u64) of when the
object was created.

The local player is the entity that puts an effect without a skill on
itself (monsters' own effects come from a skill) or the one named by
`33 36`; its position is then taken from every `2a 38` / `2b 38` /
`02 38` / `09 38` that has it as the target.

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
v test objdb
v test wire
v run tools\envgen build_remote.v
v run tools\stamp build_stamp.v
v -d no_backtrace -subsystem windows -o cube_watch.exe .
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
  decoding, pcap reading / writing and the last-minute frame buffer (unit
  tested, no Windows dependencies).
- `objdb/` - template names and seen places behind the Objects tab
  (`names.csv` / `db.csv`; unit tested, no Windows dependencies).
- `objects.v` - the Objects tab.
- `wire/` - the messages Cube Watch and the backend exchange and the small
  websocket client codec (unit tested).
- `remote/` - the background connection to the backend; `backend.v` - what
  the app reports through it.
- `server/` - the backend (its own executable, see `server/README.md`).
- `tools/envgen` - writes `build_remote.v` (backend address) from `.env`;
  `tools/fakeclient` - plays a client against a backend.
- `capture.v` - Npcap loading, adapter selection, capture thread.
- `overlay.v`, `overlay2.v` - the minimap overlay and the one for the large map.
- `app.v`, `icon.v`, `win32.v` - Win32 GUI and tray.
- `sound.v`, `settings.v` - alerts and persisted preferences.
- `trial.v`, `trial_pins.v`, `tools/stamp/` - 7-day trial check, pinned
  root certificates for the time sources, build stamp generator.

## Notes

- Problems are logged to `%APPDATA%\CubeWatch\log.txt`: V panics and native
  crashes with the module (DLL) they happened in. Send that file along with
  a bug report.

- The title bar shows the privilege check, e.g.
  `Cube Watch - standard user | Npcap: all users`. If Npcap was installed
  with "Restrict Npcap driver's access to Administrators only" (registry
  `HKLM\SYSTEM\CurrentControlSet\Services\npcap\Parameters\AdminOnly`), or
  the adapter cannot be opened, a "Run as administrator" button restarts
  Cube Watch elevated through the UAC prompt.
- Supported adapter link types: Ethernet, loopback/NULL and raw IP (some
  VPN / tunnel adapters).
