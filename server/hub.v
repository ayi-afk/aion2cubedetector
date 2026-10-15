module main

import db.sqlite
import x.json2
import log
import math
import net.websocket
import strings
import sync
import time
import wire
import server.world

// The hub owns everything that lives in memory: the world, the profiles,
// the websocket sessions. Cube Watch clients and browsers talk to it from
// their own threads, the HTTP handlers from another one, so every access
// goes through `mu`. Changes are written to SQLite by a background thread
// every few seconds.
//
// Many clients and browsers are connected at once, so nothing waits for a
// socket: every connection (a Peer) has its own reader thread, its own
// queue of outgoing messages and its own writer thread. Sending means
// putting the text into the queues; a peer that does not keep up (queue
// full) or stops answering is dropped without holding anybody else back.

// A player who has not reported for this long is taken off the map (seconds).
const person_ttl = i64(120)
// How often collected changes are written to the database.
const flush_interval = 2 * time.second
// Positions outside this range are not game coordinates.
const max_coordinate = 10_000_000.0
// The profile worker looks for a character to refresh this often.
const profile_tick = time.second
// Messages that may wait for one peer; with more it is too slow and is dropped.
const peer_queue = 512
// Positions of players are sent to the browsers in batches this often.
const people_interval = 500 * time.millisecond
// A peer that sent nothing for this long is gone (clients and pages ping
// every 20 - 25 s).
const peer_silence = 75 * time.second
// Clients that watch the area around them (the second map overlay) are told
// about the other players this often, and about the tracked places at most
// every area_spots_seconds (when something changed).
const area_interval = 2 * time.second
const area_spots_seconds = i64(5)
// Name of a player whose client does not know its character's name yet,
// followed by a few characters that tell such players apart.
const unknown_prefix = 'Unknown-'

struct ClientSession {
mut:
	authed  bool
	server  int
	name    string
	person  string // key of the player this client is on the map as
	found   int    // game server found for the name while the client did not know it
	map     u32    // the map id the client reports, as the game sent it (0 not known yet)
	install string // id of the Cube Watch installation
	noted   string // the character (person key) written down for that installation in this session
	// What the client last said is around it (asked for by the admin).
	near    []wire.NearItem
	near_at i64
	since   i64
	last    i64
	// The client wants to be told what is around it (wire.t_watch); what
	// it was last sent the places of (game server and map, hub.area_rev) and when.
	watch    bool
	area_key string
	area_rev u64
	area_at  i64
}

// Outgoing says who gets a message.
struct Outgoing {
	viewers bool   // every browser
	clients bool   // every Cube Watch client
	viewer  string // one browser (websocket id)
	client  string // one Cube Watch client (websocket id)
	text    string
	close   bool // close that one connection afterwards
}

// Peer is one websocket connection that has said hello.
@[heap]
struct Peer {
	id     string
	viewer bool // a browser; else a Cube Watch client
mut:
	client &websocket.Client = unsafe { nil }
	out    chan string
	kick   bool // close after the next message
	// What a Cube Watch client gets is sealed (wire/seal.v); `plain` is a
	// client from before that, which is only told to update.
	sealer wire.Sealer
	plain  bool
}

@[heap]
struct Hub {
mut:
	mu            &sync.Mutex = sync.new_mutex()
	w             &world.World
	db            sqlite.DB
	maps          []MapDef
	alias         map[u32]u32 // map id -> the id spots of that map are stored under
	default_map   u32
	client_key    string
	sessions      map[string]ClientSession // websocket id -> session
	profiles      map[string]Profile
	profile_tries map[string]i64
	name_servers  map[string]int // character name -> game server found through the official API
	server_names  map[int]string // game server id -> name, from the official list
	custom_names  map[int]string // names the admin gave (ids the list does not have, or better names)
	// Characters played from the same Cube Watch installation belong to one
	// player: installation id -> person keys -> name, and back.
	owned     map[string]map[string]string
	owner_of  map[string]string
	char_seen map[string]i64 // person key -> when that character last reported
	// A character seen on a game server without a name (the Abyss, an
	// instance) is listed under its named server: person key there -> the
	// key it is listed under (merge_instances).
	home_of      map[string]string
	wss_client   &websocket.Server = unsafe { nil }
	wss_view     &websocket.Server = unsafe { nil }
	peers_mu     &sync.Mutex       = sync.new_mutex() // after `mu` when both are needed
	peers        map[string]&Peer
	dirty_people map[string]bool // new, or their profile changed: the browsers get all of them
	moved_people map[string]bool // only moved since the last batch to the browsers
	started      i64
	reports      i64 // sightings applied since start
	area_rev     u64 = 1 // goes up when a place or what is at one changed
}

fn now_unix() i64 {
	return time.now().unix()
}

fn new_hub(db sqlite.DB, client_key string) !&Hub {
	mut h := &Hub{
		w:          load_world(db)!
		db:         db
		client_key: client_key
		started:    now_unix()
	}
	h.set_maps(load_maps(db)!)
	for r in q(db, 'SELECT server,name,json FROM profiles ORDER BY fetched_at DESC LIMIT ${max_profiles}')! {
		p := json2.decode[Profile](r.vals[2]) or { continue }
		h.profiles[world.person_key(r.vals[0].int(), r.vals[1])] = p
		if r.vals[0].int() > 0 && r.vals[1].to_lower() !in h.name_servers {
			h.name_servers[r.vals[1].to_lower()] = r.vals[0].int()
		}
	}
	mut quiet := &log.Log{}
	quiet.set_level(.disabled)
	if known := json2.decode[ServersFile](servers_json) {
		for srv in known.servers {
			h.server_names[srv.id] = srv.name
		}
	}
	// what the API said last time is newer than what was compiled in
	for id, name in meta_names(db, 'server_names') {
		h.server_names[id] = name
	}
	h.custom_names = meta_names(db, 'server_names_custom')
	for r in q(db, 'SELECT install,server,name,last_seen FROM owners ORDER BY last_seen')! {
		key := world.person_key(r.vals[1].int(), r.vals[2])
		h.owner_of[key] = r.vals[0]
		h.owned[r.vals[0]][key] = r.vals[2]
		h.char_seen[key] = r.vals[3].i64()
	}
	for install in h.owned.keys() {
		h.merge_instances(install)
	}
	h.wss_client = websocket.new_server(.ip, 0, '', logger: quiet)
	h.wss_view = websocket.new_server(.ip, 0, '', logger: quiet)
	// The websocket module logs every frame at debug level by default.
	h.wss_client.on_connect(quiet_client)!
	h.wss_view.on_connect(quiet_client)!
	h.wss_client.on_message_ref(fn (mut c websocket.Client, msg &websocket.Message, ref voidptr) ! {
		mut hub := unsafe { &Hub(ref) }
		if msg.opcode == .binary_frame {
			hub.peer(mut c, false)
			text := wire.open(msg.payload, false) or {
				hub.refuse(c.id, 'not a Cube Watch message')
				return
			}
			hub.on_client_text(c.id, text)
		} else if msg.opcode == .text_frame {
			mut p := hub.peer(mut c, false)
			p.plain = true
			hub.refuse(c.id, 'this backend needs a newer Cube Watch')
		}
	}, h)
	h.wss_client.on_close_ref(fn (mut c websocket.Client, code int, reason string, ref voidptr) ! {
		mut hub := unsafe { &Hub(ref) }
		hub.drop_peer(c.id)
		hub.mu.lock()
		hub.sessions.delete(c.id)
		hub.mu.unlock()
	}, h)
	h.wss_view.on_message_ref(fn (mut c websocket.Client, msg &websocket.Message, ref voidptr) ! {
		mut hub := unsafe { &Hub(ref) }
		if msg.opcode == .text_frame {
			hub.peer(mut c, true)
			hub.on_viewer_text(c.id, msg.payload.bytestr())
		}
	}, h)
	h.wss_view.on_close_ref(fn (mut c websocket.Client, code int, reason string, ref voidptr) ! {
		mut hub := unsafe { &Hub(ref) }
		hub.drop_peer(c.id)
	}, h)
	return h
}

fn quiet_client(mut sc websocket.ServerClient) !bool {
	mut quiet := &log.Log{}
	quiet.set_level(.disabled)
	sc.client.logger = quiet
	return true
}

fn (mut h Hub) set_maps(maps []MapDef) {
	h.maps = maps
	h.alias.clear()
	h.default_map = 0
	for m in maps {
		if m.map_ids.len == 0 {
			continue
		}
		for id in m.map_ids {
			h.alias[id] = m.map_ids[0]
		}
		if m.is_default {
			h.default_map = m.map_ids[0]
		}
	}
}

// canonical_map is the id things on that map are stored under: every id of
// a built-in map becomes its first id, an unknown map the default map.
fn (h &Hub) canonical_map(id u32) u32 {
	if id == 0 {
		return h.default_map
	}
	return h.alias[id] or { id }
}

// peer returns the connection's Peer, creating it (and its writer thread)
// at its first message. Before that nothing is sent to a connection: the
// websocket handshake answer has to go out first.
fn (mut h Hub) peer(mut c websocket.Client, viewer bool) &Peer {
	h.peers_mu.lock()
	defer {
		h.peers_mu.unlock()
	}
	if p := h.peers[c.id] {
		return p
	}
	mut p := &Peer{
		id:     c.id
		viewer: viewer
		client: unsafe { c }
		out:    chan string{cap: peer_queue}
		sealer: wire.new_sealer(true)
	}
	h.peers[c.id] = p
	spawn h.write_loop(mut p)
	return p
}

// write_loop is the only thread that writes to this connection.
fn (mut h Hub) write_loop(mut p Peer) {
	for {
		text := <-p.out or { break }
		if p.viewer || p.plain {
			p.client.write_string(text) or { break }
		} else {
			p.client.write(p.sealer.seal(text), .binary_frame) or { break }
		}
		if p.kick {
			break
		}
	}
	h.drop_peer(p.id)
	p.client.close(1000, 'closed') or {}
}

// refuse tells a client why it is not wanted and closes its connection.
fn (mut h Hub) refuse(id string, why string) {
	h.send(Outgoing{
		client: id
		text:   wire.ServerMsg{
			t:   wire.t_error
			msg: why
		}.encode()
		close:  true
	})
}

// drop_peer forgets a connection; its writer thread ends.
fn (mut h Hub) drop_peer(id string) {
	h.peers_mu.lock()
	if p := h.peers[id] {
		p.out.close()
		h.peers.delete(id)
	}
	h.peers_mu.unlock()
}

// send queues a message for its receivers and returns at once.
fn (mut h Hub) send(o Outgoing) {
	h.peers_mu.lock()
	mut slow := []string{}
	for id, mut p in h.peers {
		wanted := if p.viewer { o.viewers || id == o.viewer } else { o.clients || id == o.client }
		if !wanted {
			continue
		}
		if o.close {
			p.kick = true
		}
		if p.out.try_push(o.text) != .success {
			slow << id
		}
	}
	for id in slow {
		// It reconnects and gets the whole picture again.
		if p := h.peers[id] {
			p.out.close()
			h.peers.delete(id)
		}
	}
	h.peers_mu.unlock()
}

// connected counts the browsers or the Cube Watch clients.
fn (mut h Hub) connected(viewers bool) int {
	h.peers_mu.lock()
	defer {
		h.peers_mu.unlock()
	}
	mut n := 0
	for _, p in h.peers {
		if p.viewer == viewers {
			n++
		}
	}
	return n
}

// ---- what the browsers get -------------------------------------------------------

struct KindOut {
	cat     string
	tpl     u32
	name    string
	group   int
	respawn int
	report  bool
}

struct SpotOut {
	id      int
	map     u32
	cat     string
	tpl     u32
	x       f64
	y       f64
	z       f64
	label   string
	hidden  bool
	spawns  int
	takes   int
	respawn int // seconds from taken to the next spawn, 0 unknown
	pickup  int // seconds one stays before it is taken, on average; 0 unknown
}

struct PersonOut {
	key      string
	server   int
	name     string
	map      u32
	x        f64
	y        f64
	z        f64
	seen_at  i64
	cls      string
	level    int
	portrait string
	home     int      // game server of its profile, when that is not the one it is on (the Abyss)
	owner    string   // short tag of the installation: the same for one player's characters
	alts     []string // that player's other characters
}

struct MapOut {
	id     u32
	key    string
	name   string
	image  string
	width  int
	height int
	sx     f64
	sy     f64
	ox     f64
	oy     f64
}

struct ServerName {
	id     int
	name   string
	custom bool // named by the admin
}

// The game servers known when the backend was built (assets/servers.json):
// their names are there from the first moment and without the API.
const servers_json = $embed_file('assets/servers.json').to_string()

struct ServersFile {
	servers []ServerName
}

struct InitOut {
mut:
	t       string = 'init'
	now     i64
	servers []ServerName
	groups  []world.Group
	kinds   []KindOut
	maps    []MapOut
	spots   []SpotOut
	states  []world.State
	people  []PersonOut
}

struct StateMsg {
	t     string = 'state'
	now   i64
	spot  SpotOut
	state world.State
}

struct PeopleMsg {
	t   string = 'people'
	now i64
mut:
	people []PersonOut
}

struct KeyMsg {
	t   string
	key string
}

fn (h &Hub) spot_out(s world.Spot) SpotOut {
	return SpotOut{
		id:      s.id
		map:     s.map
		cat:     s.cat
		tpl:     s.tpl
		x:       s.x
		y:       s.y
		z:       s.z
		label:   s.label
		hidden:  s.hidden
		spawns:  s.spawns
		takes:   s.takes
		respawn: h.w.respawn_seconds(s.id)
		pickup:  s.avg_pickup()
	}
}

fn (h &Hub) person_out(key string, p world.Person) PersonOut {
	prof := h.profiles[key] or { Profile{} }
	return PersonOut{
		key:      key
		server:   p.server
		name:     p.name
		map:      p.map
		x:        p.x
		y:        p.y
		z:        p.z
		seen_at:  p.seen_at
		cls:      prof.cls
		level:    prof.level
		portrait: prof.portrait
		home:     if prof.server != p.server { prof.server } else { 0 }
		owner:    owner_tag(h.owner_of[key] or { '' })
		alts:     h.alts_of(key)
	}
}

// init_json is the whole picture, sent to a browser when it connects and to
// all of them after the admin changed something. Call with `mu` held.
fn (h &Hub) init_json() string {
	mut out := InitOut{
		now:    now_unix()
		groups: h.w.groups.values()
	}
	out.servers = h.servers_out()
	for _, k in h.w.kinds {
		out.kinds << KindOut{k.cat, k.tpl, k.name, k.group_id, k.respawn_sec, k.report}
	}
	for m in h.maps {
		if m.map_ids.len > 0 {
			image := if m.image == '' { '' } else { '/mapimg/${m.image}' }
			out.maps << MapOut{m.map_ids[0], m.key, m.name, image, m.width, m.height, m.sx, m.sy, m.ox, m.oy}
		}
	}
	for _, s in h.w.spots {
		out.spots << h.spot_out(s)
	}
	out.states = h.w.states.values()
	for key, p in h.w.people {
		out.people << h.person_out(key, p)
	}
	return json2.encode(out)
}

// kinds_text is the "kinds" message for the Cube Watch clients.
fn (h &Hub) kinds_text() string {
	mut msg := wire.ServerMsg{
		t: wire.t_kinds
	}
	for _, k in h.w.kinds {
		if !k.report {
			continue
		}
		group := h.w.groups[k.group_id] or { world.Group{} }
		msg.kinds << wire.KindInfo{k.cat, k.tpl, k.name, group.name}
	}
	return msg.encode()
}

// config_changed tells everybody about new groups / kinds / maps. Call with `mu` held.
fn (mut h Hub) config_changed() {
	h.w.refresh_expected()
	h.area_rev++
	h.send(Outgoing{
		viewers: true
		text:    h.init_json()
	})
	h.send(Outgoing{
		clients: true
		text:    h.kinds_text()
	})
}

// ---- browsers ------------------------------------------------------------------------

struct TypeOnly {
	t string
}

fn (mut h Hub) on_viewer_text(id string, text string) {
	msg := json2.decode[TypeOnly](text) or { return }
	if msg.t != 'hello' {
		return
	}
	h.mu.lock()
	init := h.init_json()
	h.mu.unlock()
	h.send(Outgoing{
		viewer: id
		text:   init
	})
}

// ---- Cube Watch clients -----------------------------------------------------------------

fn valid_position(m wire.ClientMsg) bool {
	for v in [m.x, m.y, m.z] {
		if math.is_nan(v) || math.abs(v) > max_coordinate {
			return false
		}
	}
	return true
}

fn (mut h Hub) on_client_text(id string, text string) {
	msg := wire.decode_client(text) or { return }
	now := now_unix()
	h.mu.lock()
	defer {
		h.mu.unlock()
	}
	mut ses := h.sessions[id] or {
		ClientSession{
			since: now
		}
	}
	ses.last = now
	if msg.t == wire.t_hello {
		if msg.ver != wire.protocol_version {
			h.refuse(id, 'this backend and this Cube Watch are of different versions - update both')
			return
		}
		if h.client_key != '' && !same_secret(msg.key, h.client_key) {
			h.send(Outgoing{
				client: id
				text:   wire.ServerMsg{
					t:   wire.t_error
					msg: 'wrong client key'
				}.encode()
				close:  true
			})
			return
		}
		ses.authed = true
		ses.install = clean_install(msg.install)
		h.sessions[id] = ses
		h.send(Outgoing{
			client: id
			text:   h.kinds_text()
		})
		return
	}
	if !ses.authed {
		return
	}
	if msg.t == wire.t_ping {
		h.sessions[id] = ses
		return
	}
	if msg.t == wire.t_near {
		ses.near = msg.items
		ses.near_at = now
		h.sessions[id] = ses
		return
	}
	if msg.t == wire.t_watch {
		ses.watch = msg.watch
		ses.area_key = '' // the places are sent again
		h.sessions[id] = ses
		return
	}
	if !valid_position(msg) {
		return
	}
	map_id := h.canonical_map(msg.map)
	match msg.t {
		wire.t_me {
			ses.map = msg.map
			ses.name = msg.name.trim_space()
			// A client that does not know its game server yet is put on the
			// one its character was found on.
			if msg.server == 0 && ses.found == 0 {
				ses.found = h.name_servers[ses.name.to_lower()] or { 0 }
			}
			ses.server = if msg.server != 0 { msg.server } else { ses.found }
			// A client learns its character's name when the character enters
			// a zone; until then it is on the map without one.
			name := if valid_name(ses.name) { ses.name } else { unknown_prefix + id[..4] }
			old := ses.person
			ses.person = world.person_key(ses.server, name)
			h.sessions[id] = ses
			if old != '' && old != ses.person && old in h.w.people {
				// it has a name (or another character) now
				h.w.people.delete(old)
				h.send(Outgoing{
					viewers: true
					text:    json2.encode(KeyMsg{'person_gone', old})
				})
			}
			known := ses.person in h.w.people
			key := h.w.me(ses.server, name, map_id, msg.x, msg.y, msg.z, now)
			if ses.install != '' && name == ses.name && ses.server > 0 {
				// written down when a session starts with the character (and
				// again when it leaves the map, see flush_loop)
				if ses.noted != key {
					h.note_owner(ses.install, key, ses.server, name, now)
					ses.noted = key
					h.sessions[id] = ses
				}
				h.char_seen[h.home_of[key] or { key }] = now
			}
			if known {
				h.moved_people[key] = true
			} else {
				h.dirty_people[key] = true
			}
		}
		wire.t_seen, wire.t_taken, wire.t_gone {
			if msg.server != 0 {
				ses.server = msg.server
			}
			h.sessions[id] = ses
			sighting := world.Sighting{
				server:  ses.server
				who:     ses.name
				map:     map_id
				cat:     msg.cat
				tpl:     msg.tpl
				x:       msg.x
				y:       msg.y
				z:       msg.z
				entity:  msg.id
				created: if msg.t == wire.t_seen && msg.age >= 0 { now - i64(msg.age) } else { 0 }
			}
			state := if msg.t == wire.t_seen {
				h.w.seen(sighting, now)
			} else {
				h.w.left(sighting, msg.t == wire.t_taken, msg.mine && ses.name != '',
					now)
			}
			if st := state {
				h.reports++
				h.area_rev++
				h.send(Outgoing{
					viewers: true
					text:    json2.encode(StateMsg{
						now:   now
						spot:  h.spot_out(h.w.spots[st.spot_id])
						state: st
					})
				})
			}
		}
		else {}
	}
}

// ---- what watching clients get ----------------------------------------------------------------

// group_rgb reads a group's color ('#f5a623') as 0xRRGGBB.
fn group_rgb(color string) u32 {
	return u32(color.trim_left('#').parse_uint(16, 32) or { 0xf5a623 })
}

// spots_text is the t_spots message: every tracked place of a map that is
// not hidden, with what is there on one game server. Call with `mu` held.
fn (h &Hub) spots_text(server int, map_id u32, now i64) string {
	mut msg := wire.ServerMsg{
		t:   wire.t_spots
		now: now
		map: map_id
	}
	for _, s in h.w.spots {
		if s.map != map_id || s.hidden {
			continue
		}
		kind := h.w.kinds['${s.cat}:${s.tpl}'] or { continue }
		group := h.w.groups[kind.group_id] or { world.Group{} }
		st := h.w.states[world.state_key(server, s.id)] or { world.State{} }
		msg.spots << wire.AreaSpot{
			cat:      s.cat
			tpl:      s.tpl
			x:        s.x
			y:        s.y
			z:        s.z
			present:  st.present
			expected: st.expected
			spawns:   s.spawns
			color:    group_rgb(group.color)
		}
	}
	return msg.encode()
}

// area_loop tells every client that asked for it (wire.t_watch) what the
// backend knows around its character: the other players on its game server
// and map every two seconds, and the tracked places of that map when the
// character came to it or something there changed.
fn (mut h Hub) area_loop() {
	for {
		time.sleep(area_interval)
		now := now_unix()
		mut out := []Outgoing{}
		mut sent := map[string]ClientSession{}
		h.mu.lock()
		for id, ses in h.sessions {
			if !ses.watch || !ses.authed || ses.person == '' {
				continue
			}
			map_id := h.canonical_map(ses.map)
			mut people := wire.ServerMsg{
				t:   wire.t_people
				now: now
			}
			for key, p in h.w.people {
				if key != ses.person && p.server == ses.server && p.map == map_id {
					people.people << wire.AreaPerson{p.name, p.x, p.y, p.z}
				}
			}
			out << Outgoing{
				client: id
				text:   people.encode()
			}
			key := '${ses.server}:${map_id}'
			if key != ses.area_key
				|| (ses.area_rev != h.area_rev && now - ses.area_at >= area_spots_seconds) {
				out << Outgoing{
					client: id
					text:   h.spots_text(ses.server, map_id, now)
				}
				sent[id] = ClientSession{
					...ses
					area_key: key
					area_rev: h.area_rev
					area_at:  now
				}
			}
		}
		for id, ses in sent {
			h.sessions[id] = ses
		}
		h.mu.unlock()
		for o in out {
			h.send(o)
		}
	}
}

// ---- background work -----------------------------------------------------------------------

// flush_loop writes what changed and takes silent players off the map.
fn (mut h Hub) flush_loop() {
	for {
		time.sleep(flush_interval)
		h.mu.lock()
		spots := h.w.take_dirty_spots()
		events := h.w.take_events()
		gone := h.w.expire_people(now_unix(), person_ttl)
		save_changes(h.db, spots, events) or { eprintln('[db] ${err}') }
		for key in gone {
			// when its player's character was last there
			install := h.owner_of[key] or { continue }
			home := h.home_of[key] or { key }
			name := h.owned[install][home] or { continue }
			q(h.db, 'UPDATE owners SET last_seen=? WHERE install=? AND server=? AND name=?',
				h.char_seen[home].str(), install, home.all_before(':'), name) or {
				eprintln('[db] ${err}')
			}
		}
		h.mu.unlock()
		for key in gone {
			h.send(Outgoing{
				viewers: true
				text:    json2.encode(KeyMsg{'person_gone', key})
			})
		}
	}
}

fn (h &Hub) servers_out() []ServerName {
	mut out := []ServerName{}
	for id, name in h.server_names {
		if id !in h.custom_names {
			out << ServerName{id, name, false}
		}
	}
	for id, name in h.custom_names {
		out << ServerName{id, name, true}
	}
	return out
}

// servers_loop keeps the names of the game servers fresh: the list that
// was compiled in is there at once, the official API is asked at start
// (until it works) and once a day, and its last answer is kept in the
// database.
fn (mut h Hub) servers_loop() {
	for {
		names := fetch_server_names()
		if names.len == 0 {
			time.sleep(5 * time.minute)
			continue
		}
		h.mu.lock()
		for id, name in names {
			h.server_names[id] = name
		}
		meta_set_names(h.db, 'server_names', names) or {}
		h.send(Outgoing{
			viewers: true
			text:    h.init_json()
		})
		h.mu.unlock()
		time.sleep(24 * time.hour)
	}
}

// people_loop tells the browsers about the players twice a second, all in
// one go: who is new or has a fresh profile as JSON with everything, and
// who merely moved as plain lines
//
//   pos,<now>
//   <key>,<map>,<x>,<y>,<z>
//
// - with many clients that is far less to build, send and parse than one
// JSON message per move.
fn (mut h Hub) people_loop() {
	for {
		time.sleep(people_interval)
		h.mu.lock()
		if h.dirty_people.len == 0 && h.moved_people.len == 0 {
			h.mu.unlock()
			continue
		}
		now := now_unix()
		mut full := PeopleMsg{
			now: now
		}
		for key, _ in h.dirty_people {
			if p := h.w.people[key] {
				full.people << h.person_out(key, p)
			}
		}
		mut lines := strings.new_builder(64 + 48 * h.moved_people.len)
		mut moved := 0
		lines.write_string('pos,${now}')
		for key, _ in h.moved_people {
			if key in h.dirty_people {
				continue
			}
			if p := h.w.people[key] {
				lines.write_string('\n${key},${p.map},${i64(p.x)},${i64(p.y)},${i64(p.z)}')
				moved++
			}
		}
		h.dirty_people.clear()
		h.moved_people.clear()
		h.mu.unlock()
		if full.people.len > 0 {
			h.send(Outgoing{
				viewers: true
				text:    json2.encode(full)
			})
		}
		if moved > 0 {
			h.send(Outgoing{
				viewers: true
				text:    lines.str()
			})
		}
	}
}

// profile_loop keeps the profiles of the players on the map fresh, one
// character at a time so the official API is not hammered.
fn (mut h Hub) profile_loop() {
	for {
		time.sleep(profile_tick)
		now := now_unix()
		mut server := 0
		mut name := ''
		mut key := ''
		h.mu.lock()
		// the character whose profile is the oldest (or missing) goes first
		mut oldest := i64(max_i64)
		for k, p in h.w.people {
			if p.name.starts_with(unknown_prefix) {
				continue
			}
			fetched := if prof := h.profiles[k] { prof.fetched_at } else { i64(0) }
			tried := h.profile_tries[k] or { i64(0) }
			if now - fetched >= profile_ttl && now - tried >= profile_ttl && fetched < oldest {
				server, name, key, oldest = p.server, p.name, k, fetched
			}
		}
		if key != '' {
			h.profile_tries[key] = now
		}
		prefer := h.common_server()
		// A game server the official list does not have (the Abyss runs on
		// one of its own): the character is found by name like one whose
		// server is not known, but stays where its client says it is.
		listed := server == 0 || server in h.server_names
		h.mu.unlock()
		if key == '' {
			continue
		}
		prof := fetch_profile(if listed { server } else { 0 }, name, prefer, if listed {
			0
		} else {
			server
		}) or {
			eprintln('[profile] ${name}@${server}: ${err}')
			continue
		}
		h.mu.lock()
		if server == 0 {
			// The client did not know its game server; now the backend does.
			h.name_servers[name.to_lower()] = prof.server
			if p := h.w.people[key] {
				h.w.people.delete(key)
				h.send(Outgoing{
					viewers: true
					text:    json2.encode(KeyMsg{'person_gone', key})
				})
				key = h.w.me(prof.server, p.name, p.map, p.x, p.y, p.z, p.seen_at)
			} else {
				key = world.person_key(prof.server, name)
			}
			for sid, ses in h.sessions {
				if ses.name.to_lower() == name.to_lower() && ses.server == 0 {
					h.sessions[sid] = ClientSession{
						...ses
						server: prof.server
						found:  prof.server
						person: key
					}
				}
			}
		}
		h.profiles[key] = prof
		if h.profiles.len > max_profiles {
			h.drop_oldest_profile()
		}
		if h.profile_tries.len > 4 * max_profiles {
			h.profile_tries.clear()
		}
		profile_put(h.db, prof.server, name, json2.encode(prof), prof.fetched_at) or {
			eprintln('[db] ${err}')
		}
		if key in h.w.people {
			h.dirty_people[key] = true
		}
		h.mu.unlock()
	}
}

// common_server is the game server of the official list most players on
// the map are on (0 when nobody's is known). Call with `mu` held.
fn (h &Hub) common_server() int {
	mut counts := map[int]int{}
	mut best := 0
	for _, p in h.w.people {
		if p.server > 0 && p.server in h.server_names {
			counts[p.server]++
			if best == 0 || counts[p.server] > counts[best] {
				best = p.server
			}
		}
	}
	return best
}

fn (mut h Hub) drop_oldest_profile() {
	mut oldest := ''
	mut at := i64(max_i64)
	for k, p in h.profiles {
		if p.fetched_at < at && k !in h.w.people {
			oldest, at = k, p.fetched_at
		}
	}
	if oldest != '' {
		h.profiles.delete(oldest)
	}
}

// clean_install keeps an installation id to letters and digits.
fn clean_install(id string) string {
	mut out := []u8{}
	for c in id {
		if c.is_alnum() && out.len < 40 {
			out << c
		}
	}
	return out.bytestr()
}

// owner_tag is what viewers see of an installation id: enough to tell
// players apart, not the id itself.
fn owner_tag(install string) string {
	return if install.len >= 6 { install[..6] } else { install }
}

// note_owner remembers that a character is played from an installation.
// Call with `mu` held.
fn (mut h Hub) note_owner(install string, key string, server int, name string, now i64) {
	h.owner_of[key] = install
	h.owned[install][key] = name
	h.char_seen[key] = now
	q(h.db, 'INSERT INTO owners(install,server,name,last_seen) VALUES(?,?,?,?)
		ON CONFLICT(install,server,name) DO UPDATE SET last_seen=excluded.last_seen',
		install, server.str(), name, now.str()) or { eprintln('[db] ${err}') }
	h.merge_instances(install)
}

// server_named: the official list or the admin has a name for this game server.
fn (h &Hub) server_named(id int) bool {
	return id in h.server_names || id in h.custom_names
}

// home_server is the game server a character of an installation is listed
// under. In shared zones (the Abyss, instances) the game puts a character on
// a game server of its own, one without a name: that is not another
// character. It belongs to the character of the same name the installation
// has on a named server - of several, the one whose id ends in the same two
// digits (3304 -> 2304), else the one seen last - or, while there is none,
// to the server its profile was found on. Call with `mu` held.
fn (h &Hub) home_server(install string, server int, name string) int {
	if h.server_named(server) {
		return server
	}
	mut best := 0
	mut best_same := false
	mut best_seen := i64(-1)
	for key, other in h.owned[install] or {
		map[string]string{}
	} {
		id := key.all_before(':').int()
		if other.to_lower() != name.to_lower() || !h.server_named(id) {
			continue
		}
		same := id % 100 == server % 100
		seen := h.char_seen[key]
		if best == 0 || (same && !best_same) || (same == best_same && seen > best_seen) {
			best, best_same, best_seen = id, same, seen
		}
	}
	if best != 0 {
		return best
	}
	if prof := h.profiles[world.person_key(server, name)] {
		if prof.server != server && h.server_named(prof.server) {
			return prof.server
		}
	}
	return server
}

// merge_instances folds an installation's characters on game servers without
// a name into the same character on its named server (home_server), in
// memory and in the database. Call with `mu` held.
fn (mut h Hub) merge_instances(install string) {
	mut chars := h.owned[install].clone()
	mut changed := false
	for key, name in h.owned[install].clone() {
		server := key.all_before(':').int()
		home := h.home_server(install, server, name)
		if home == server {
			continue
		}
		target := world.person_key(home, name)
		seen := if h.char_seen[key] > h.char_seen[target] {
			h.char_seen[key]
		} else {
			h.char_seen[target]
		}
		chars.delete(key)
		if target !in chars {
			chars[target] = name
		}
		h.char_seen[target] = seen
		h.char_seen.delete(key)
		h.home_of[key] = target
		h.owner_of[target] = install
		changed = true
		q(h.db, 'DELETE FROM owners WHERE install=? AND server=? AND name=?', install,
			server.str(), name) or { eprintln('[db] ${err}') }
		q(h.db, 'INSERT INTO owners(install,server,name,last_seen) VALUES(?,?,?,?)
			ON CONFLICT(install,server,name) DO UPDATE SET last_seen=max(last_seen, excluded.last_seen)',
			install, home.str(), chars[target], seen.str()) or { eprintln('[db] ${err}') }
	}
	if changed {
		h.owned[install] = chars.clone()
	}
}

// alts_of lists the other characters of the same player, each name once.
// The same name on other game servers is not another character: in shared
// zones the game puts a character on a game server of its own, and those
// that could not be folded into a named server (merge_instances) are still
// separate rows.
fn (h &Hub) alts_of(key string) []string {
	install := h.owner_of[key] or { return [] }
	own := h.home_of[key] or { key }
	own_name := (h.owned[install][own] or { key.all_after(':') }).to_lower()
	mut seen := map[string]bool{}
	mut out := []string{}
	for k, name in h.owned[install] or {
		map[string]string{}
	} {
		lower := name.to_lower()
		if k == own || lower == own_name || lower in seen {
			continue
		}
		seen[lower] = true
		out << name
	}
	out.sort()
	return out
}

// ask_nearby asks one client what is around it; its answer is kept in the
// session. Call with `mu` held.
fn (mut h Hub) ask_nearby(id string) bool {
	if id !in h.sessions {
		return false
	}
	h.send(Outgoing{
		client: id
		text:   wire.ServerMsg{
			t:   wire.t_nearby
			msg: now_unix().str()
		}.encode()
	})
	return true
}

// ---- statistics ---------------------------------------------------------------------------

struct KindStats {
	cat       string
	tpl       u32
	name      string
	spots     int
	here      int // there right now
	seen_day  int // new ones seen in the last 24 hours
	taken_day int
	seen_all  int
	taken_all int
	respawn   int // typical seconds from taken to the next one, 0 unknown
	pickup    int // average seconds until one is taken, 0 unknown
}

struct TakerStats {
	who string
	n   int
}

struct StatsOut {
mut:
	now    i64
	server int
	kinds  []KindStats
	takers []TakerStats // who took the most in the last 7 days
}

// stats_json sums up one game server (-1 = all of them, the imported
// history included). Call with `mu` held.
fn (mut h Hub) stats_json(server int) string {
	now := now_unix()
	mut out := StatsOut{
		now:    now
		server: server
	}
	// what is still waiting in memory belongs into the numbers too
	save_changes(h.db, h.w.take_dirty_spots(), h.w.take_events()) or {}
	mut day := map[string][]int{}
	rows := q(h.db, "SELECT s.cat, s.tpl,
			count(DISTINCT CASE WHEN e.typ IN ('seen','noted') AND e.ts>=?1 THEN e.id END),
			count(DISTINCT CASE WHEN e.typ IN ('taken','gone') AND e.ts>=?1 THEN e.spot_id||':'||e.ts END),
			count(DISTINCT CASE WHEN e.typ IN ('seen','noted') THEN e.id END),
			count(DISTINCT CASE WHEN e.typ IN ('taken','gone') THEN e.spot_id||':'||e.ts END)
		FROM events e JOIN spots s ON s.id = e.spot_id WHERE e.server=?2 OR ?2='-1' GROUP BY s.cat, s.tpl",
		(now - 86400).str(), server.str()) or { [] }
	for r in rows {
		day['${r.vals[0]}:${r.vals[1]}'] = r.vals[2..].map(it.int())
	}
	for key, k in h.w.kinds {
		mut spots := 0
		mut here := 0
		mut delays := []int{}
		mut life_sum := i64(0)
		mut life_n := 0
		for _, s in h.w.spots {
			if s.cat != k.cat || s.tpl != k.tpl {
				continue
			}
			life_sum += s.life_sum
			life_n += s.life_n
			if server < 0 {
				spots++
				continue
			}
			// a place is one of a game server's once something was seen at it there
			if st := h.w.states[world.state_key(server, s.id)] {
				spots++
				if st.present {
					here++
				}
			}
		}
		if server < 0 {
			for _, st in h.w.states {
				if st.present {
					if sp := h.w.spots[st.spot_id] {
						if sp.cat == k.cat && sp.tpl == k.tpl {
							here++
						}
					}
				}
			}
		}
		delays = h.w.kind_delays[key] or { []int{} }
		mut sorted := delays.clone()
		sorted.sort()
		n := day[key] or { [0, 0, 0, 0] }
		out.kinds << KindStats{
			cat:       k.cat
			tpl:       k.tpl
			name:      k.name
			spots:     spots
			here:      here
			seen_day:  n[0]
			taken_day: n[1]
			seen_all:  n[2]
			taken_all: n[3]
			respawn:   if k.respawn_sec > 0 {
				k.respawn_sec
			} else if sorted.len > 0 {
				sorted[sorted.len / 2]
			} else {
				0
			}
			pickup:    if life_n > 0 { int(life_sum / life_n) } else { 0 }
		}
	}
	takers := q(h.db, "SELECT who, count(*) FROM events WHERE (server=?1 OR ?1='-1') AND typ='taken' AND who<>'' AND ts>=?2 GROUP BY who ORDER BY 2 DESC, 1 LIMIT 10",
		server.str(), (now - 7 * 86400).str()) or { [] }
	for r in takers {
		out.takers << TakerStats{r.vals[0], r.vals[1].int()}
	}
	return json2.encode(out)
}

// valid_name: a character name that fits into a line of the text format.
fn valid_name(name string) bool {
	if name.len < 1 || name.len > 48 {
		return false
	}
	for c in name {
		if c < 0x21 || c == `,` || c == `:` {
			return false
		}
	}
	return true
}

// same_secret compares in constant time (no early exit on the first differing byte).
fn same_secret(a string, b string) bool {
	if a.len != b.len {
		return false
	}
	mut diff := u8(0)
	for i in 0 .. a.len {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}
