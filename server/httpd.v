module main

import net
import net.http
import net.urllib
import net.websocket
import time

// A small HTTP server of our own: every connection gets a thread, a
// request is answered and the connection closed - unless it is a websocket
// upgrade, in which case the same thread goes on reading that websocket.
// Nothing here limits how many websockets stay open (an event-loop web
// framework keeps a fixed table of sockets and runs out of it).

const max_head_bytes = 64 * 1024
// The largest request body: a database file for the import.
const max_body_bytes = 256 * 1024 * 1024
const http_timeout = 20 * time.second

// Result marks a handler's return; the response itself is written by the
// Context methods.
pub struct Result {}

pub struct Context {
pub mut:
	req   http.Request
	conn  &net.TcpConn = unsafe { nil }
	path  string
	query map[string]string
mut:
	status  http.Status = .ok
	headers []string // complete "Name: value" lines
	sent    bool
	taken   bool // the connection now belongs to a websocket
}

pub fn (mut ctx Context) set_status(status http.Status) {
	ctx.status = status
}

pub fn (mut ctx Context) set_header(key http.CommonHeader, value string) {
	ctx.headers << '${key.str()}: ${value}'
}

pub fn (mut ctx Context) set_custom_header(key string, value string) ! {
	if key.contains_any('\r\n:') || value.contains_any('\r\n') {
		return error('invalid header')
	}
	ctx.headers << '${key}: ${value}'
}

pub fn (mut ctx Context) set_cookie(cookie http.Cookie) {
	ctx.headers << 'Set-Cookie: ${cookie.str()}'
}

pub fn (ctx &Context) get_cookie(name string) ?string {
	cookie := ctx.req.cookie(name)?
	return cookie.value
}

// send_response_to_client writes the whole response.
pub fn (mut ctx Context) send_response_to_client(mime string, body string) Result {
	if ctx.sent || ctx.taken {
		return Result{}
	}
	ctx.sent = true
	mut head := 'HTTP/1.1 ${ctx.status.int()} ${ctx.status.str()}\r\nContent-Type: ${mime}\r\nContent-Length: ${body.len}\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n'
	for h in ctx.headers {
		head += h + '\r\n'
	}
	head += '\r\n'
	ctx.conn.write_string(head) or { return Result{} }
	if ctx.req.method != .head {
		ctx.conn.write_string(body) or {}
	}
	return Result{}
}

pub fn (mut ctx Context) html(body string) Result {
	return ctx.send_response_to_client('text/html; charset=utf-8', body)
}

pub fn (mut ctx Context) not_found() Result {
	ctx.status = .not_found
	return ctx.send_response_to_client('text/plain; charset=utf-8', '404 Not Found')
}

fn parse_query(raw string) map[string]string {
	mut out := map[string]string{}
	for pair in raw.split('&') {
		if pair == '' {
			continue
		}
		key, value := pair.split_once('=') or { pair, '' }
		out[urllib.query_unescape(key) or { key }] = urllib.query_unescape(value) or { value }
	}
	return out
}

// read_request reads one request: the head up to the empty line, then the
// body the Content-Length header announces.
fn read_request(mut conn net.TcpConn) !http.Request {
	mut data := []u8{cap: 2048}
	mut buf := []u8{len: 16384}
	mut head_end := -1
	for head_end < 0 {
		n := conn.read(mut buf)!
		if n <= 0 {
			return error('closed')
		}
		// the end can straddle two reads: look a little before the new bytes
		from := if data.len > 3 { data.len - 3 } else { 0 }
		data << buf[..n]
		for i in from .. data.len - 3 {
			if data[i] == `\r` && data[i + 1] == `\n` && data[i + 2] == `\r` && data[i + 3] == `\n` {
				head_end = i
				break
			}
		}
		if head_end < 0 && data.len > max_head_bytes {
			return error('request head too large')
		}
	}
	mut req := http.parse_request_head_str(data[..head_end + 4].bytestr())!
	length := (req.header.get(.content_length) or { '0' }).int()
	if length < 0 || length > max_body_bytes {
		return error('request body too large')
	}
	mut body := data[head_end + 4..].clone()
	for body.len < length {
		n := conn.read(mut buf)!
		if n <= 0 {
			return error('closed')
		}
		body << buf[..n]
	}
	req.data = body[..length].bytestr()
	return req
}

// serve accepts connections forever.
fn (mut app App) serve(host string, port int) ! {
	mut listener := net.listen_tcp(.ip, '${host}:${port}')!
	for {
		mut conn := listener.accept() or {
			time.sleep(10 * time.millisecond)
			continue
		}
		spawn app.handle_conn(mut conn)
	}
}

fn (mut app App) handle_conn(mut conn net.TcpConn) {
	conn.set_read_timeout(http_timeout)
	conn.set_write_timeout(http_timeout)
	req := read_request(mut conn) or {
		conn.close() or {}
		return
	}
	raw_path, raw_query := req.url.split_once('?') or { req.url, '' }
	mut ctx := Context{
		req:   req
		conn:  conn
		path:  urllib.path_unescape(raw_path) or { raw_path }
		query: parse_query(raw_query)
	}
	app.route(mut ctx)
	if ctx.taken {
		return
	}
	if !ctx.sent {
		ctx.not_found()
	}
	conn.close() or {}
}

// websocket turns the request into a websocket and reads it until it
// ends; this call returns only then.
fn (mut ctx Context) websocket(mut wss websocket.Server) Result {
	key := ctx.req.header.get(.sec_websocket_key) or { '' }
	if key == '' {
		ctx.status = .bad_request
		return ctx.send_response_to_client('text/plain; charset=utf-8', 'this is a websocket endpoint')
	}
	ctx.taken = true
	// A peer that cannot be written to for this long is dropped by its
	// writer thread; one that says nothing for peer_silence ends here.
	ctx.conn.set_write_timeout(10 * time.second)
	ctx.conn.set_read_timeout(peer_silence)
	wss.handle_handshake(mut ctx.conn, key) or {}
	ctx.conn.close() or {}
	return Result{}
}
