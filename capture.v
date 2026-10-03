module main

import os
import proto
import sync
import time

// Npcap bindings resolved at runtime so the app can start (and offer to
// install Npcap) when wpcap.dll is missing.

struct PcapIf {
	next        &PcapIf
	name        &char
	description &char
	addresses   &PcapAddr
	flags       u32
}

struct PcapAddr {
	next      &PcapAddr
	addr      voidptr
	netmask   voidptr
	broadaddr voidptr
	dstaddr   voidptr
}

// pcap_pkthdr on Windows: struct timeval uses 32-bit longs.
struct PcapPktHdr {
	sec    i32
	usec   i32
	caplen u32
	len    u32
}

struct BpfProgram {
	len   u32
	insns voidptr
}

struct SockAddrIn {
mut:
	family u16
	port   u16
	addr   [4]u8
	zero   [8]u8
}

type FnFindAllDevs = fn (voidptr, &char) int

type FnFreeAllDevs = fn (voidptr)

type FnOpenLive = fn (&char, int, int, int, &char) voidptr

type FnDatalink = fn (voidptr) int

type FnNextEx = fn (voidptr, voidptr, voidptr) int

type FnClose = fn (voidptr)

type FnCompile = fn (voidptr, voidptr, &char, int, u32) int

type FnSetFilter = fn (voidptr, voidptr) int

type FnFreeCode = fn (voidptr)

type FnGetErr = fn (voidptr) &char

struct Npcap {
	findalldevs FnFindAllDevs = unsafe { nil }
	freealldevs FnFreeAllDevs = unsafe { nil }
	open_live   FnOpenLive    = unsafe { nil }
	datalink    FnDatalink    = unsafe { nil }
	next_ex     FnNextEx      = unsafe { nil }
	close       FnClose       = unsafe { nil }
	compile     FnCompile     = unsafe { nil }
	setfilter   FnSetFilter   = unsafe { nil }
	freecode    FnFreeCode    = unsafe { nil }
	geterr      FnGetErr      = unsafe { nil }
}

struct Device {
	name        string
	description string
	ipv4        []string
}

fn (d Device) label() string {
	ip := if d.ipv4.len > 0 { d.ipv4.join(', ') } else { 'no IPv4' }
	desc := if d.description != '' { d.description } else { d.name }
	return '${desc} (${ip})'
}

fn npcap_dll_path() string {
	mut buf := []u16{len: 260}
	n := C.GetSystemDirectoryW(buf.data, u32(buf.len))
	return unsafe { string_from_wide2(buf.data, int(n)) } + '\\Npcap\\wpcap.dll'
}

fn load_npcap() !Npcap {
	path := npcap_dll_path()
	// Altered search path lets wpcap.dll find Packet.dll next to it.
	h := C.LoadLibraryExW(path.to_wide(), unsafe { nil }, load_with_altered_search_path)
	if h == unsafe { nil } {
		return error('Npcap not found (${path})')
	}
	sym := fn [h] (name string) !voidptr {
		p := C.GetProcAddress(h, &u8(name.str))
		if p == unsafe { nil } {
			return error('wpcap.dll is missing ${name}')
		}
		return p
	}
	return Npcap{
		findalldevs: FnFindAllDevs(sym('pcap_findalldevs')!)
		freealldevs: FnFreeAllDevs(sym('pcap_freealldevs')!)
		open_live:   FnOpenLive(sym('pcap_open_live')!)
		datalink:    FnDatalink(sym('pcap_datalink')!)
		next_ex:     FnNextEx(sym('pcap_next_ex')!)
		close:       FnClose(sym('pcap_close')!)
		compile:     FnCompile(sym('pcap_compile')!)
		setfilter:   FnSetFilter(sym('pcap_setfilter')!)
		freecode:    FnFreeCode(sym('pcap_freecode')!)
		geterr:      FnGetErr(sym('pcap_geterr')!)
	}
}

fn (api Npcap) devices() ![]Device {
	mut errbuf := []u8{len: 512}
	mut first := unsafe { &PcapIf(nil) }
	if api.findalldevs(voidptr(&first), &char(errbuf.data)) != 0 {
		return error(unsafe { cstring_to_vstring(&char(errbuf.data)) })
	}
	defer {
		api.freealldevs(first)
	}
	mut out := []Device{}
	mut cur := first
	for cur != unsafe { nil } {
		mut ips := []string{}
		mut a := cur.addresses
		for a != unsafe { nil } {
			if a.addr != unsafe { nil } {
				sa := unsafe { &SockAddrIn(a.addr) }
				if sa.family == 2 {
					ips << '${sa.addr[0]}.${sa.addr[1]}.${sa.addr[2]}.${sa.addr[3]}'
				}
			}
			a = a.next
		}
		out << Device{
			name:        unsafe { cstring_to_vstring(cur.name) }
			description: if cur.description != unsafe { nil } {
				unsafe { cstring_to_vstring(cur.description) }
			} else {
				''
			}
			ipv4:        ips
		}
		cur = cur.next
	}
	return out
}

type FnWsaStartup = fn (u16, voidptr) int

type FnSocket = fn (int, int, int) usize

type FnConnect = fn (usize, voidptr, int) int

type FnGetSockName = fn (usize, voidptr, &int) int

type FnCloseSocket = fn (usize) int

// default_route_ip asks Windows which local IPv4 address would reach the
// internet. A UDP connect selects a route without sending any packet.
fn default_route_ip() ?string {
	startup := proc_address('ws2_32.dll', 'WSAStartup')
	sock_fn := proc_address('ws2_32.dll', 'socket')
	connect_fn := proc_address('ws2_32.dll', 'connect')
	name_fn := proc_address('ws2_32.dll', 'getsockname')
	close_fn := proc_address('ws2_32.dll', 'closesocket')
	if startup == unsafe { nil } || sock_fn == unsafe { nil } || connect_fn == unsafe { nil }
		|| name_fn == unsafe { nil } || close_fn == unsafe { nil } {
		return none
	}
	mut wsa := []u8{len: 512}
	call_wsastartup := FnWsaStartup(startup)
	if call_wsastartup(0x0202, wsa.data) != 0 {
		return none
	}
	call_socket := FnSocket(sock_fn)
	s := call_socket(2, 2, 17)
	if s == ~usize(0) {
		return none
	}
	defer {
		call_closesocket := FnCloseSocket(close_fn)
		_ := call_closesocket(s)
	}
	mut remote := SockAddrIn{
		family: 2
		port:   0x5000 // 80 in network byte order
		addr:   [u8(1), 1, 1, 1]!
	}
	call_connect := FnConnect(connect_fn)
	if call_connect(s, &remote, int(sizeof(SockAddrIn))) != 0 {
		return none
	}
	mut local := SockAddrIn{}
	mut size := int(sizeof(SockAddrIn))
	call_getsockname := FnGetSockName(name_fn)
	if call_getsockname(s, &local, &size) != 0 {
		return none
	}
	return '${local.addr[0]}.${local.addr[1]}.${local.addr[2]}.${local.addr[3]}'
}

// preferred_device picks the adapter that carries the default route.
fn preferred_device(devices []Device) int {
	if ip := default_route_ip() {
		for i, d in devices {
			if ip in d.ipv4 {
				return i
			}
		}
	}
	for i, d in devices {
		if d.ipv4.any(it != '127.0.0.1' && !it.starts_with('169.254.')) {
			return i
		}
	}
	return if devices.len > 0 { 0 } else { -1 }
}

enum WorkerEventKind {
	status
	failed
	open_failed
	server
	decoded // `ev` holds a decoder event
	stopped
}

struct WorkerEvent {
	kind WorkerEventKind
	text string
	ev   proto.Event
}

fn (e WorkerEvent) is_player_position() bool {
	return e.kind == .decoded && e.ev.kind == .player
}

// Capture owns the worker thread state shared with the GUI thread. All
// fields below `mu` are guarded by it.
@[heap]
struct Capture {
	notify_hwnd voidptr
	notify_msg  u32
mut:
	mu           &sync.Mutex = sync.new_mutex()
	events       []WorkerEvent
	posted       bool
	stop         bool
	reset_player bool
	running      bool
}

fn (mut c Capture) push(ev WorkerEvent) {
	c.mu.lock()
	// Position updates arrive many times per second; keep only the newest
	// pending one so the GUI queue cannot grow without bound.
	if ev.is_player_position() && c.events.len > 0 && c.events.last().is_player_position() {
		c.events[c.events.len - 1] = ev
	} else {
		c.events << ev
	}
	need_post := !c.posted
	c.posted = true
	c.mu.unlock()
	if need_post {
		C.PostMessageW(c.notify_hwnd, c.notify_msg, 0, 0)
	}
}

fn (mut c Capture) drain() []WorkerEvent {
	c.mu.lock()
	events := c.events
	c.events = []WorkerEvent{}
	c.posted = false
	c.mu.unlock()
	return events
}

fn (mut c Capture) is_running() bool {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	return c.running
}

fn (mut c Capture) start(api Npcap, device Device, port int) bool {
	c.mu.lock()
	if c.running {
		c.mu.unlock()
		return false
	}
	c.running = true
	c.stop = false
	c.mu.unlock()
	spawn capture_worker(mut c, api, device, port)
	return true
}

fn (mut c Capture) request_stop() {
	c.mu.lock()
	c.stop = true
	c.mu.unlock()
}

fn (mut c Capture) request_player_reset() {
	c.mu.lock()
	c.reset_player = true
	c.mu.unlock()
}

// poll_flags returns (stop requested, player reset requested) and clears
// the one-shot reset flag.
fn (mut c Capture) poll_flags() (bool, bool) {
	c.mu.lock()
	stop, reset := c.stop, c.reset_player
	c.reset_player = false
	c.mu.unlock()
	return stop, reset
}

fn (mut c Capture) finish(reason string) {
	c.mu.lock()
	c.running = false
	c.mu.unlock()
	c.push(WorkerEvent{
		kind: .stopped
		text: reason
	})
}

const supported_linktypes = [proto.dlt_null, proto.dlt_en10mb, proto.dlt_raw, proto.linktype_raw]

fn capture_worker(mut c Capture, api Npcap, device Device, port int) {
	mut errbuf := []u8{len: 512}
	handle := api.open_live(&char(device.name.str), 65535, 0, 200, &char(errbuf.data))
	if handle == unsafe { nil } {
		msg := unsafe { cstring_to_vstring(&char(errbuf.data)) }
		c.push(WorkerEvent{
			kind: .open_failed
			text: 'Cannot open adapter: ${msg.trim_right('. ')}'
		})
		c.finish('open failed')
		return
	}
	defer {
		api.close(handle)
	}
	linktype := api.datalink(handle)
	if linktype !in supported_linktypes {
		c.push(WorkerEvent{
			kind: .failed
			text: 'Unsupported adapter link type ${linktype}; choose another adapter.'
		})
		c.finish('unsupported link type')
		return
	}
	// The kernel filter only reduces load; game_packet re-checks the port.
	filter := 'tcp src port ${port}'
	mut prog := BpfProgram{}
	if api.compile(handle, &prog, &char(filter.str), 1, 0xffffffff) == 0 {
		if api.setfilter(handle, &prog) != 0 {
			c.push(WorkerEvent{
				kind: .status
				text: 'Kernel filter not applied (${unsafe { cstring_to_vstring(api.geterr(handle)) }}); using software filter.'
			})
		}
		api.freecode(&prog)
	}
	c.push(WorkerEvent{
		kind: .status
		text: 'Capturing on ${device.label()}. Waiting for game traffic on port ${port}...'
	})
	mut sink := PacketSink{
		port: port
	}
	mut hdr_ptr := unsafe { nil }
	mut data_ptr := unsafe { nil }
	for {
		stop, reset := c.poll_flags()
		if stop {
			break
		}
		if reset {
			sink.dec.reset_player()
		}
		rc := api.next_ex(handle, voidptr(&hdr_ptr), voidptr(&data_ptr))
		if rc == 0 {
			continue
		}
		if rc < 0 {
			err := unsafe { cstring_to_vstring(api.geterr(handle)) }
			c.push(WorkerEvent{
				kind: .failed
				text: 'Capture stopped (status ${rc}): ${err}'
			})
			c.finish('capture error')
			return
		}
		hdr := unsafe { &PcapPktHdr(hdr_ptr) }
		frame := unsafe { (&u8(data_ptr)).vbytes(int(hdr.caplen)) }
		sink.handle(mut c, frame, linktype, f64(hdr.sec) + f64(hdr.usec) / 1_000_000.0)
	}
	c.finish('stopped')
}

// PacketSink turns captured frames into worker events; shared by live
// capture and file replay.
struct PacketSink {
	port int
mut:
	dec     proto.Decoder
	streams map[string]&proto.Stream
}

fn (mut sink PacketSink) handle(mut c Capture, frame []u8, linktype int, timestamp f64) {
	pkt := proto.game_packet(frame, linktype, sink.port) or { return }
	if pkt.payload.len == 0 {
		return
	}
	key := '${pkt.server}:${pkt.client_port}'
	mut stream := sink.streams[key] or {
		s := &proto.Stream{}
		sink.streams[key] = s
		c.push(WorkerEvent{
			kind: .server
			text: '${pkt.server}:${sink.port} (client port ${pkt.client_port})'
		})
		s
	}
	stream.feed(pkt.seq, pkt.payload, timestamp, mut sink.dec)
	for ev in sink.dec.take_events() {
		c.push(WorkerEvent{
			kind: .decoded
			ev:   ev
		})
	}
}

fn (mut c Capture) start_replay(path string, port int) bool {
	c.mu.lock()
	if c.running {
		c.mu.unlock()
		return false
	}
	c.running = true
	c.stop = false
	c.mu.unlock()
	spawn replay_worker(mut c, path, port)
	return true
}

// replay_worker plays a capture file in real time, with timestamps moved to
// the present so ages and distances behave as in a live session.
fn replay_worker(mut c Capture, path string, port int) {
	frames := proto.read_capture_file(path) or {
		c.push(WorkerEvent{
			kind: .failed
			text: 'Cannot read capture: ${err}'
		})
		c.finish('replay failed')
		return
	}
	if frames.len == 0 {
		c.finish('empty capture')
		return
	}
	c.push(WorkerEvent{
		kind: .status
		text: 'Replaying ${os.file_name(path)} (${frames.len} frames) in real time...'
	})
	mut sink := PacketSink{
		port: port
	}
	start := now_seconds()
	first := frames[0].timestamp
	for f in frames {
		stop, reset := c.poll_flags()
		if stop {
			break
		}
		if reset {
			sink.dec.reset_player()
		}
		due := start + (f.timestamp - first)
		for now_seconds() < due {
			if c.stop_requested() {
				c.finish('replay stopped')
				return
			}
			time.sleep(20 * time.millisecond)
		}
		sink.handle(mut c, f.data, f.linktype, due)
	}
	c.push(WorkerEvent{
		kind: .status
		text: 'Replay of ${os.file_name(path)} finished.'
	})
	c.finish('replay finished')
}

fn (mut c Capture) stop_requested() bool {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	return c.stop
}
