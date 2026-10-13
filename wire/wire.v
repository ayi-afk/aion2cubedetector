// Package wire is what Cube Watch (the client) and the backend in server/
// say to each other over the websocket: short comma separated text
// messages, sealed (seal.v) and sent as binary frames, plus the small
// websocket client codec the client uses. No Windows dependencies.
module wire

import crypto.sha1
import encoding.base64
import encoding.binary

pub const protocol_version = 3

const mix_first = u64(0x7cc7cb5061a03d0b)

// Paths of the backend's websocket endpoints.
pub const client_path = '/ws/client'
pub const viewer_path = '/ws/view'

pub const category_object = 'object'
pub const category_npc = 'npc'

// Message types, client -> server.
pub const t_hello = 'hello' // first message: ver, install, key
pub const t_me = 'me' // who and where the character is
pub const t_seen = 'seen' // a tracked object / NPC came into view
pub const t_taken = 'taken' // a player opened it (mine = this client's character)
pub const t_gone = 'gone' // it was destroyed (collected or expired), not merely out of view
pub const t_ping = 'ping' // keeps the connection alive
pub const t_near = 'near' // answer to t_nearby: what is in view, nearest first
// Message types, server -> client.
pub const t_kinds = 'kinds' // the templates the server wants reports for, with their names
pub const t_error = 'error' // msg says why; the server closes the connection
pub const t_nearby = 'nearby' // the admin wants to see what is around this client (msg = request id)

// A t_near answer lists at most this many things.
pub const max_near_items = 60
const mix_third = u64(0xd2f8c2c5d55fae25)

// NearItem is one object or NPC in a client's view, tracked or not.
pub struct NearItem {
pub mut:
	cat  string
	tpl  u32
	id   u64
	x    f64
	y    f64
	z    f64
	dist f64 // flat distance to the character, -1 unknown
}

// ClientMsg is every message the client sends; `t` says which fields count.
pub struct ClientMsg {
pub mut:
	t       string
	key     string // hello: the shared client key
	ver     int    // hello: protocol_version
	install string // hello: random id of this Cube Watch installation (letters and digits)
	server  int    // game server id of the character, 0 unknown
	name    string // me: character name, '' unknown
	map     u32    // map id, 0 unknown
	x       f64
	y       f64
	z       f64
	cat     string // category_object / category_npc
	tpl     u32    // template id
	id      u64    // entity id on the game server
	age     f64 = -1 // seen: seconds since the game server created it, -1 unknown
	mine    bool       // taken: opened by this client's character
	items   []NearItem // near: what is in view (key = the request id)
}

// KindInfo names one template the server tracks.
pub struct KindInfo {
pub mut:
	cat   string
	tpl   u32
	name  string
	group string
}

// ServerMsg is every message the server sends to a client.
pub struct ServerMsg {
pub mut:
	t     string
	kinds []KindInfo
	msg   string
}

// kind_key identifies a template: the same number can be an object and an NPC.
pub fn kind_key(cat string, tpl u32) string {
	return '${cat}:${tpl}'
}

// ---- text format ----------------------------------------------------------------
//
// A message is one websocket text frame of comma separated fields - cheap
// to write and to read when many clients report every second:
//
//   hello,<version>,<install id>,<key>
//   me,<server>,<map>,<x>,<y>,<z>,<name>
//   seen,<server>,<map>,<o|n>,<template>,<entity>,<x>,<y>,<z>,<age>
//   taken,<server>,<map>,<o|n>,<template>,<entity>,<x>,<y>,<z>,<mine 0|1>
//   gone,<server>,<map>,<o|n>,<template>,<entity>,<x>,<y>,<z>
//   ping
//   near,<request id>          then one line per thing in view:
//   <o|n>,<template>,<entity>,<x>,<y>,<z>,<distance>
//
// and from the server:
//
//   kinds                      then one line per kind:
//   <o|n>,<template>,<group>,<name>
//   error,<text>
//   nearby,<request id>
//
// The last field of a line (key, name, text) may itself contain commas.

fn cat_code(cat string) string {
	return if cat == category_npc { 'n' } else { 'o' }
}

fn cat_name(code string) string {
	return if code == 'n' { category_npc } else { category_object }
}

// one_line keeps a value from breaking the line format.
fn one_line(s string) string {
	return s.replace_each(['\r', ' ', '\n', ' '])
}

// encode writes the message in the text format.
pub fn (m ClientMsg) encode() string {
	return match m.t {
		t_hello {
			'${t_hello},${m.ver},${one_line(m.install).replace(',', '')},${one_line(m.key)}'
		}
		t_me {
			'${t_me},${m.server},${m.map},${m.x:.1f},${m.y:.1f},${m.z:.1f},${one_line(m.name)}'
		}
		t_seen {
			'${t_seen},${m.server},${m.map},${cat_code(m.cat)},${m.tpl},${m.id},${m.x:.1f},${m.y:.1f},${m.z:.1f},${m.age:.1f}'
		}
		t_taken {
			'${t_taken},${m.server},${m.map},${cat_code(m.cat)},${m.tpl},${m.id},${m.x:.1f},${m.y:.1f},${m.z:.1f},${int(m.mine)}'
		}
		t_gone {
			'${t_gone},${m.server},${m.map},${cat_code(m.cat)},${m.tpl},${m.id},${m.x:.1f},${m.y:.1f},${m.z:.1f}'
		}
		t_near {
			mut lines := ['${t_near},${one_line(m.key)}']
			for it in m.items {
				lines << '${cat_code(it.cat)},${it.tpl},${it.id},${it.x:.1f},${it.y:.1f},${it.z:.1f},${it.dist:.0f}'
			}
			lines.join('\n')
		}
		else {
			m.t
		}
	}
}

// decode_client reads a client message; none when it is not one.
pub fn decode_client(text string) ?ClientMsg {
	if text == t_ping {
		return ClientMsg{
			t: t_ping
		}
	}
	if text.starts_with(t_near + ',') {
		lines := text.split('\n')
		mut msg := ClientMsg{
			t:   t_near
			key: lines[0].all_after(',')
		}
		for line in lines[1..] {
			f := line.split(',')
			if f.len == 7 && msg.items.len < max_near_items {
				msg.items << NearItem{cat_name(f[0]), f[1].u32(), f[2].u64(), f[3].f64(), f[4].f64(), f[5].f64(), f[6].f64()}
			}
		}
		return msg
	}
	// the name / key at the end may contain commas
	f := text.split_nth(',', if text.starts_with(t_hello) {
		4
	} else if text.starts_with(t_me + ',') {
		7
	} else {
		0
	})
	match f[0] {
		t_hello {
			if f.len != 4 {
				return none
			}
			return ClientMsg{
				t:       t_hello
				ver:     f[1].int()
				install: f[2]
				key:     f[3]
			}
		}
		t_me {
			if f.len != 7 {
				return none
			}
			return ClientMsg{
				t:      t_me
				server: f[1].int()
				map:    f[2].u32()
				x:      f[3].f64()
				y:      f[4].f64()
				z:      f[5].f64()
				name:   f[6]
			}
		}
		t_seen, t_taken, t_gone {
			if f.len != if f[0] == t_gone {
				9
			} else {
				10
			} {
				return none
			}
			return ClientMsg{
				t:      f[0]
				server: f[1].int()
				map:    f[2].u32()
				cat:    cat_name(f[3])
				tpl:    f[4].u32()
				id:     f[5].u64()
				x:      f[6].f64()
				y:      f[7].f64()
				z:      f[8].f64()
				age:    if f[0] == t_seen { f[9].f64() } else { -1.0 }
				mine:   f[0] == t_taken && f[9] == '1'
			}
		}
		else {
			return none
		}
	}
}

// encode writes the message in the text format.
pub fn (m ServerMsg) encode() string {
	if m.t != t_kinds {
		return '${m.t},${one_line(m.msg)}'
	}
	mut lines := [t_kinds]
	for k in m.kinds {
		lines << '${cat_code(k.cat)},${k.tpl},${one_line(k.group).replace(',', ' ')},${one_line(k.name)}'
	}
	return lines.join('\n')
}

// decode_server reads a server message; none when it is not one.
pub fn decode_server(text string) ?ServerMsg {
	lines := text.split('\n')
	if lines[0] != t_kinds {
		kind, msg := text.split_once(',') or { return none }
		return ServerMsg{
			t:   kind
			msg: msg
		}
	}
	mut out := ServerMsg{
		t: t_kinds
	}
	for line in lines[1..] {
		f := line.split_nth(',', 4)
		if f.len == 4 {
			out.kinds << KindInfo{cat_name(f[0]), f[1].u32(), f[3], f[2]}
		}
	}
	return out
}

// ---- where the backend is -----------------------------------------------------

// Endpoint is the backend's address as Cube Watch dials it.
pub struct Endpoint {
pub:
	host string
	port int
	tls  bool // behind HTTPS (a reverse proxy with a certificate)
}

// parse_endpoint reads REMOTE_ADDR:
//
//   host:port                 plain websocket (TLS when the port is 443)
//   host                      a name alone is a site behind HTTPS: TLS, port 443
//   ws://host[:port]          plain, port 80 unless given   (also http://)
//   wss://host[:port]         TLS, port 443 unless given    (also https://)
//
// A path after the host is ignored: the backend's endpoints are fixed.
pub fn parse_endpoint(addr string) ?Endpoint {
	mut rest := addr.trim_space()
	mut scheme := ''
	if at := rest.index('://') {
		scheme = rest[..at].to_lower()
		rest = rest[at + 3..]
	}
	rest = rest.all_before('/').all_before('?')
	mut host := rest
	mut port := 0
	if colon := rest.last_index(':') {
		host = rest[..colon]
		port = rest[colon + 1..].int()
		if port <= 0 || port > 65535 || rest[colon + 1..] != port.str() {
			return none
		}
	}
	if host == '' || host.contains_any(' :@') {
		return none
	}
	tls := match scheme {
		'wss', 'https' { true }
		'ws', 'http' { false }
		'' { port == 0 || port == 443 }
		else { return none }
	}
	if port == 0 {
		port = if tls { 443 } else { 80 }
	}
	return Endpoint{host, port, tls}
}

// host_header is the Host of the upgrade request: a reverse proxy picks
// the site by it.
pub fn (e Endpoint) host_header() string {
	if (e.tls && e.port == 443) || (!e.tls && e.port == 80) {
		return e.host
	}
	return '${e.host}:${e.port}'
}

// str is the address the way a browser would show it.
pub fn (e Endpoint) str() string {
	return if e.tls { 'wss://' } else { 'ws://' } + e.host_header()
}

// ---- websocket client codec (RFC 6455, no extensions) -----------------------

const ws_guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
const mix_second = u64(0xf5d002150597ab6a)

pub const op_continuation = u8(0x0)
pub const op_text = u8(0x1)
pub const op_binary = u8(0x2)
pub const op_close = u8(0x8)
pub const op_ping = u8(0x9)
pub const op_pong = u8(0xA)

// A frame larger than this is not something the backend sends.
pub const max_frame_payload = 4 * 1024 * 1024
const mix_fourth = u64(0x460a3ac9a66ece79)

// handshake_request is the HTTP upgrade request; `key` is 16 random bytes in base64.
pub fn handshake_request(host string, path string, key string) string {
	return 'GET ${path} HTTP/1.1\r\nHost: ${host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n'
}

// accept_key is the Sec-WebSocket-Accept value the server must answer with.
pub fn accept_key(key string) string {
	return base64.encode(sha1.sum((key + ws_guid).bytes()))
}

// handshake_ok checks the server's answer (status line and headers, up to the empty line).
pub fn handshake_ok(response string, key string) bool {
	lines := response.split('\r\n')
	if lines.len == 0 || !lines[0].starts_with('HTTP/1.1 101') {
		return false
	}
	for line in lines[1..] {
		name, value := line.split_once(':') or { continue }
		if name.trim_space().to_lower() == 'sec-websocket-accept' {
			return value.trim_space() == accept_key(key)
		}
	}
	return false
}

// encode_frame builds one complete (FIN) frame as a client sends it: masked.
pub fn encode_frame(opcode u8, payload []u8, mask [4]u8) []u8 {
	mut out := []u8{cap: payload.len + 14}
	out << (0x80 | opcode)
	if payload.len < 126 {
		out << (0x80 | u8(payload.len))
	} else if payload.len <= 0xffff {
		out << u8(0x80 | 126)
		out << u8(payload.len >> 8)
		out << u8(payload.len)
	} else {
		out << u8(0x80 | 127)
		mut size := []u8{len: 8}
		binary.big_endian_put_u64(mut size, u64(payload.len))
		out << size
	}
	out << mask[0]
	out << mask[1]
	out << mask[2]
	out << mask[3]
	for i, b in payload {
		out << (b ^ mask[i % 4])
	}
	return out
}

// Frame is one received message (fragments already joined).
pub struct Frame {
pub:
	opcode  u8
	payload []u8
}

// FrameReader turns the bytes received from the server into frames.
pub struct FrameReader {
mut:
	buf      []u8
	partial  []u8 // payload of a fragmented message so far
	part_op  u8
	in_parts bool
pub mut:
	// Set when the stream is not a websocket stream we understand; the
	// connection has to be dropped then.
	error string
}

pub fn (mut r FrameReader) feed(data []u8) {
	r.buf << data
}

// next returns the next complete message, or none when more bytes are needed
// (or the stream is broken, see `error`).
pub fn (mut r FrameReader) next() ?Frame {
	for {
		if r.error != '' || r.buf.len < 2 {
			return none
		}
		fin := r.buf[0] & 0x80 != 0
		opcode := r.buf[0] & 0x0f
		masked := r.buf[1] & 0x80 != 0
		mut size := u64(r.buf[1] & 0x7f)
		mut at := 2
		if size == 126 {
			if r.buf.len < 4 {
				return none
			}
			size = u64(binary.big_endian_u16_at(r.buf, 2))
			at = 4
		} else if size == 127 {
			if r.buf.len < 10 {
				return none
			}
			size = binary.big_endian_u64_at(r.buf, 2)
			at = 10
		}
		if size > max_frame_payload {
			r.error = 'websocket frame of ${size} bytes'
			return none
		}
		mask_at := at
		if masked {
			at += 4
		}
		end := at + int(size)
		if r.buf.len < end {
			return none
		}
		mut payload := r.buf[at..end].clone()
		if masked {
			for i in 0 .. payload.len {
				payload[i] ^= r.buf[mask_at + i % 4]
			}
		}
		r.buf.delete_many(0, end)
		if opcode >= 0x8 {
			// Control frames may sit between the fragments of a message.
			return Frame{opcode, payload}
		}
		if opcode != op_continuation {
			r.part_op = opcode
			r.partial = []u8{}
			r.in_parts = true
		} else if !r.in_parts {
			r.error = 'websocket continuation without a start'
			return none
		}
		r.partial << payload
		if r.partial.len > max_frame_payload {
			r.error = 'websocket message too large'
			return none
		}
		if fin {
			r.in_parts = false
			done := r.partial
			r.partial = []u8{}
			return Frame{r.part_op, done}
		}
	}
	return none
}
