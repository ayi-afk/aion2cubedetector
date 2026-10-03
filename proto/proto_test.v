module proto

import encoding.binary
import math

fn f32_bytes(v f32) []u8 {
	mut b := []u8{len: 4}
	binary.little_endian_put_u32(mut b, math.f32_bits(v))
	return b
}

fn vec_bytes(x f32, y f32, z f32) []u8 {
	mut out := f32_bytes(x)
	out << f32_bytes(y)
	out << f32_bytes(z)
	return out
}

fn encode_varint(value u64) []u8 {
	mut out := []u8{}
	mut v := value
	for {
		b := u8(v & 0x7f)
		v >>= 7
		if v == 0 {
			out << b
			return out
		}
		out << (b | 0x80)
	}
	return out
}

// frame prepends the size varint; the wire size is message length + 3.
fn frame(body []u8) []u8 {
	mut size_len := 1
	for {
		enc := encode_varint(u64(body.len + size_len + 3))
		if enc.len == size_len {
			mut out := enc.clone()
			out << body
			return out
		}
		size_len = enc.len
	}
	return []u8{}
}

fn cube_message(obj u64, x f32, y f32, z f32) []u8 {
	mut body := [u8(0x34), 0x36]
	body << encode_varint(obj)
	body << [u8(0), 0]
	mut tpl := []u8{len: 4}
	binary.little_endian_put_u32(mut tpl, cube_template)
	body << tpl
	body << vec_bytes(x, y, z)
	return frame(body)
}

fn position_message(op0 u8, entity u64, x f32, y f32, z f32) []u8 {
	mut body := [op0, 0x38]
	body << encode_varint(entity)
	body << [u8(0xaa), 0xbb, 0xcc]
	body << encode_varint(entity)
	body << if op0 == 0x2a { [u8(0x01), 0x00] } else { [u8(0x01), 0x02] }
	body << vec_bytes(x, y, z)
	return frame(body)
}

// literal_lz4 encodes data as one literal-only LZ4 sequence.
fn literal_lz4(data []u8) []u8 {
	mut out := []u8{}
	if data.len < 15 {
		out << u8(data.len << 4)
	} else {
		out << u8(0xf0)
		mut rest := data.len - 15
		for rest >= 255 {
			out << u8(255)
			rest -= 255
		}
		out << u8(rest)
	}
	out << data
	return out
}

fn bundle(inner []u8) []u8 {
	compressed := literal_lz4(inner)
	mut payload := [u8(0xff), 0xff]
	mut n := []u8{len: 4}
	binary.little_endian_put_u32(mut n, u32(inner.len))
	payload << n
	payload << compressed
	// Bundle frames are one byte longer than the size varint states.
	enc := encode_varint(u64(payload.len + 1 + 3 - 1))
	assert enc.len == 1
	mut out := enc.clone()
	out << payload
	return out
}

fn test_varint() {
	assert read_varint([u8(0x05)], 0) == Varint{.ok, 5, 1}
	assert read_varint([u8(0xac), 0x02], 0) == Varint{.ok, 300, 2}
	assert read_varint([u8(0xac)], 0).status == .incomplete
	assert read_varint([u8(0xff), 0xff, 0xff, 0xff, 0xff, 0x01], 0).status == .invalid
}

fn test_lz4_with_match() {
	// "abc" literal then match offset 3 length 6 -> "abcabcabc"
	src := [u8(0x32), `a`, `b`, `c`, 0x03, 0x00]
	out := lz4_block(src, 9) or { panic(err) }
	assert out.bytestr() == 'abcabcabc'
	if _ := lz4_block(src, 10) {
		assert false, 'length mismatch must fail'
	}
	if _ := lz4_block([u8(0x10), `a`, 0x05, 0x00], 10) {
		assert false, 'offset beyond output must fail'
	}
}

fn test_cube_spawn_reported_once() {
	mut dec := Decoder{}
	mut s := Stream{}
	mut data := cube_message(4242, 100.5, -200.25, 30.0)
	data << cube_message(4242, 1, 2, 3)
	s.feed(1000, data, 1.0, mut dec)
	events := dec.take_events()
	assert events.len == 2
	assert events[0].kind == .cube
	assert events[0].id == 4242
	assert events[0].pos == Vec3{100.5, -200.25, 30.0}
	// A repeated spawn of the same object only reports it as visible again.
	assert events[1].kind == .cube_visible
	assert events[1].pos == Vec3{1, 2, 3}
}

// Messages copied from real captures (cube2/cube3, local player 3273).
const real_self_position = '302a38c9190111960602e1f505ffffffffffffffff8075d52abb030000c919010073daa6c7f0e2b1c71bb8e846'
const real_self_entity_position = '181a37c919000046941cc774bf8cc7654ea3469f34'
const real_other_entity_position = '191a378bfc050007cbdc98c7d516adc7d9a3ef465002'
const real_cube_spawn = '3d3436da9e040400cfda1300027f89c7afedb5c7003cfc46000000000030de42010101d46859faa001000000000000000000004517518e070000'
const real_other_spawn = '3d3436d4fa01040026d61300d9049dc78dc7abc700aee2460000000000706943010101c0901ff6a00100000000000000000000b8654b10070000'
const real_open_start = '0c3836da9e04ad4e01'
const real_open_done = '133a36da9e04ad4e0100000023c59a25'
const real_despawn = '0c3536da9e04040300'
const real_other_despawn = '0c3536d69302010100'

fn hex_bytes(s string) []u8 {
	mut out := []u8{}
	for i := 0; i < s.len; i += 2 {
		out << u8(s[i..i + 2].parse_uint(16, 8) or { panic(err) })
	}
	return out
}

fn close_to(a f64, b f64) bool {
	return math.abs(a - b) < 0.1
}

fn test_real_capture_messages() {
	mut data := []u8{}
	for m in [real_self_position, real_other_spawn, real_cube_spawn, real_other_entity_position,
		real_self_entity_position, real_open_start, real_open_done, real_other_despawn, real_despawn] {
		data << hex_bytes(m)
	}
	mut dec := Decoder{}
	mut s := Stream{}
	s.feed(1, data, 10.0, mut dec)
	ev := dec.take_events()
	assert ev.map(it.kind) == [EventKind.player_detected, .player, .cube, .player, .cube_opening,
		.cube_opened, .cube_removed]
	assert ev[0].id == 3273
	assert close_to(ev[1].pos.x, -85428.9) && close_to(ev[1].pos.y, -91077.9)
	assert ev[2].id == 69466
	assert close_to(ev[2].pos.x, -70398.0) && close_to(ev[2].pos.y, -93147.4)
		&& close_to(ev[2].pos.z, 32286.0)
	assert close_to(ev[3].pos.x, -40084.3) && close_to(ev[3].pos.y, -72062.9)
	assert ev[4].id == 69466 && ev[4].actor == 10029
	assert ev[5].id == 69466 && ev[5].actor == 10029
	assert ev[6].id == 69466 && ev[6].reason == removed_destroyed
}

fn test_other_template_ignored() {
	mut msg := cube_message(7, 1, 2, 3)
	msg[6] ^= 0xff // corrupt template
	mut dec := Decoder{}
	mut s := Stream{}
	s.feed(1, msg, 1.0, mut dec)
	assert dec.take_events().len == 0
}

fn test_player_detection_and_filtering() {
	mut dec := Decoder{}
	mut s := Stream{}
	mut data := position_message(0x2a, 900, 1, 2, 3)
	data << position_message(0x2b, 900, 4, 5, 6)
	data << position_message(0x2a, 901, 7, 8, 9) // another entity
	s.feed(5, data, 2.0, mut dec)
	events := dec.take_events()
	assert events.len == 3
	assert events[0].kind == .player_detected
	assert events[0].id == 900
	assert events[1].pos == Vec3{1, 2, 3}
	assert events[2].pos == Vec3{4, 5, 6}
	assert dec.self_id or { 0 } == 900
}

fn test_new_entity_id_after_reset() {
	// Entering an instance gives the character a new id: it is ignored until
	// player detection is reset (the app does that once the fix is stale).
	mut dec := Decoder{}
	mut s := Stream{}
	s.feed(5, position_message(0x2a, 900, 1, 2, 3), 2.0, mut dec)
	dec.take_events()
	mut seq := u32(5 + position_message(0x2a, 900, 1, 2, 3).len)
	instance := position_message(0x2a, 1234, 7, 8, 9)
	s.feed(seq, instance, 3.0, mut dec)
	assert dec.take_events().len == 0
	seq += u32(instance.len)
	dec.reset_player()
	s.feed(seq, position_message(0x2b, 1234, 10, 11, 12), 4.0, mut dec)
	events := dec.take_events()
	assert events.len == 2
	assert events[0].kind == .player_detected
	assert events[0].id == 1234
	assert events[1].pos == Vec3{10, 11, 12}
}

fn test_wrong_discriminator_ignored() {
	mut msg := position_message(0x2b, 900, 1, 2, 3)
	msg[msg.len - 13] = 0x00 // 01 02 -> 01 00 does not match op 0x2b
	mut dec := Decoder{}
	mut s := Stream{}
	s.feed(5, msg, 2.0, mut dec)
	assert dec.take_events().len == 0
}

fn test_reassembly_out_of_order_and_split() {
	data := cube_message(1, 1, 1, 1)
	mut dec := Decoder{}
	mut s := Stream{}
	base := u32(0xffff_fff0) // crosses the 32-bit sequence wrap
	s.feed(base, data[..4], 1.0, mut dec)
	s.feed(base + 10, data[10..], 1.1, mut dec)
	assert dec.take_events().len == 0
	s.feed(base + 4, data[4..10], 1.2, mut dec)
	events := dec.take_events()
	assert events.len == 1
	assert events[0].id == 1
}

fn test_retransmission_overlap() {
	data := cube_message(2, 1, 1, 1)
	mut dec := Decoder{}
	mut s := Stream{}
	s.feed(100, data[..8], 1.0, mut dec)
	s.feed(100, data, 1.1, mut dec) // retransmit covering old + new bytes
	assert dec.take_events().len == 1
}

fn test_gap_resync_after_timeout() {
	mut dec := Decoder{}
	mut s := Stream{}
	first := cube_message(10, 1, 1, 1)
	s.feed(0, first, 1.0, mut dec)
	// Bytes at [first.len, 5000) are lost; later frames arrive continuously.
	second := cube_message(11, 2, 2, 2)
	s.feed(5000, second, 1.5, mut dec)
	third := cube_message(12, 3, 3, 3)
	s.feed(u32(5000 + second.len), third, 2.6, mut dec)
	ids := dec.take_events().map(it.id)
	assert ids == [u64(10), 12]
}

fn test_bundle_decoded() {
	mut inner := cube_message(77, 5, 6, 7)
	inner << position_message(0x2a, 3, 8, 9, 10)
	mut dec := Decoder{}
	mut s := Stream{}
	s.feed(0, bundle(inner), 1.0, mut dec)
	kinds := dec.take_events().map(it.kind)
	assert kinds == [EventKind.cube, .player_detected, .player]
}

fn test_nop_and_padding_skipped() {
	mut dec := Decoder{}
	mut s := Stream{}
	s.feed(0, nop_frame, 1.0, mut dec)
	mut data := [u8(0), 0]
	data << cube_message(5, 1, 1, 1)
	s.feed(0, data, 1.0, mut dec)
	assert dec.take_events().len == 1
}

fn ipv4_tcp(sport u16, dport u16, seq u32, payload []u8) []u8 {
	mut ip := []u8{len: 20}
	ip[0] = 0x45
	binary.big_endian_put_u16_at(mut ip, u16(40 + payload.len), 2)
	ip[9] = 6
	ip[12], ip[13], ip[14], ip[15] = 10, 1, 2, 3
	mut tcp := []u8{len: 20}
	binary.big_endian_put_u16_at(mut tcp, sport, 0)
	binary.big_endian_put_u16_at(mut tcp, dport, 2)
	binary.big_endian_put_u32_at(mut tcp, seq, 4)
	tcp[12] = 0x50
	mut out := ip.clone()
	out << tcp
	out << payload
	return out
}

fn test_game_packet_ethernet_and_raw() {
	payload := [u8(1), 2, 3]
	ip := ipv4_tcp(13328, 50000, 77, payload)
	mut eth := []u8{len: 12}
	eth << [u8(0x08), 0x00]
	eth << ip
	eth << []u8{len: 6} // Ethernet padding
	p := game_packet(eth, dlt_en10mb, 13328) or { panic('expected packet') }
	assert p.server == '10.1.2.3'
	assert p.client_port == 50000
	assert p.seq == 77
	assert p.payload == payload
	raw := game_packet(ip, dlt_raw, 13328) or { panic('expected packet') }
	assert raw.payload == payload
	assert game_packet(ip, dlt_raw, 1234) == none
}
