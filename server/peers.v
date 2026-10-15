module main

import net
import rand
import sync
import wire

// The websocket connections (browsers and Cube Watch clients), without
// net.websocket: that module reads a frame in tiny pieces - dozens of
// recv / select calls and shared-state locks per message - which with a
// few hundred clients reporting every second costs more CPU than all the
// rest of the backend. Here a connection reads into one buffer
// (wire.FrameReader takes the frames apart) on the thread that accepted
// it, and a writer thread of its own sends what the hub queued, so a slow
// or dead peer never holds the others back. An idle connection is two
// sleeping threads: one waiting in recv, one on its queue.
//
// The queue is a plain array, not a channel: a channel keeps every message
// that passed through its slots reachable until the slot is used again, so
// each connection held on to its last few hundred messages.

// What may wait for one peer, in bytes of text: a peer that falls further
// behind is too slow and is dropped (it reconnects and gets everything anew).
const max_peer_bytes = 1024 * 1024

// PeerOut is one frame for a peer's writer: a message (op 0: text for a
// browser, sealed binary for a client) or a control frame.
struct PeerOut {
	op    u8
	text  string
	close bool // close the connection after it
	area  bool // the area message of area_loop (at most one waits)
}

// Peer is one websocket connection.
@[heap]
struct Peer {
	id     string
	viewer bool   // a browser; else a Cube Watch client
	ip     string // where it connects from (behind a proxy: what the proxy saw)
mut:
	conn &net.TcpConn = unsafe { nil }
	// What a Cube Watch client gets is sealed (wire/seal.v).
	sealer wire.Sealer
	// The messages waiting for the writer, their bytes of text, whether an
	// area message is among them, and whether the peer was dropped; all under
	// hub.peers_mu. `wake` is posted once per message and once when dropped.
	pending      []PeerOut
	queued       int
	area_waiting bool
	closed       bool
	wake         &sync.Semaphore = sync.new_semaphore()
}

// serve_peer runs a websocket connection whose handshake was answered; it
// returns when the connection is over. The caller closes the socket.
fn (mut h Hub) serve_peer(mut conn net.TcpConn, viewer bool, ip string) {
	mut p := &Peer{
		id:     rand.uuid_v4()
		viewer: viewer
		ip:     ip
		conn:   conn
		sealer: wire.new_sealer(true)
	}
	h.peers_mu.lock()
	h.peers[p.id] = p
	h.peers_mu.unlock()
	if !viewer {
		now := now_unix()
		h.mu.lock()
		h.sessions[p.id] = ClientSession{
			since: now
			last:  now
			ip:    ip
		}
		h.mu.unlock()
	}
	writer := spawn h.write_loop(mut p)
	h.read_loop(mut p)
	// The writer ends when the peer is dropped; shutting the socket down
	// ends a write that hangs on a slow peer too. The socket is closed only
	// after that, so its number cannot go to a new connection while the
	// writer might still use it.
	h.drop_peer(p.id)
	net.shutdown(conn.sock.handle)
	writer.wait()
	if !viewer {
		h.mu.lock()
		h.sessions.delete(p.id)
		h.mu.unlock()
	}
}

// read_loop reads and handles what the peer sends until the connection
// ends: closed, broken, not a websocket stream, or silent for peer_silence
// (the read timeout of the socket).
fn (mut h Hub) read_loop(mut p Peer) {
	mut reader := wire.FrameReader{}
	mut buf := []u8{len: 4096}
	for {
		n := p.conn.read(mut buf) or { return }
		if n <= 0 {
			return
		}
		reader.feed(buf[..n])
		for {
			frame := reader.next() or { break }
			match frame.opcode {
				wire.op_text {
					if p.viewer {
						h.on_viewer_text(p.id, frame.payload.bytestr())
					} else {
						// a Cube Watch from before the encryption: told to
						// update, in the plain text it understands
						h.push(p.id, PeerOut{
							op:    wire.op_text
							text:  wire.ServerMsg{
								t:   wire.t_error
								msg: 'this backend needs a newer Cube Watch'
							}.encode()
							close: true
						})
					}
				}
				wire.op_binary {
					if !p.viewer {
						text := wire.open(frame.payload, false) or {
							h.refuse(p.id, 'not a Cube Watch message')
							continue
						}
						h.on_client_text(p.id, text)
					}
				}
				wire.op_ping {
					h.push(p.id, PeerOut{
						op:   wire.op_pong
						text: frame.payload.bytestr()
					})
				}
				wire.op_close {
					// answered with the same status, then the connection ends
					h.push(p.id, PeerOut{
						op:    wire.op_close
						text:  frame.payload#[..2].bytestr()
						close: true
					})
					return
				}
				else {}
			}
		}
		if reader.error != '' {
			return
		}
	}
}

// write_loop is the only thread that writes to this connection.
fn (mut h Hub) write_loop(mut p Peer) {
	for {
		p.wake.wait()
		h.peers_mu.lock()
		if p.closed || p.pending.len == 0 {
			closed := p.closed
			h.peers_mu.unlock()
			if closed {
				break
			}
			continue
		}
		m := p.pending[0]
		p.pending.delete(0)
		if p.pending.len == 0 {
			// a new array: the old one would keep the texts reachable
			p.pending = []PeerOut{}
		}
		h.peers_mu.unlock()
		// the text is only read: no copy of it before the frame
		text := unsafe { m.text.str.vbytes(m.text.len) }
		frame := if m.op != 0 {
			wire.encode_server_frame(m.op, text)
		} else if p.viewer {
			wire.encode_server_frame(wire.op_text, text)
		} else {
			wire.encode_server_frame(wire.op_binary, p.sealer.seal(m.text))
		}
		p.conn.write(frame) or { break }
		h.peers_mu.lock()
		p.queued -= m.text.len
		if m.area {
			p.area_waiting = false
		}
		h.peers_mu.unlock()
		if m.close {
			if m.op != wire.op_close {
				p.conn.write(wire.encode_server_frame(wire.op_close, [u8(0x03), 0xe8])) or {}
			}
			break
		}
	}
	h.drop_peer(p.id)
	// wakes the reader, which ends the connection
	net.shutdown(p.conn.sock.handle)
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
	if mut p := h.peers[id] {
		close_peer(mut p)
		h.peers.delete(id)
	}
	h.peers_mu.unlock()
}

// close_peer ends its writer. Call with `peers_mu` held.
fn close_peer(mut p Peer) {
	if !p.closed {
		p.closed = true
		p.pending = []PeerOut{}
		p.queued = 0
		p.wake.post()
	}
}

// QueueResult says what became of a message for one peer.
enum QueueResult {
	queued
	skipped // an area message while the last one still waits
	slow    // the peer is too far behind: to be dropped
}

// queue puts a message into a peer's queue. Call with `peers_mu` held.
fn queue(mut p Peer, m PeerOut) QueueResult {
	if m.area && p.area_waiting {
		// the waiting one is replaced by the next round anyway
		return .skipped
	}
	if p.closed {
		return .skipped
	}
	if p.queued + m.text.len > max_peer_bytes || p.pending.len >= peer_queue {
		return .slow
	}
	p.pending << m
	p.queued += m.text.len
	p.wake.post()
	if m.area {
		p.area_waiting = true
	}
	return .queued
}

// push queues one frame for one peer.
fn (mut h Hub) push(id string, m PeerOut) {
	h.peers_mu.lock()
	if mut p := h.peers[id] {
		if queue(mut p, m) == .slow {
			close_peer(mut p)
			h.peers.delete(id)
		}
	}
	h.peers_mu.unlock()
}

// send queues a message for its receivers and returns at once.
fn (mut h Hub) send(o Outgoing) {
	h.send_all([o])
}

// send_all queues messages for their receivers, under one lock. A message
// for one peer goes straight to it; a peer that is too far behind is
// dropped (it reconnects and gets the whole picture again). It returns the
// peers an area message was not queued for (the last one still waits).
fn (mut h Hub) send_all(msgs []Outgoing) []string {
	h.peers_mu.lock()
	mut slow := []string{}
	mut skipped := []string{}
	for o in msgs {
		item := PeerOut{
			text:  o.text
			close: o.close
			area:  o.area
		}
		if o.viewers || o.clients {
			for id, mut p in h.peers {
				if (p.viewer && o.viewers) || (!p.viewer && o.clients) {
					if queue(mut p, item) == .slow {
						slow << id
					}
				}
			}
		}
		for id in [o.viewer, o.client] {
			if id == '' || (id == o.viewer && o.viewers) || (id == o.client && o.clients) {
				continue
			}
			if mut p := h.peers[id] {
				if p.viewer != (id == o.viewer) {
					continue
				}
				match queue(mut p, item) {
					.slow { slow << id }
					.skipped { skipped << id }
					.queued {}
				}
			}
		}
	}
	for id in slow {
		if mut p := h.peers[id] {
			close_peer(mut p)
			h.peers.delete(id)
		}
	}
	h.peers_mu.unlock()
	return skipped
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
