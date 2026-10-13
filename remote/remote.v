// Package remote keeps Cube Watch connected to the backend (server/): a
// worker thread dials the websocket, says hello, sends what the app queued
// and hands back what the server said. When the backend cannot be reached
// it tries again every 20 - 30 seconds; the app never waits for it.
module remote

import encoding.base64
import net
import net.mbedtls
import rand
import sync
import time
import wire

// The next attempt after a failed or lost connection comes after
// retry_min .. retry_max seconds.
const retry_min_seconds = 20
const retry_max_seconds = 30
// The worker looks at the outbox this often.
const poll = 200 * time.millisecond
// A ping message this often keeps the connection (and NAT mappings) alive.
const ping_seconds = 20
const handshake_seconds = 10
// Messages that wait while the worker is busy; older ones are dropped.
const max_outbox = 2000

pub struct Config {
pub:
	addr    string // the backend: host:port, a host name alone or a ws(s):// address (wire.parse_endpoint)
	key     string // the backend's client key, '' when it has none
	install string // random id of this installation, so the backend knows which characters belong together
}

@[heap]
pub struct Link {
	cfg Config
mut:
	mu      &sync.Mutex = sync.new_mutex()
	outbox  []string // messages waiting for the worker
	inbox   []wire.ServerMsg
	online  bool
	stop    bool
	started bool
	problem string // why the last attempt or connection ended
	// Called on the worker thread when the inbox or `online` changed.
	notify     fn (voidptr) = unsafe { nil }
	notify_arg voidptr
}

pub fn new_link(cfg Config) &Link {
	return &Link{
		cfg: cfg
	}
}

// on_change sets the function the worker calls (on its own thread) when
// there is news: a message from the server, or the connection came or went.
pub fn (mut l Link) on_change(notify fn (voidptr), arg voidptr) {
	l.notify = notify
	l.notify_arg = arg
}

// start begins connecting in the background; calling it again does nothing.
pub fn (mut l Link) start() {
	l.mu.lock()
	already := l.started
	l.started = true
	l.mu.unlock()
	if !already && l.cfg.addr != '' {
		spawn l.work()
	}
}

pub fn (mut l Link) close() {
	l.mu.lock()
	l.stop = true
	l.mu.unlock()
}

pub fn (mut l Link) is_online() bool {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	return l.online
}

// send queues a message. While the backend is not connected it is dropped:
// reports are only true at the moment they are made, and the app reports
// everything in view again when the connection is back.
pub fn (mut l Link) send(msg wire.ClientMsg) {
	text := msg.encode()
	l.mu.lock()
	if l.online {
		if l.outbox.len >= max_outbox {
			l.outbox.delete(0)
		}
		l.outbox << text
	}
	l.mu.unlock()
}

// take_inbox returns what the server sent since the last call.
pub fn (mut l Link) take_inbox() []wire.ServerMsg {
	l.mu.lock()
	msgs := l.inbox
	l.inbox = []wire.ServerMsg{}
	l.mu.unlock()
	return msgs
}

// problem says why the backend is not connected ('' while it is, or
// before the first attempt ended).
pub fn (mut l Link) problem() string {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	return if l.online { '' } else { l.problem }
}

fn (mut l Link) stopping() bool {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	return l.stop
}

fn (mut l Link) set_online(online bool) {
	l.mu.lock()
	changed := l.online != online
	l.online = online
	if !online {
		l.outbox.clear()
	}
	l.mu.unlock()
	if changed && l.notify != unsafe { nil } {
		l.notify(l.notify_arg)
	}
}

fn (mut l Link) work() {
	for !l.stopping() {
		l.session() or {
			l.mu.lock()
			l.problem = err.msg()
			l.mu.unlock()
		}
		l.set_online(false)
		wait := retry_min_seconds + rand.intn(retry_max_seconds - retry_min_seconds + 1) or { 0 }
		for _ in 0 .. wait * 5 {
			if l.stopping() {
				return
			}
			time.sleep(200 * time.millisecond)
		}
	}
}

fn is_timeout(err IError) bool {
	return err.code() == net.err_timed_out_code
}

// mbedtls says this when nothing came within its read timeout
// (MBEDTLS_ERR_SSL_TIMEOUT); the connection is fine.
const tls_timeout_code = -0x6800

// Conn is the connection to the backend: plain, or inside TLS when the
// backend is behind HTTPS.
struct Conn {
mut:
	tcp &net.TcpConn     = unsafe { nil }
	tls &mbedtls.SSLConn = unsafe { nil }
}

// dial connects. The certificate of a TLS backend is not checked against
// a list of authorities (Cube Watch carries none): TLS is here to get
// through a reverse proxy that only speaks HTTPS, and what is said inside
// is sealed with the key only Cube Watch and the backend have (wire/seal.v).
fn dial(e wire.Endpoint) !Conn {
	if e.tls {
		mut tls := mbedtls.new_ssl_conn(validate: false)!
		tls.dial(e.host, e.port) or {
			tls.shutdown() or {}
			return error('cannot connect to ${e}')
		}
		tls.duration = 10 * time.second
		return Conn{
			tls: tls
		}
	}
	mut tcp := net.dial_tcp('${e.host}:${e.port}') or { return error('cannot connect to ${e}') }
	tcp.set_write_timeout(10 * time.second)
	tcp.set_read_timeout(poll)
	return Conn{
		tcp: tcp
	}
}

fn (mut c Conn) close() {
	if c.tls != unsafe { nil } {
		c.tls.shutdown() or {}
	} else {
		c.tcp.close() or {}
	}
}

fn (mut c Conn) write(data []u8) ! {
	if c.tls != unsafe { nil } {
		c.tls.write(data)!
	} else {
		c.tcp.write(data)!
	}
}

// read returns what came, 0 when nothing did within a moment, and an
// error when the connection is over.
fn (mut c Conn) read(mut buf []u8) !int {
	mut n := 0
	if c.tls != unsafe { nil } {
		n = c.tls.read(mut buf) or {
			if err.code() == tls_timeout_code || is_timeout(err) {
				return 0
			}
			return err
		}
	} else {
		n = c.tcp.read(mut buf) or {
			if is_timeout(err) {
				return 0
			}
			return err
		}
	}
	if n <= 0 {
		return error('the backend closed the connection')
	}
	return n
}

fn write_frame(mut conn Conn, opcode u8, payload []u8) ! {
	key := rand.bytes(4) or { [u8(0x3a), 0x91, 0x5c, 0xe7] }
	conn.write(wire.encode_frame(opcode, payload, [key[0], key[1], key[2], key[3]]!))!
}

// session is one connection from dialing to its end.
fn (mut l Link) session() ! {
	endpoint := wire.parse_endpoint(l.cfg.addr) or {
		return error('"${l.cfg.addr}" is not a backend address')
	}
	mut conn := dial(endpoint)!
	defer {
		conn.close()
	}
	key := base64.encode(rand.bytes(16) or { []u8{len: 16, init: u8(index * 37 + 11)} })
	conn.write(wire.handshake_request(endpoint.host_header(), wire.client_path, key).bytes())!

	mut buf := []u8{len: 16384}
	mut head := []u8{}
	deadline := time.now().add(handshake_seconds * time.second)
	mut body_at := -1
	for body_at < 0 {
		if l.stopping() || time.now() > deadline {
			return error('no answer to the websocket handshake from ${endpoint}')
		}
		n := conn.read(mut buf)!
		if n == 0 {
			continue
		}
		head << buf[..n]
		body_at = head.bytestr().index('\r\n\r\n') or { -1 }
		if head.len > 16384 {
			return error('handshake answer too long')
		}
	}
	if !wire.handshake_ok(head[..body_at].bytestr(), key) {
		// e.g. a proxy that answers with a redirect to HTTPS, or one that
		// does not pass websockets on
		status := head.bytestr().all_before('\r\n')
		return error('${endpoint} did not accept the websocket (${status})')
	}
	mut reader := wire.FrameReader{}
	reader.feed(head[body_at + 4..])

	// Everything after the handshake is sealed (wire/seal.v).
	mut sealer := wire.new_sealer(false)
	hello := wire.ClientMsg{
		t:       wire.t_hello
		key:     l.cfg.key
		ver:     wire.protocol_version
		install: l.cfg.install
	}
	write_frame(mut conn, wire.op_binary, sealer.seal(hello.encode()))!
	l.set_online(true)
	mut last_ping := time.now()
	for !l.stopping() {
		l.mu.lock()
		pending := l.outbox
		l.outbox = []string{}
		l.mu.unlock()
		for text in pending {
			write_frame(mut conn, wire.op_binary, sealer.seal(text))!
		}
		if time.since(last_ping) > ping_seconds * time.second {
			last_ping = time.now()
			write_frame(mut conn, wire.op_binary, sealer.seal(wire.t_ping))!
		}
		n := conn.read(mut buf)!
		if n == 0 {
			continue
		}
		reader.feed(buf[..n])
		mut got := false
		for {
			frame := reader.next() or { break }
			match frame.opcode {
				wire.op_binary {
					text := wire.open(frame.payload, true) or { continue }
					msg := wire.decode_server(text) or { continue }
					l.mu.lock()
					l.inbox << msg
					l.mu.unlock()
					got = true
				}
				wire.op_ping {
					write_frame(mut conn, wire.op_pong, frame.payload)!
				}
				wire.op_close {
					return error('the backend closed the connection')
				}
				else {}
			}
		}
		if reader.error != '' {
			return error(reader.error)
		}
		if got && l.notify != unsafe { nil } {
			l.notify(l.notify_arg)
		}
	}
}
