// Package proto decodes the AION 2 server->client TCP stream and reports
// cube spawns and local player positions. Ported from cube_watch.py.
module proto

import encoding.binary
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

fn read_vec3(buf []u8, at int) Vec3 {
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
}

// Removal reason observed for cubes after they were opened. Other values
// (0x01) are sent when an object merely leaves the visible range.
pub const removed_destroyed = u8(0x04)

pub struct Event {
pub:
	kind      EventKind
	id        u64 // cube object id, or player entity id
	actor     u64 // player entity id for cube_opening / cube_opened
	reason    u8  // removal reason for cube_removed
	pos       Vec3
	timestamp f64
}

// Decoder turns individual game messages into events. It keeps the
// per-session state: which cubes were already reported and which entity
// is the local player.
pub struct Decoder {
mut:
	seen map[u64]bool
pub mut:
	self_id ?u64
	events  []Event
}

// reset_player forgets the detected local player so the next matching
// position update selects it again (e.g. after a character switch).
pub fn (mut d Decoder) reset_player() {
	d.self_id = none
}

pub fn (mut d Decoder) take_events() []Event {
	events := d.events
	d.events = []Event{}
	return events
}

// Server -> client opcodes (two bytes after the size varint). Layouts were
// derived from captures; see README "Protocol notes".
const op_spawn = [u8(0x34), 0x36]! // object spawn: id, 2 bytes, template u32, xyz
const op_despawn = [u8(0x35), 0x36]! // object removed: id, reason u8
const op_open_start = [u8(0x38), 0x36]! // object interaction start: id, player id
const op_open_done = [u8(0x3a), 0x36]! // object interaction done: id, player id
const op_entity_pos = [u8(0x1a), 0x37]! // entity position: id, 2 bytes, xyz

// on_message handles one framed message; `prefix` is the size varint width.
pub fn (mut d Decoder) on_message(msg []u8, prefix int, timestamp f64) {
	if prefix + 2 > msg.len {
		return
	}
	op := [msg[prefix], msg[prefix + 1]]!
	if op[1] == 0x38 && (op[0] == 0x2a || op[0] == 0x2b) {
		d.on_position(msg, prefix, op[0], timestamp)
	} else if op == op_spawn {
		d.on_spawn(msg, prefix, timestamp)
	} else if op == op_entity_pos {
		d.on_entity_position(msg, prefix, timestamp)
	} else if op == op_open_start || op == op_open_done {
		d.on_interaction(msg, prefix, op == op_open_done, timestamp)
	} else if op == op_despawn {
		d.on_despawn(msg, prefix, timestamp)
	}
}

fn (mut d Decoder) on_position(msg []u8, prefix int, op0 u8, timestamp f64) {
	id := read_varint(msg, prefix + 2)
	if id.status != .ok || msg.len < 16 {
		return
	}
	// The trailing self-id / discriminator pair selects only the local
	// player in the reference captures.
	start := math.max(0, msg.len - (14 + id.width))
	tail := msg[start..msg.len - 12]
	tail_id := read_varint(tail, 0)
	if tail_id.status != .ok || tail_id.value != id.value || tail_id.width != id.width {
		return
	}
	disc := tail[id.width..]
	expected_disc := if op0 == 0x2a { [u8(0x01), 0x00] } else { [u8(0x01), 0x02] }
	if disc != expected_disc {
		return
	}
	self_id := d.self_id or {
		d.self_id = id.value
		d.events << Event{
			kind:      .player_detected
			id:        id.value
			timestamp: timestamp
		}
		id.value
	}

	if id.value != self_id {
		return
	}
	d.emit_player(id.value, read_vec3(msg, msg.len - 12), timestamp)
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

fn (mut d Decoder) on_spawn(msg []u8, prefix int, timestamp f64) {
	obj := read_varint(msg, prefix + 2)
	if obj.status != .ok {
		return
	}
	template_at := prefix + 2 + obj.width + 2
	if template_at + 16 > msg.len {
		return
	}
	if binary.little_endian_u32_at(msg, template_at) != cube_template {
		return
	}
	pos := read_vec3(msg, template_at + 4)
	if !pos.is_finite() {
		return
	}
	known := obj.value in d.seen
	d.seen[obj.value] = true
	d.events << Event{
		kind:      if known { EventKind.cube_visible } else { EventKind.cube }
		id:        obj.value
		pos:       pos
		timestamp: timestamp
	}
}

fn (mut d Decoder) on_interaction(msg []u8, prefix int, done bool, timestamp f64) {
	obj := read_varint(msg, prefix + 2)
	if obj.status != .ok || obj.value !in d.seen {
		return
	}
	actor := read_varint(msg, prefix + 2 + obj.width)
	if actor.status != .ok {
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
// bytes consumed. Bundles (0xFFFF marker) carry LZ4-compressed frames.
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
		mut length := i64(size.value) - 3
		if length < 3 || length > 65535 {
			pos++
			continue
		}
		if pos + length > buf.len {
			break
		}
		prefix := size.width
		is_bundle := pos + prefix + 2 <= buf.len && buf[pos + prefix] == 0xff
			&& buf[pos + prefix + 1] == 0xff
		if is_bundle {
			length++
			if pos + length > buf.len {
				break
			}
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
