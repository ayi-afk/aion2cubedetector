# Cube Watch backend

One executable (`cubewatch-server.exe` / Linux `cubewatch-server`, written in
V; web pages, map image and SQLite compiled in). Cube Watch clients tell it
over a websocket where their characters are and what happens to the things it
tracks (cubes, and whatever else the admin names); browsers get a live map.

```
cubewatch-server --port 8081 --password MapPassword --password-admin AdminPassword --client-key SharedKey
```

| flag | description |
|---|---|
| `--port`, `-p` | HTTP / websocket port (default 8081) |
| `--host` | listen address (default `0.0.0.0`) |
| `--password` | password for the map page (or `CW_PASSWORD`); empty = no login |
| `--password-admin` | password for `/admin` (or `CW_PASSWORD_ADMIN`); empty = `/admin` only from localhost |
| `--client-key` | key Cube Watch clients must send - `REMOTE_KEY` in their `.env` (or `CW_CLIENT_KEY`); empty = any client may report |
| `--db` | SQLite file (default `cubewatch.db` next to the executable, created automatically) |
| `--heap-mb` | memory set aside at start so the garbage collector runs rarely (default 128) |

Everything is on the one port:

- `http://<host>:8081/` - the map (page, map image and its data over the websocket `/ws/view`).
- `http://<host>:8081/admin` - the admin panel.
- `ws://<host>:8081/ws/client` - where Cube Watch clients connect.

5 wrong passwords from one IP block that IP for a minute. Without HTTPS the
passwords travel in plain text - put a reverse proxy with TLS in front when
the server is on the internet.

### Behind nginx (HTTPS)

Run the backend on the same machine with `--host 127.0.0.1`, so that it is
only reachable through the proxy, and pass everything on - websockets too:

```nginx
server {
    listen 443 ssl;
    server_name cube.example.org;
    # ssl_certificate / ssl_certificate_key ... (e.g. from certbot)

    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_read_timeout 120s;
        client_max_body_size 512m;   # database import in the admin panel
    }
}
server {
    listen 80;
    server_name cube.example.org;
    return 301 https://$host$request_uri;
}
```

- The browser pages work as they are (they use `wss://` on an HTTPS page).
- Cube Watch: `REMOTE_ADDR=cube.example.org` (or `wss://cube.example.org`)
  in its `.env`, then build it again - the address is fixed in the exe. A
  host name alone means TLS on port 443; `host:port` is a plain websocket
  straight to the backend. Port 80 does not work once it only redirects.
- `X-Forwarded-For` is what the login limiter counts wrong passwords by,
  and a request that came through the proxy never counts as "from
  localhost", so `/admin` needs `--password-admin` there.
- To check from any PC without reporting anything:
  `v run tools/fakeclient --probe --addr cube.example.org` says whether the
  backend answers, or why not.

## The map

- Map and game server selectors. What is at a spot is kept per game server;
  pick one ("Lumiel (2304)") and the map, the lists and the statistics show
  only the spots something was seen at on that game server, or "All game
  servers" for every spot (the ones of an imported history are only there:
  it does not say which game server they were on). Every game server has a
  color: the outer ring of its spots, its players' names under "All game
  servers", and the "Game servers" list on the left (what is there now /
  spots known on this map; click one to pick it, again for all). The names are compiled
  in (`assets/servers.json`, the official list of all regions) and
  refreshed from the official site once a day; an id that list does not
  have shows as "Server 3304" until the admin names it. "Not known yet" is
  the bucket of clients that have not learned their game server (see "Who
  is who" below).
- A map without an image (the Abyss, a cave, any new map id) is a map of
  its own, drawn on a grid: nothing from it is ever put on another map's
  image.
- Spots: solid with a glow while something is there; faint while empty (the
  "Empty spots" slider, 20 % by default) with a countdown to the expected
  respawn. Hover for details: when it spawned, who took it last and when,
  when the next one is expected, how often it was seen and taken.
- Players: portrait (from the official site), class badge, name. Hover for
  the profile: combat power, item level, weapon, Daevanion boards, god
  stats, stigmas - read from the official AION 2 web API as soon as the
  character connects (a copy younger than 30 minutes is used at once) and
  again every 30 minutes, kept in memory and in the database. Click a
  player to keep the card open; it has a link to the character's page on
  shugo.gg (also the arrow in the players list). The API has no class
  icons; the badge is the class's initial in its color.
- Every spot ever seen is on the map with how often something was detected
  there, how often it was taken, the average time until it is taken and the
  typical respawn. The "Statistics" box sums that up per kind for the
  selected game server (last 24 hours and all time) and lists who took the
  most in the last 7 days.
- Left side: filters by group and kind, the game servers, the spots and the
  players online. The spot list has one line per spot (dot, place and one
  number) and a menu for what it is ordered by: most detected, most taken,
  here now, next up, average time until taken, typical respawn. Click a
  spot to jump there; while the mouse is on a spot - in the list or on the
  map - a growing ring marks it on the map.
- Wheel / double-click / buttons to zoom, drag to move.
- The faint "build 2026-10-13 1405" in the bottom right corner is when the
  running backend was compiled (shown in the viewer's local time).

### When will it respawn?

Cube Watch reports when the game server created each thing it sees (that
time is in the game's own spawn message) and when it was opened or destroyed.
The delay between "taken" and the creation of the next one at the same spot
is a respawn delay. The expected respawn of an empty spot is the time it was
taken plus the median delay seen at that spot, or - while the spot has none
- the median over all spots of that kind (needs 3). The admin can set a
fixed delay per kind instead. Until something was seen taken and spawning
again there is no estimate.

### Who is who

- The game tells a client its character's name and game server only when
  the character enters a zone. A client that does not know its name yet is
  shown as "Unknown-xxxx". One that knows the name but not the game server
  is looked up by name in every region of the official API (of several
  characters with that name, the one on the game server most other players
  are on wins, else the highest level) and put on that server.
- In shared zones the game puts a character on a game server of their own
  (in the Abyss a character of Lumiel, 2304, reports 3304). Such an id is
  not on the official list, so the character is looked up by name in the
  region the id belongs to (its second digit), preferring the server with
  the same last two digits. The card then says "Lumiel (2304) - now on
  Server 3304", and the shugo.gg link goes to the home server.
- Every Cube Watch installation has a random id (made on its first run,
  kept in its settings). Characters played from the same installation are
  shown as belonging together ("also ..."); viewers only see the first six
  characters of the id.

## Admin panel

Four tabs: **Players**, **Tracked things**, **Maps**, **Server & database**.

- **Online now** (Players) - the connected clients: character, the map id
  the game gave it, player tag, game server. "Is on map": the game only
  gives a map a number, so when you know where a character is, type the
  map's name next to it (known ones are suggested) and press Enter - the
  map id that client reports gets the name. A name that exists adds the id
  to that map, a new name makes a new map.
  "What is around" asks a client for everything it sees, nearest first,
  tracked or not: stand next to the thing in the game, press it, name the
  first row and "Track" - it becomes a kind.
- **All characters** (Players) - every character a Cube Watch ever reported
  with, online or not, grouped by installation (one player's characters
  together), with when each was last seen and a link to shugo.gg.
- **Groups** - map filters with a color (Cubes, Gathering, ...).
- **Kinds** - the template ids clients report, with name, group and an
  optional fixed respawn time. Connected clients are told at once; they
  report only these kinds and show the names in their Objects tab. To track
  something new, take its ID from the Objects tab of Cube Watch.
- **Spots** - label, hide or delete single spots; state and history counters
  per game server.
- **Maps** - "Asmodian lands" is built in (it has an image; its map ids and,
  folded away, its calibration with a two-point calculator can be
  changed). Every other map is the admin's: a name and its map ids - add,
  rename, change the ids, delete. Map ids something was reported from that
  have no name yet are listed as "not named".
- **Game servers** - the ids something was reported from, with their name
  from the official list; one without a name can be named here.
- **Database** - export a consistent copy, import and merge another backend's
  database (same groups / kinds / spots / history are recognised, so
  importing twice changes nothing), and import the `data\cubes_*.csv`
  history files of Cube Watch, so the places known before there was a
  backend are on the map (counted as detections; they say nothing about
  what is there now).

## Maps

Map images are compiled in; `assets/maps.json` lists them (one so far).
Maps without an image are kept in the database and managed in the admin
panel; a new database starts with the two known by id (Abyss = 20, Caro
Cave = 600001).

```json
{ "key": "asmodians", "name": "Asmodian lands", "image": "map_asmodians.jpg",
  "width": 4428, "height": 4652, "map_ids": [1110], "default": true,
  "sx": 0.0083032, "sy": 0.0083032, "ox": 2370.8, "oy": 2223.9 }
```

A pixel is `px = ox + sx * world_x`, `py = oy + sy * world_y` (image north
is world -Y, east is world +X). `map_ids` are the ids the game sends when it
places a character on the map; they all share the image and spots are stored
under the first one. The `default` map also takes reports whose map id is not
known (a client started in the middle of a session knows it only after the
next zone change). Map ids and calibration can be changed in the admin panel
without a rebuild (kept in the database).

The Asmodian map was calibrated from two in-game positions (Neglected
Crematorium and the Steel Hammer Mercenary camp, about 335,000 units apart)
and checked against 84 known cube positions, which all land on land. The
image is stitched from several screenshots, so expect it to be off by a few
metres here and there; refine it in the admin panel if needed.

To add a map: put the image into `assets/`, add an entry to `maps.json`, add
a line to `map_image()` in `maps.v`, rebuild.

## Many clients

Every websocket (client or browser) has its own reader thread, its own queue
of outgoing messages and its own writer thread; sending only puts text into
queues, so a slow or dead connection never holds the others back - it is
dropped when its queue fills up (512 messages) or when it is silent for 75 s
(clients and pages ping every 20 - 25 s). The state lives in memory; SQLite
is written by a background thread every 2 s in one transaction.

Clients talk in a short comma separated text format (`wire/wire.v`), every
message sealed with ChaCha20-Poly1305 (`wire/seal.v`; a few microseconds per
message) and sent as a binary frame. The key is one that both programs
carry: it is put together at start from numbers spread over the `wire`
package, so it is not in the executables as a piece of data - enough to
keep eyes and ready-made tools off the traffic and to drop anything that
was not made by a Cube Watch, but who takes the program apart will find it.
(Change the `mix_...` numbers and the first number in `seal.v` to have a
key of your own; client and backend must then be built from the same
source. A Cube Watch from before the encryption is told to update.) The
`--client-key` travels inside the sealed hello. Position updates go to the browsers in batches of plain lines twice a second,
because that is the busy path. Measured on a desktop PC with the optimized
Windows build: 600 clients each reporting a position every second (far more
than real clients do - they report on change, at most once a second, and a
heartbeat every 10 s) took about a third of one CPU core and 220 MB, with
HTTP answered in a few milliseconds.

## What is stored (SQLite)

| table | contents |
|---|---|
| `groups`, `kinds` | the admin's configuration (a new database starts with the known kinds: Cube 1301199, Odyle 1500062; a kind added to that list later is added once to an existing database) |
| `spots` | one row per place (map, kind, position rounded to a metre), label, hidden |
| `events` | history: a new one seen (with its creation time), taken (by whom), gone - per game server; `noted` = imported history |
| `profiles` | one JSON document per character |
| `owners` | which characters were played from which installation, and when each was last seen |
| `meta` | the admin's maps (`map_names`: map id = name), map ids and calibration of the built-in map, game server names (last official list, the admin's own) |

What is at each spot right now and all counters are rebuilt from `events` at
start. Players' positions are only in memory.

## Building

Requires V (tested with 0.5.0) and gcc from MSYS2 UCRT64. Once:
`v run %VROOT%\vlib\db\sqlite\install_thirdparty_sqlite.vsh`. Then
`server\build.bat` -> `server\cubewatch-server.exe` (static, depends only on
Windows system DLLs).

`server\build.bat --linux` (or `server\build_linux.bat`; run on Windows,
needs **zig** in PATH: `winget install zig.zig`) produces a fully static
Linux x86-64 binary:
`server\build\linux\cubewatch-server` (musl, no dependencies).

```
scp server/build/linux/cubewatch-server host:~/
./cubewatch-server --port 8081 --password ... --password-admin ... --client-key ...
```

Three things in the build scripts are there for a reason:

- `-fno-lto`: with gcc's link-time optimization (V's `-prod` default) the
  program crashes at start.
- `x.json2` instead of `json` for everything the server writes: the
  cJSON-based `json.encode` crashes on nested structs in optimized builds.
- its own `VCACHE`: Cube Watch is built with V's bundled tcc and the two
  compilers cannot share cached C objects.

To work on the pages without rebuilding: `set CW_WEB_DIR=server\web` - they
are then read from disk.

### Trying it without the game

`v run tools/fakeclient --addr 127.0.0.1:8081 --name Tester --server 2304`
plays a client: a character walks around a cube that is seen, opened and
respawns. `--clients 300 --server 0` connects that many walking clients for a
load test.

## Layout

- `main.v` - flags, pages, login, the admin API.
- `httpd.v` - the small HTTP server (a thread per connection; a websocket
  upgrade keeps its thread).
- `hub.v` - everything in memory, websocket sessions, sending, the
  background threads.
- `world/` - spots, states, respawn estimates (unit tested, no I/O).
- `store.v` - SQLite; `maps.v` - built-in maps; `profiles.v` - the official API.
- `web/` - the map and admin pages; `assets/` - map images, `maps.json`
  and `servers.json` (the game servers known at build time).
