module wire

fn test_accept_key_matches_the_rfc_example() {
	// RFC 6455, section 1.3.
	assert accept_key('dGhlIHNhbXBsZSBub25jZQ==') == 's3pPLMBiTxaQ9kYGzzhZRbK+xOo='
	ok := 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nsec-websocket-accept:  s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n'
	assert handshake_ok(ok, 'dGhlIHNhbXBsZSBub25jZQ==')
	assert !handshake_ok(ok, 'another key')
	assert !handshake_ok('HTTP/1.1 403 Forbidden\r\n', 'dGhlIHNhbXBsZSBub25jZQ==')
}

fn server_frame(first u8, payload []u8) []u8 {
	mut out := [first]
	if payload.len < 126 {
		out << u8(payload.len)
	} else if payload.len <= 0xffff {
		out << [u8(126), u8(payload.len >> 8), u8(payload.len)]
	} else {
		out << [u8(127), 0, 0, 0, 0, u8(payload.len >> 24), u8(payload.len >> 16),
			u8(payload.len >> 8), u8(payload.len)]
	}
	out << payload
	return out
}

fn must_next(mut r FrameReader) ?Frame {
	f := r.next()
	assert r.error == ''
	return f
}

fn test_reader_handles_split_fragmented_and_control_frames() {
	mut r := FrameReader{}
	hello := server_frame(0x81, 'hello'.bytes())
	r.feed(hello[..3])
	assert must_next(mut r) == none
	r.feed(hello[3..])
	f := must_next(mut r) or { panic('expected a frame') }
	assert f.opcode == op_text && f.payload.bytestr() == 'hello'
	assert must_next(mut r) == none

	// "ab" + ping + "cd" as one fragmented text message with a ping in between.
	mut data := server_frame(0x01, 'ab'.bytes())
	data << server_frame(0x89, 'p'.bytes())
	data << server_frame(0x80, 'cd'.bytes())
	r.feed(data)
	ping := must_next(mut r) or { panic('expected the ping') }
	assert ping.opcode == op_ping && ping.payload.bytestr() == 'p'
	whole := must_next(mut r) or { panic('expected the message') }
	assert whole.opcode == op_text && whole.payload.bytestr() == 'abcd'

	for n in [125, 126, 65535, 65536, 70000] {
		big := []u8{len: n, init: u8(index)}
		r.feed(server_frame(0x82, big))
		got := must_next(mut r) or { panic('expected ${n} bytes') }
		assert got.opcode == op_binary && got.payload == big
	}
	r.feed(server_frame(0x80, 'x'.bytes()))
	assert r.next() == none
	assert r.error != '', 'a continuation without a start must fail'
}

fn test_client_frames_are_masked_and_read_back() {
	mask := [u8(1), 2, 3, 4]!
	for n in [0, 5, 125, 126, 300, 70000] {
		payload := []u8{len: n, init: u8(index * 7)}
		frame := encode_frame(op_text, payload, mask)
		assert frame[0] == 0x81
		assert frame[1] & 0x80 != 0
		if n > 4 {
			assert frame[frame.len - n..] != payload, 'the payload must be masked'
		}
		mut r := FrameReader{}
		r.feed(frame)
		got := must_next(mut r) or { panic('expected a frame') }
		assert got.payload == payload
	}
}

fn test_backend_addresses() {
	plain := parse_endpoint('127.0.0.1:8081')?
	assert plain == Endpoint{'127.0.0.1', 8081, false}
	assert plain.host_header() == '127.0.0.1:8081'
	// a name alone is a site behind HTTPS
	site := parse_endpoint(' cube.example.org ')?
	assert site == Endpoint{'cube.example.org', 443, true}
	assert site.host_header() == 'cube.example.org'
	assert site.str() == 'wss://cube.example.org'
	assert parse_endpoint('https://cube.example.org/')? == site
	assert parse_endpoint('wss://cube.example.org/ws/client')? == site
	assert parse_endpoint('cube.example.org:443')? == site
	assert parse_endpoint('wss://cube.example.org:8443')? == Endpoint{'cube.example.org', 8443, true}
	assert parse_endpoint('http://cube.example.org')? == Endpoint{'cube.example.org', 80, false}
	assert parse_endpoint('ws://10.0.0.5:8081')?.str() == 'ws://10.0.0.5:8081'
	for bad in ['', 'ftp://host', 'host:', 'host:0', 'host:port', 'host:70000', ':8081', 'a b:80'] {
		assert parse_endpoint(bad) == none, bad
	}
}

fn test_sealed_messages() {
	mut client := new_sealer(false)
	mut server := new_sealer(true)
	text := 'me,2304,1110,-169762,-95786,34292,Tester'
	sealed := client.seal(text)
	assert sealed.len == text.len + seal_overhead
	assert !sealed.bytestr().contains('Tester')
	assert open(sealed, false)? == text
	// the same text never looks the same twice
	again := client.seal(text)
	assert again != sealed
	assert open(again, false)? == text
	// each side only takes what the other side made
	assert open(sealed, true) == none
	back := server.seal('kinds\no,1301199,Cubes,Cube')
	assert open(back, true)? == 'kinds\no,1301199,Cubes,Cube'
	assert open(back, false) == none
	// a changed, cut or foreign message is not one
	for i in [0, 5, 12, sealed.len - 1] {
		mut bad := sealed.clone()
		bad[i] ^= 0x01
		assert open(bad, false) == none
	}
	assert open(sealed[..sealed.len - 1], false) == none
	assert open(text.bytes(), false) == none
	assert open([]u8{}, false) == none
	assert open(client.seal(''), false)? == ''
}

fn test_client_messages_in_the_text_format() {
	seen := ClientMsg{
		t:      t_seen
		server: 2304
		map:    1110
		x:      -134043.7
		y:      -54024.8
		z:      28616.0
		cat:    category_object
		tpl:    1301199
		id:     61967
		age:    63.5
	}
	assert seen.encode() == 'seen,2304,1110,o,1301199,61967,-134043.7,-54024.8,28616.0,63.5'
	assert (decode_client(seen.encode()) or { panic('seen') }) == seen
	taken := ClientMsg{
		...seen
		t:    t_taken
		cat:  category_npc
		age:  -1
		mine: true
	}
	assert taken.encode() == 'taken,2304,1110,n,1301199,61967,-134043.7,-54024.8,28616.0,1'
	assert (decode_client(taken.encode()) or { panic('taken') }) == taken
	gone := ClientMsg{
		...taken
		t:    t_gone
		mine: false
	}
	assert (decode_client(gone.encode()) or { panic('gone') }) == gone
	me := ClientMsg{
		t:      t_me
		server: 2304
		map:    1110
		x:      1.5
		y:      -2.5
		z:      3
		name:   'ChanterMain'
	}
	assert me.encode() == 'me,2304,1110,1.5,-2.5,3.0,ChanterMain'
	assert (decode_client(me.encode()) or { panic('me') }) == me
	hello := ClientMsg{
		t:       t_hello
		ver:     protocol_version
		install: '3f9a1c0e5b7d2468'
		key:     'a key, with a comma'
	}
	assert hello.encode() == 'hello,3,3f9a1c0e5b7d2468,a key, with a comma'
	assert (decode_client(hello.encode()) or { panic('hello') }) == hello
	assert decode_client('hello,1,old key') == none
	assert (decode_client('ping') or { panic('ping') }).t == t_ping
	for bad in ['', 'nonsense', 'me,1,2', 'seen,1,2,o,3,4,5,6,7', 'gone,1,2,o,3,4,5,6,7,8', 'hello'] {
		assert decode_client(bad) == none, bad
	}
}

fn test_server_messages_in_the_text_format() {
	kinds := ServerMsg{
		t:     t_kinds
		kinds: [KindInfo{category_object, 1301199, 'Cube', 'Cubes'},
			KindInfo{category_npc, 2400031, 'Wolf, grey', 'Monsters'}]
	}
	text := kinds.encode()
	assert text == 'kinds\no,1301199,Cubes,Cube\nn,2400031,Monsters,Wolf, grey'
	assert (decode_server(text) or { panic('kinds') }) == kinds
	// A group name cannot break the line: its commas become spaces.
	odd := ServerMsg{
		t:     t_kinds
		kinds: [KindInfo{category_object, 5, 'A\nB', 'x,y'}]
	}
	assert (decode_server(odd.encode()) or { panic('odd') }).kinds == [
		KindInfo{category_object, 5, 'A B', 'x y'},
	]
	none_yet := ServerMsg{
		t: t_kinds
	}
	assert (decode_server(none_yet.encode()) or { panic('empty') }) == none_yet
	err := ServerMsg{
		t:   t_error
		msg: 'wrong client key'
	}
	assert err.encode() == 'error,wrong client key'
	assert (decode_server(err.encode()) or { panic('error') }) == err
	assert decode_server('nonsense') == none
	assert kind_key(category_npc, 2400031) == 'npc:2400031'
}

fn test_near_items_in_the_text_format() {
	near := ClientMsg{
		t:     t_near
		key:   'r7'
		items: [
			NearItem{category_object, 1300011, 24135, -133811.3, -55679.0, 28572.0, 2951},
			NearItem{category_npc, 2400031, 47163, 1.5, 2.0, 3.0, -1},
		]
	}
	text := near.encode()
	assert text == 'near,r7\no,1300011,24135,-133811.3,-55679.0,28572.0,2951\nn,2400031,47163,1.5,2.0,3.0,-1'
	assert (decode_client(text) or { panic('near') }) == near
	empty := ClientMsg{
		t:   t_near
		key: 'r8'
	}
	assert (decode_client(empty.encode()) or { panic('empty') }) == empty
	ask := ServerMsg{
		t:   t_nearby
		msg: 'r7'
	}
	assert ask.encode() == 'nearby,r7'
	assert (decode_server('nearby,r7') or { panic('nearby') }) == ask
}

fn test_the_area_around_a_client_in_the_text_format() {
	watch := ClientMsg{
		t:     t_watch
		watch: true
	}
	assert watch.encode() == 'watch,1'
	back := decode_client(watch.encode()) or { panic('watch') }
	assert back.t == t_watch && back.watch
	off := decode_client('watch,0') or { panic('watch off') }
	assert !off.watch
	assert decode_client('watch') == none

	spots := ServerMsg{
		t:     t_spots
		now:   1760000000
		map:   20
		spots: [
			AreaSpot{category_object, 1301199, 53449.4, -54074.2, 20402.0, true, 0, 7, 0xf5a623},
			AreaSpot{category_npc, 2400801, -12.0, 34.0, 5.0, false, 1760000600, 1, 0x00ff80},
		]
	}
	text := spots.encode()
	assert text == 'spots,1760000000,20\no,1301199,53449,-54074,20402,1,0,7,f5a623\nn,2400801,-12,34,5,0,1760000600,1,00ff80'
	got := decode_server(text) or { panic('spots') }
	assert got.t == t_spots && got.now == 1760000000 && got.map == 20 && got.spots.len == 2
	assert got.spots[0].present && got.spots[0].tpl == 1301199 && got.spots[0].color == 0xf5a623
	assert got.spots[0].x == 53449 && got.spots[0].y == -54074 && got.spots[0].spawns == 7
	assert !got.spots[1].present && got.spots[1].expected == 1760000600
		&& got.spots[1].cat == category_npc
	empty := decode_server('spots,5,1110') or { panic('no spots') }
	assert empty.t == t_spots && empty.spots.len == 0 && empty.map == 1110

	people := ServerMsg{
		t:      t_people
		now:    1760000001
		people: [AreaPerson{'Ann', 10.4, -20.6, 30.0}, AreaPerson{'With, comma', 1, 2, 3}]
	}
	ptext := people.encode()
	assert ptext == 'people,1760000001\n10,-21,30,Ann\n1,2,3,With, comma'
	pgot := decode_server(ptext) or { panic('people') }
	assert pgot.t == t_people && pgot.people.len == 2
	assert pgot.people[0].name == 'Ann' && pgot.people[0].y == -21
	assert pgot.people[1].name == 'With, comma' && pgot.people[1].z == 3
	nobody := decode_server('people,7') or { panic('nobody') }
	assert nobody.t == t_people && nobody.people.len == 0
	// the older messages are read as before
	err := decode_server('error,spots, people and more') or { panic('error') }
	assert err.t == t_error && err.msg == 'spots, people and more'
}
