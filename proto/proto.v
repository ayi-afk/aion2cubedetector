// Package proto decodes the AION 2 server->client TCP stream and reports
// cube spawns and local player positions. Ported from cube_watch.py.
module proto

import encoding.binary
import encoding.utf8
import math

pub const default_port = 13328
pub const cube_template = u32(0x0013DACF)

// Duplicate placeholder frames observed in captures.
const nop_frame = [u8(0x00), 0x00, 0x20, 0x20, 0x20, 0x20]

// A gap that has not been filled for this long is treated as lost data.
const gap_timeout = 1.0
const max_pending_segments = 4096
const max_bundle_size = u32(1_000_000)
const max_bundle_depth = 3

// Largest message accepted straight from the TCP stream. After lost data a
// wrong size would otherwise hold back everything until that many bytes
// arrived; larger messages only occur inside bundles.
const max_frame_size = 65535

pub enum VarintStatus {
	ok
	incomplete
	invalid
}

pub struct Varint {
pub:
	status VarintStatus
	value  u64
	width  int
}

// read_varint decodes a little-endian base-128 varint of at most 5 bytes.
pub fn read_varint(buf []u8, pos int) Varint {
	mut value := u64(0)
	for i in 0 .. 5 {
		if pos + i >= buf.len {
			return Varint{
				status: .incomplete
			}
		}
		b := buf[pos + i]
		value |= u64(b & 0x7f) << (7 * i)
		if b < 0x80 {
			return Varint{
				status: .ok
				value:  value
				width:  i + 1
			}
		}
	}
	return Varint{
		status: .invalid
	}
}

// lz4_block decompresses a raw LZ4 block whose decoded size is known.
pub fn lz4_block(src []u8, expected int) ![]u8 {
	mut out := []u8{cap: expected}
	mut pos := 0
	for pos < src.len {
		token := src[pos]
		pos++
		mut literal := int(token >> 4)
		if literal == 15 {
			for {
				if pos >= src.len {
					return error('truncated LZ4 literal length')
				}
				n := src[pos]
				pos++
				literal += n
				if n != 255 {
					break
				}
			}
		}
		if pos + literal > src.len {
			return error('truncated LZ4 literals')
		}
		out << src[pos..pos + literal]
		pos += literal
		if pos == src.len {
			break
		}
		if pos + 2 > src.len {
			return error('truncated LZ4 offset')
		}
		offset := int(src[pos]) | int(src[pos + 1]) << 8
		pos += 2
		if offset == 0 || offset > out.len {
			return error('bad LZ4 offset')
		}
		mut length := int(token & 15) + 4
		if token & 15 == 15 {
			for {
				if pos >= src.len {
					return error('truncated LZ4 match length')
				}
				n := src[pos]
				pos++
				length += n
				if n != 255 {
					break
				}
			}
		}
		if out.len + length > expected {
			return error('LZ4 output exceeds expected length')
		}
		for _ in 0 .. length {
			out << out[out.len - offset]
		}
	}
	if out.len != expected {
		return error('bad LZ4 length')
	}
	return out
}

pub struct Vec3 {
pub:
	x f64
	y f64
	z f64
}

pub fn (v Vec3) is_finite() bool {
	return !math.is_nan(v.x) && !math.is_inf(v.x, 0) && !math.is_nan(v.y) && !math.is_inf(v.y, 0)
		&& !math.is_nan(v.z) && !math.is_inf(v.z, 0)
}

// read_vec3 reads three little-endian f32 (x, y, z) at `at`.
pub fn read_vec3(buf []u8, at int) Vec3 {
	return Vec3{
		x: f64(math.f32_from_bits(binary.little_endian_u32_at(buf, at)))
		y: f64(math.f32_from_bits(binary.little_endian_u32_at(buf, at + 4)))
		z: f64(math.f32_from_bits(binary.little_endian_u32_at(buf, at + 8)))
	}
}

pub enum EventKind {
	cube         // a cube spawned (first time this object id is seen)
	cube_visible // a known cube came back into view
	cube_opening // a player started opening a known cube (`actor`)
	cube_opened  // a player finished opening a known cube (`actor`)
	cube_removed // a known cube left the client's view (`reason`)
	player
	player_detected
	player_lost // the entity taken for the local player turned out to be something else
	map_entered // the character was placed on a map (`id` = map id, `pos`)
	game_server // the game server (world) the client logged in to (`id`, e.g. 2304)
	player_name // the local character's name (`id` = its entity id, `name`)
	// Only with Decoder.entities: every object and NPC, cubes included.
	entity         // an object or NPC came into view (`info`, `pos`)
	entity_moved   // a known NPC moved (`pos`)
	entity_removed // a known object or NPC left the view (`reason`)
	entity_opened  // a player finished opening a known object (`actor`)
}

pub enum EntityCategory {
	object // 34 36: cubes, gatherables, chests, ...
	npc    // 41 36: monsters and other NPCs
}

// EntityInfo describes an object or NPC as its spawn message does.
pub struct EntityInfo {
pub:
	category EntityCategory
	template u32    // what it is; the same for every entity of that sort
	flags    string // flag bytes of the spawn message whose meaning is unknown, as hex
	heading  f64    // degrees
	hp       i64 = -1 // NPCs only
	max_hp   i64 = -1
	age      f64 = -1 // objects: seconds since the server created it, -1 unknown
}

// Removal reason observed for cubes after they were opened. Other values
// (0x01) are sent when an object merely leaves the visible range.
pub const removed_destroyed = u8(0x04)
// Removal reason of an NPC (42 36) observed when one died.
pub const npc_removed_dead = u8(0x03)

pub struct Event {
pub:
	kind      EventKind
	id        u64 // cube object id, or player entity id
	actor     u64 // player entity id for cube_opening / cube_opened
	reason    u8  // removal reason for cube_removed / entity_removed
	pos       Vec3
	timestamp f64
	info      EntityInfo // for entity
	name      string     // for player_name
}

// Decoder turns individual game messages into events. It keeps the
// per-session state: which cubes were already reported and which entity
// is the local player.
pub struct Decoder {
mut:
	seen map[u64]bool
	// Another entity may take over as the local player (see rearm_player).
	rearmed bool
	// The local player was named by the game itself (33 36), not guessed.
	confirmed bool
	// Entities that spawned as an object, an NPC or another player: never
	// the local player, whatever effects they put on themselves.
	not_me map[u64]bool
	// Objects and NPCs in view, reported through entity events.
	tracked map[u64]bool
	// The server's clock (ms), sent 20 times a second.
	server_time u64
pub mut:
	self_id ?u64
	events  []Event
	// Report every object and NPC (entity events), not only cubes.
	entities bool
	// Analysis tools set `trace` to keep every message in `messages`.
	trace    bool
	messages []RawMessage
}

// RawMessage is one framed message: opcode (2 bytes) and body, without the
// size varint.
pub struct RawMessage {
pub:
	timestamp f64
	data      []u8
}

// reset_player forgets the detected local player so the next matching
// position update selects it again (e.g. after a character switch).
pub fn (mut d Decoder) reset_player() {
	d.self_id = none
	d.rearmed = false
	d.confirmed = false
}

// rearm_player keeps following the detected local player but lets the next
// entity that looks like the local player replace it. Used when the entity
// id may have changed (new server connection, no position for a while):
// unlike reset_player it keeps the positions coming when the id is the same.
pub fn (mut d Decoder) rearm_player() {
	// An id the game named itself only changes with a new connection.
	if !d.confirmed {
		d.rearmed = true
	}
}

// new_connection: the game connected to another server (zone or instance
// change). The character gets a new entity id there and every other id
// means something else.
pub fn (mut d Decoder) new_connection() {
	d.rearmed = true
	d.confirmed = false
	d.not_me.clear()
	d.forget_entities()
}

// other_entity notes that `id` spawned as something that is not the local
// player. If it was guessed to be the player, that guess is dropped.
fn (mut d Decoder) other_entity(id u64, timestamp f64) {
	if d.not_me.len > 50000 {
		d.not_me.clear()
	}
	d.not_me[id] = true
	if d.confirmed {
		return
	}
	if current := d.self_id {
		if current == id {
			d.self_id = none
			d.events << Event{
				kind:      .player_lost
				id:        id
				timestamp: timestamp
			}
		}
	}
}

// forget_entities drops the objects and NPCs in view; another server uses
// its own entity ids.
pub fn (mut d Decoder) forget_entities() {
	d.tracked.clear()
	d.server_time = 0
}

fn (mut d Decoder) set_self(id u64, timestamp f64) {
	d.rearmed = false
	if current := d.self_id {
		if current == id {
			return
		}
	}
	d.self_id = id
	d.events << Event{
		kind:      .player_detected
		id:        id
		timestamp: timestamp
	}
}

pub fn (mut d Decoder) take_events() []Event {
	events := d.events
	d.events = []Event{}
	return events
}

// Server -> client opcodes (two bytes after the size varint). Layouts were
// derived from captures; see README "Protocol notes".
pub const op_login = [u8(0x15), 0x36]! // first message of a game server connection: ..., account string, server id string, ...
pub const op_enter_map = [u8(0x21), 0x36]! // placed on a map: u32, map id u32, u32, u32, xyz, heading f32, ...
pub const op_self_spawn = [u8(0x33), 0x36]! // own character entering a zone: id, ...
pub const op_spawn = [u8(0x34), 0x36]! // object spawn: id, 2 bytes, template u32, xyz
pub const op_despawn = [u8(0x35), 0x36]! // object removed: id, reason u8
pub const op_open_start = [u8(0x38), 0x36]! // object interaction start: id, player id
pub const op_open_done = [u8(0x3a), 0x36]! // object interaction done: id, player id
pub const op_entity_pos = [u8(0x1a), 0x37]! // entity position: id, 2 bytes, xyz
pub const op_entity_start = [u8(0x1b), 0x37]! // entity starts moving: id, 1 byte, xyz
pub const op_entity_step = [u8(0x1c), 0x37]! // entity keeps moving (about once a second): id, 1 byte, xyz
pub const op_npc_spawn = [u8(0x41), 0x36]! // NPC spawn: id, 3 bytes, template u32, 2 bytes, xyz, ...
pub const op_player_spawn = [u8(0x45), 0x36]! // another player coming into view: id, ..., name, ...
pub const op_npc_despawn = [u8(0x42), 0x36]! // NPC removed: id, 1 byte, reason u8
pub const op_server_time = [u8(0x00), 0x36]! // server clock: ms u64
pub const op_effect = [u8(0x2a), 0x38]! // status effect put on a target, with the target's xyz
pub const op_effect_update = [u8(0x2b), 0x38]! // status effect refreshed, same without one byte
pub const op_cast = [u8(0x02), 0x38]! // skill used on a target, with the target's xyz
pub const op_cast_start = [u8(0x09), 0x38]! // skill with a cast time started, same layout

// An effect refresh repeats the position of the first application unless
// this flag says that the position follows the target.
const effect_follows_target = u8(0x02)

// A skill cast carries the target's position only with this flag.
const cast_has_position = u8(0x02)

// on_message handles one framed message; `prefix` is the size varint width.
pub fn (mut d Decoder) on_message(msg []u8, prefix int, timestamp f64) {
	if prefix + 2 > msg.len {
		return
	}
	if d.trace {
		d.messages << RawMessage{
			timestamp: timestamp
			data:      msg[prefix..].clone()
		}
	}
	op := [msg[prefix], msg[prefix + 1]]!
	if op == op_effect || op == op_effect_update {
		d.on_effect(msg[prefix..], timestamp)
	} else if op == op_cast || op == op_cast_start {
		d.on_cast(msg[prefix..], timestamp)
	} else if op == op_spawn {
		d.on_spawn(msg, prefix, timestamp)
	} else if op == op_self_spawn {
		id := read_varint(msg, prefix + 2)
		if id.status == .ok {
			d.not_me.delete(id.value)
			d.set_self(id.value, timestamp)
			d.confirmed = true
			if name := parse_self_name(msg[prefix..]) {
				d.events << Event{
					kind:      .player_name
					id:        id.value
					name:      name
					timestamp: timestamp
				}
			}
		}
	} else if op == op_login {
		if server := parse_login_server(msg[prefix..]) {
			d.events << Event{
				kind:      .game_server
				id:        server
				timestamp: timestamp
			}
		}
	} else if op == op_entity_pos {
		d.on_entity_position(msg, prefix, timestamp)
		d.on_entity_move(msg[prefix..], 2, timestamp)
	} else if op == op_entity_start || op == op_entity_step {
		d.on_entity_move(msg[prefix..], 1, timestamp)
	} else if op == op_open_start || op == op_open_done {
		d.on_interaction(msg, prefix, op == op_open_done, timestamp)
	} else if op == op_despawn {
		d.on_despawn(msg, prefix, timestamp)
		d.on_entity_removed(msg[prefix..], 0, timestamp)
	} else if op == op_npc_spawn {
		d.on_npc_spawn(msg[prefix..], timestamp)
	} else if op == op_player_spawn {
		id := read_varint(msg, prefix + 2)
		if id.status == .ok {
			d.other_entity(id.value, timestamp)
		}
	} else if op == op_enter_map {
		d.on_enter_map(msg[prefix..], timestamp)
	} else if op == op_npc_despawn {
		d.on_entity_removed(msg[prefix..], 1, timestamp)
	} else if op == op_server_time && msg.len == prefix + 10 {
		d.server_time = binary.little_endian_u64_at(msg, prefix + 2)
	}
}

// Reader walks a message front to back; `ok` turns false on a short read.
struct Reader {
	buf []u8
mut:
	pos int
	ok  bool = true
}

fn (mut r Reader) varint() u64 {
	v := read_varint(r.buf, r.pos)
	if v.status != .ok {
		r.ok = false
		return 0
	}
	r.pos += v.width
	return v.value
}

fn (mut r Reader) skip(n int) {
	r.pos += n
	if r.pos > r.buf.len {
		r.ok = false
	}
}

fn (mut r Reader) u8() u8 {
	r.skip(1)
	return if r.ok { r.buf[r.pos - 1] } else { u8(0) }
}

fn (mut r Reader) vec3() Vec3 {
	r.skip(12)
	return if r.ok { read_vec3(r.buf, r.pos - 12) } else { Vec3{} }
}

fn (mut r Reader) u32() u32 {
	r.skip(4)
	return if r.ok { binary.little_endian_u32_at(r.buf, r.pos - 4) } else { u32(0) }
}

fn (mut r Reader) f32() f64 {
	return f64(math.f32_from_bits(r.u32()))
}

// hex returns the next n bytes as hex digits.
fn (mut r Reader) hex(n int) string {
	r.skip(n)
	return if r.ok { r.buf[r.pos - n..r.pos].hex() } else { '' }
}

// Effect is a status effect (buff, debuff, landing, dash, ...) that `caster`
// put on `target` (2a 38) or that was refreshed (2b 38); `pos` is where the
// target stood.
pub struct Effect {
pub:
	caster    u64
	target    u64
	has_skill bool // caused by a skill; plain effects such as landing are not
	flag      u8
	pos       Vec3
}

// parse_effect reads a status effect message; `data` starts at the opcode.
pub fn parse_effect(data []u8) ?Effect {
	if data.len < 2 {
		return none
	}
	mut r := Reader{
		buf: data
		pos: 2
	}
	caster := r.varint()
	if data[0] == op_effect[0] {
		r.skip(1)
	}
	mask := r.u8()
	r.varint() // number of the effect on the target
	r.skip(20) // effect id u32, duration u32, u32, time u64
	target := r.varint()
	r.skip(1) // effect level
	has_skill := mask & 0x02 != 0
	if has_skill {
		r.skip(4)
	}
	flag := r.u8()
	pos := r.vec3()
	if !r.ok || r.pos != data.len {
		return none
	}
	return Effect{
		caster:    caster
		target:    target
		has_skill: has_skill
		flag:      flag
		pos:       pos
	}
}

// on_effect takes the local player's position from every effect put on it,
// whoever the caster is (own skills, other players, monsters).
fn (mut d Decoder) on_effect(data []u8, timestamp f64) {
	e := parse_effect(data) or { return }
	if data[0] == op_effect_update[0] && e.flag != effect_follows_target {
		return
	}
	// An effect an entity puts on itself without a skill (landing, the
	// effects listed when entering a zone) selects only the local player in
	// the reference captures; monsters' own effects come from a skill.
	if e.caster == e.target && !e.has_skill && e.target !in d.not_me
		&& (d.self_id == none || d.rearmed) {
		d.set_self(e.target, timestamp)
	}
	self_id := d.self_id or { return }
	if e.target != self_id {
		return
	}
	d.emit_player(e.target, e.pos, timestamp)
}

// on_cast takes the local player's position from skills aimed at it (e.g.
// by a monster): the message says where the target stands.
fn (mut d Decoder) on_cast(data []u8, timestamp f64) {
	self_id := d.self_id or { return }
	mut r := Reader{
		buf: data
		pos: 2
	}
	r.varint() // caster
	r.skip(6) // kind u8, skill u32, sequence u8
	flag := r.u8()
	target := r.varint()
	r.skip(4) // heading f32
	pos := r.vec3()
	if !r.ok || flag != cast_has_position || target != self_id {
		return
	}
	d.emit_player(target, pos, timestamp)
}

// on_entity_position uses the generic entity position update, which the
// server also sends for the local player (e.g. after landing or a stop).
fn (mut d Decoder) on_entity_position(msg []u8, prefix int, timestamp f64) {
	self_id := d.self_id or { return }
	id := read_varint(msg, prefix + 2)
	if id.status != .ok || id.value != self_id {
		return
	}
	at := prefix + 2 + id.width + 2
	if at + 12 > msg.len {
		return
	}
	d.emit_player(id.value, read_vec3(msg, at), timestamp)
}

fn (mut d Decoder) emit_player(id u64, pos Vec3, timestamp f64) {
	if !pos.is_finite() {
		return
	}
	d.events << Event{
		kind:      .player
		id:        id
		pos:       pos
		timestamp: timestamp
	}
}

// Spawn is an object spawn message of any template.
pub struct Spawn {
pub:
	id       u64
	template u32
	pos      Vec3
	// From the rest of the message, when it is there:
	flags   string // the 2 bytes before the template and 3 state bytes, as hex
	heading f64    // degrees
	created u64    // server clock (ms) when the object was created, 0 unknown
}

// parse_spawn reads an object spawn; `data` starts at the opcode.
pub fn parse_spawn(data []u8) ?Spawn {
	if data.len < 2 || data[0] != op_spawn[0] || data[1] != op_spawn[1] {
		return none
	}
	mut r := Reader{
		buf: data
		pos: 2
	}
	id := r.varint()
	kind := r.hex(2)
	template := r.u32()
	pos := r.vec3()
	if !r.ok || !pos.is_finite() {
		return none
	}
	// 4 zero bytes, heading f32, 3 state bytes, creation time u64, ...
	r.skip(4)
	heading := r.f32()
	state := r.hex(3)
	r.skip(8)
	if !r.ok {
		return Spawn{
			id:       id
			template: template
			pos:      pos
			flags:    kind
		}
	}
	return Spawn{
		id:       id
		template: template
		pos:      pos
		flags:    '${kind} ${state}'
		heading:  heading
		created:  binary.little_endian_u64_at(data, r.pos - 8)
	}
}

// NpcSpawn is an NPC (monster, merchant, ...) coming into view.
pub struct NpcSpawn {
pub:
	id       u64
	template u32
	pos      Vec3
	flags    string // the 3 bytes before and the 2 bytes after the template, as hex
	heading  f64    // degrees
	hp       i64
	max_hp   i64
}

// parse_npc_spawn reads an NPC spawn; `data` starts at the opcode.
pub fn parse_npc_spawn(data []u8) ?NpcSpawn {
	if data.len < 2 || data[0] != op_npc_spawn[0] || data[1] != op_npc_spawn[1] {
		return none
	}
	mut r := Reader{
		buf: data
		pos: 2
	}
	id := r.varint()
	head := r.hex(3)
	template := r.u32()
	tail := r.hex(2)
	pos := r.vec3()
	heading := r.f32()
	r.skip(2)
	marker := r.u8()
	hp := r.varint()
	max_hp := r.varint()
	// A rarer variant of the message has other fields here; it fails this check.
	if !r.ok || marker != 1 || hp > max_hp || !pos.is_finite() {
		return none
	}
	return NpcSpawn{
		id:       id
		template: template
		pos:      pos
		flags:    '${head} ${tail}'
		heading:  heading
		hp:       i64(hp)
		max_hp:   i64(max_hp)
	}
}

fn (mut d Decoder) on_npc_spawn(data []u8, timestamp f64) {
	id := read_varint(data, 2)
	if id.status == .ok {
		d.other_entity(id.value, timestamp)
	}
	if !d.entities {
		return
	}
	sp := parse_npc_spawn(data) or { return }
	d.tracked[sp.id] = true
	d.events << Event{
		kind:      .entity
		id:        sp.id
		pos:       sp.pos
		timestamp: timestamp
		info:      EntityInfo{
			category: .npc
			template: sp.template
			flags:    sp.flags
			heading:  sp.heading
			hp:       sp.hp
			max_hp:   sp.max_hp
		}
	}
}

// is_name reports whether the bytes can be a character name: letters and
// digits (any script), nothing else.
fn is_name(b []u8) bool {
	if b.len < 2 || b.len > 48 {
		return false
	}
	for c in b {
		if c < 0x80 && !c.is_alnum() {
			return false
		}
	}
	return utf8.validate_str(b.bytestr())
}

// parse_self_name reads the character name from the own-character message
// (33 36): id, three small numbers, then the name with its length in front.
// `data` starts at the opcode.
pub fn parse_self_name(data []u8) ?string {
	mut r := Reader{
		buf: data
		pos: 2
	}
	r.varint()
	r.varint()
	r.varint()
	r.varint()
	size := int(r.u8())
	r.skip(size)
	if !r.ok || !is_name(data[r.pos - size..r.pos]) {
		return none
	}
	return data[r.pos - size..r.pos].bytestr()
}

// parse_login_server reads the game server (world) id from the first
// message of a connection (15 36): 2 bytes, two clock values, 3 bytes, the
// account string, then the server id as a string of digits. Only the
// server id is taken; the account string is skipped. `data` starts at the
// opcode.
pub fn parse_login_server(data []u8) ?u64 {
	mut r := Reader{
		buf: data
		pos: 2
	}
	r.skip(2 + 8 + 8 + 3)
	r.skip(int(r.u8()))
	size := int(r.u8())
	r.skip(size)
	if !r.ok || size < 3 || size > 6 {
		return none
	}
	digits := data[r.pos - size..r.pos]
	for c in digits {
		if !c.is_digit() {
			return none
		}
	}
	return digits.bytestr().u64()
}

// on_enter_map reports the map the server puts the character on; it is sent
// once per zone / instance change, before anything on that map.
fn (mut d Decoder) on_enter_map(data []u8, timestamp f64) {
	mut r := Reader{
		buf: data
		pos: 2
	}
	r.skip(4)
	map_id := r.u32()
	r.skip(8)
	pos := r.vec3()
	if !r.ok || map_id == 0 || !pos.is_finite() {
		return
	}
	d.events << Event{
		kind:      .map_entered
		id:        map_id
		pos:       pos
		timestamp: timestamp
	}
}

// on_entity_move follows objects and NPCs in view; `gap` is the number of
// bytes between the id and the position.
fn (mut d Decoder) on_entity_move(data []u8, gap int, timestamp f64) {
	if d.tracked.len == 0 {
		return
	}
	mut r := Reader{
		buf: data
		pos: 2
	}
	id := r.varint()
	r.skip(gap)
	pos := r.vec3()
	if !r.ok || id !in d.tracked || !pos.is_finite() {
		return
	}
	d.events << Event{
		kind:      .entity_moved
		id:        id
		pos:       pos
		timestamp: timestamp
	}
}

// on_entity_removed handles an object (35 36) or NPC (42 36) leaving the
// view; `gap` is the number of bytes between the id and the reason.
fn (mut d Decoder) on_entity_removed(data []u8, gap int, timestamp f64) {
	if d.tracked.len == 0 {
		return
	}
	mut r := Reader{
		buf: data
		pos: 2
	}
	id := r.varint()
	r.skip(gap)
	reason := r.u8()
	if !r.ok || id !in d.tracked {
		return
	}
	d.tracked.delete(id)
	d.events << Event{
		kind:      .entity_removed
		id:        id
		reason:    reason
		timestamp: timestamp
	}
}

// object_age returns how long ago (seconds) the server created an object,
// -1 when either clock value is missing.
fn (d &Decoder) object_age(created u64) f64 {
	if created == 0 || d.server_time == 0 {
		return -1
	}
	// The clock is sent every 50 ms, so a fresh object can be ahead of it.
	return math.max((f64(d.server_time) - f64(created)) / 1000.0, 0.0)
}

fn (mut d Decoder) on_spawn(msg []u8, prefix int, timestamp f64) {
	sp := parse_spawn(msg[prefix..]) or { return }
	d.other_entity(sp.id, timestamp)
	if d.entities {
		d.tracked[sp.id] = true
		d.events << Event{
			kind:      .entity
			id:        sp.id
			pos:       sp.pos
			timestamp: timestamp
			info:      EntityInfo{
				category: .object
				template: sp.template
				flags:    sp.flags
				heading:  sp.heading
				age:      d.object_age(sp.created)
			}
		}
	}
	if sp.template != cube_template {
		return
	}
	known := sp.id in d.seen
	d.seen[sp.id] = true
	d.events << Event{
		kind:      if known { EventKind.cube_visible } else { EventKind.cube }
		id:        sp.id
		pos:       sp.pos
		timestamp: timestamp
	}
}

fn (mut d Decoder) on_interaction(msg []u8, prefix int, done bool, timestamp f64) {
	obj := read_varint(msg, prefix + 2)
	if obj.status != .ok {
		return
	}
	actor := read_varint(msg, prefix + 2 + obj.width)
	if actor.status != .ok {
		return
	}
	if done && obj.value in d.tracked {
		d.events << Event{
			kind:      .entity_opened
			id:        obj.value
			actor:     actor.value
			timestamp: timestamp
		}
	}
	if obj.value !in d.seen {
		return
	}
	d.events << Event{
		kind:      if done { EventKind.cube_opened } else { EventKind.cube_opening }
		id:        obj.value
		actor:     actor.value
		timestamp: timestamp
	}
}

fn (mut d Decoder) on_despawn(msg []u8, prefix int, timestamp f64) {
	obj := read_varint(msg, prefix + 2)
	if obj.status != .ok || obj.value !in d.seen {
		return
	}
	at := prefix + 2 + obj.width
	d.events << Event{
		kind:      .cube_removed
		id:        obj.value
		reason:    if at < msg.len { msg[at] } else { u8(0) }
		timestamp: timestamp
	}
}

// Stream reassembles one TCP direction and splits it into game messages.
pub struct Stream {
mut:
	next_seq      ?u32
	pending       map[u32][]u8
	buffer        []u8
	last_progress f64
}

// seq_diff returns a - b in TCP sequence space, handling wraparound.
fn seq_diff(a u32, b u32) i64 {
	return i64(i32(a - b))
}

pub fn (mut s Stream) feed(seq_in u32, data_in []u8, timestamp f64, mut dec Decoder) {
	if data_in.len == 0 || data_in == nop_frame {
		return
	}
	mut seq := seq_in
	mut next := s.next_seq or {
		s.last_progress = timestamp
		seq
	}

	// The next TCP payload after a loss starts at a frame boundary in the
	// observed traffic, so resynchronise instead of waiting forever.
	if seq_diff(seq, next) > 0
		&& (timestamp - s.last_progress > gap_timeout || s.pending.len >= max_pending_segments) {
		s.pending.clear()
		s.buffer.clear()
		next = seq
	}
	s.next_seq = next
	diff := seq_diff(seq, next)
	if diff + data_in.len <= 0 {
		return
	}
	mut skip := 0
	if diff < 0 {
		skip = int(-diff)
		seq = next
	}
	if seq !in s.pending {
		s.pending[seq] = data_in[skip..].clone()
	}
	for {
		part := s.pending[next] or { break }
		s.pending.delete(next)
		next += u32(part.len)
		s.buffer << part
		s.last_progress = timestamp
		consumed := parse_frames(s.buffer, timestamp, 0, mut dec)
		if consumed > 0 {
			s.buffer.delete_many(0, consumed)
		}
	}
	s.next_seq = next
}

// parse_frames decodes complete frames from buf and returns the number of
// bytes consumed. A frame is a size varint followed by size - 4 bytes
// (opcode and data), whatever the width of the varint. Bundles (0xFFFF
// marker) carry LZ4-compressed frames.
fn parse_frames(buf []u8, timestamp f64, depth int, mut dec Decoder) int {
	mut pos := 0
	for pos < buf.len {
		if buf[pos] == 0 {
			pos++
			continue
		}
		size := read_varint(buf, pos)
		if size.status == .invalid {
			pos++
			continue
		}
		if size.status == .incomplete {
			break
		}
		prefix := size.width
		length := i64(size.value) - 4 + prefix
		// Messages inside a bundle are complete; only the bundle limits them.
		max_length := if depth == 0 { i64(max_frame_size) } else { i64(max_bundle_size) }
		if length < prefix + 2 || length > max_length {
			pos++
			continue
		}
		if pos + length > buf.len {
			break
		}
		is_bundle := buf[pos + prefix] == 0xff && buf[pos + prefix + 1] == 0xff
		if is_bundle {
			payload := buf[pos + prefix..pos + int(length)]
			decode_bundle(payload, timestamp, depth, mut dec)
		} else {
			dec.on_message(buf[pos..pos + int(length)], prefix, timestamp)
		}
		pos += int(length)
	}
	return pos
}

fn decode_bundle(payload []u8, timestamp f64, depth int, mut dec Decoder) {
	if payload.len < 6 || depth >= max_bundle_depth {
		return
	}
	expected := binary.little_endian_u32_at(payload, 2)
	if expected > max_bundle_size {
		return
	}
	// Corrupt bundles are expected after capture loss; skip them like the
	// reference implementation does.
	inner := lz4_block(payload[6..], int(expected)) or { return }
	parse_frames(inner, timestamp, depth + 1, mut dec)
}

pub struct Packet {
pub:
	server      string
	client_port u16
	seq         u32
	payload     []u8
}

// Link-layer types supported by game_packet (pcap DLT values).
pub const dlt_null = 0
pub const dlt_en10mb = 1
pub const dlt_raw = 12
pub const linktype_raw = 101

// game_packet extracts an inbound TCP payload from the game server port.
pub fn game_packet(frame []u8, linktype int, port int) ?Packet {
	mut ip := 0
	match linktype {
		dlt_en10mb {
			if frame.len < 14 {
				return none
			}
			mut ethertype := binary.big_endian_u16_at(frame, 12)
			ip = 14
			if ethertype == 0x8100 && frame.len >= 18 {
				ethertype = binary.big_endian_u16_at(frame, 16)
				ip = 18
			}
			if ethertype != 0x0800 {
				return none
			}
		}
		dlt_null {
			if frame.len < 4 || binary.little_endian_u32_at(frame, 0) != 2 {
				return none
			}
			ip = 4
		}
		dlt_raw, linktype_raw {
			ip = 0
		}
		else {
			return none
		}
	}
	if frame.len < ip + 20 || frame[ip] >> 4 != 4 {
		return none
	}
	ihl := int(frame[ip] & 15) * 4
	if ihl < 20 || frame.len < ip + ihl || frame[ip + 9] != 6 {
		return none
	}
	tcp := ip + ihl
	if frame.len < tcp + 20 {
		return none
	}
	sport := binary.big_endian_u16_at(frame, tcp)
	if sport != port {
		return none
	}
	dport := binary.big_endian_u16_at(frame, tcp + 2)
	seq := binary.big_endian_u32_at(frame, tcp + 4)
	offset := int(frame[tcp + 12] >> 4) * 4
	if offset < 20 || frame.len < tcp + offset {
		return none
	}
	// Ignore Ethernet padding beyond the IP total length.
	total := int(binary.big_endian_u16_at(frame, ip + 2))
	end := if total >= ihl + offset && ip + total <= frame.len { ip + total } else { frame.len }
	server := '${frame[ip + 12]}.${frame[ip + 13]}.${frame[ip + 14]}.${frame[ip + 15]}'
	return Packet{
		server:      server
		client_port: dport
		seq:         seq
		payload:     frame[tcp + offset..end].clone()
	}
}
