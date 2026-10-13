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

// frame prepends the size varint: the length of opcode and data plus 4.
fn frame(body []u8) []u8 {
	mut out := encode_varint(u64(body.len + 4))
	out << body
	return out
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

// effect_message builds a status effect (2a 38) or its refresh (2b 38) put
// on `target` at x, y, z; skill 0 stands for an effect without a skill.
fn effect_message(op0 u8, caster u64, target u64, skill u32, flag u8, x f32, y f32, z f32) []u8 {
	mut body := [op0, 0x38]
	body << encode_varint(caster)
	if op0 == 0x2a {
		body << u8(0x01)
	}
	body << if skill == 0 { u8(0x11) } else { u8(0x13) }
	body << encode_varint(300) // number of the effect
	body << []u8{len: 20, init: u8(index + 1)} // effect id, duration, u32, time
	body << encode_varint(target)
	body << u8(0x01) // level
	if skill != 0 {
		mut id := []u8{len: 4}
		binary.little_endian_put_u32(mut id, skill)
		body << id
	}
	body << flag
	body << vec_bytes(x, y, z)
	return frame(body)
}

// position_message is an effect an entity puts on itself without a skill
// (e.g. landing), which is how the local player is detected.
fn position_message(op0 u8, entity u64, x f32, y f32, z f32) []u8 {
	return effect_message(op0, entity, entity, 0, if op0 == 0x2a { u8(0) } else { u8(2) },
		x, y, z)
}

// cast_message builds a skill cast (02 38) aimed at `target` at x, y, z.
fn cast_message(caster u64, target u64, flag u8, x f32, y f32, z f32) []u8 {
	mut body := [u8(0x02), 0x38]
	body << encode_varint(caster)
	body << [u8(0), 0x11, 0x22, 0x33, 0x00, 0x4b, flag] // kind, skill, sequence, flag
	body << encode_varint(target)
	body << f32_bytes(90.0) // heading
	if flag == 2 {
		body << vec_bytes(x, y, z)
	}
	body << [u8(0x90), 0x4e, 0x01, 0x00]
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
	return frame(payload)
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

fn test_stale_effect_refresh_ignored() {
	mut msg := position_message(0x2b, 900, 1, 2, 3)
	msg[msg.len - 13] = 0x00 // flag 2 -> 0: the position of the first application
	mut dec := Decoder{}
	mut s := Stream{}
	s.feed(5, msg, 2.0, mut dec)
	assert dec.take_events().len == 0
}

// feed_all feeds the messages as one TCP payload and returns the events.
fn feed_all(mut dec Decoder, messages [][]u8) []Event {
	mut data := []u8{}
	for m in messages {
		data << m
	}
	mut s := Stream{}
	s.feed(1, data, 10.0, mut dec)
	return dec.take_events()
}

fn test_two_byte_size_keeps_framing() {
	// Messages of 124 bytes and more have a two-byte size; the bytes after
	// one must still be read as the next message (a cube was missed here).
	for n in [100, 123, 124, 125, 200, 16379, 16380, 20000] {
		mut body := [u8(0x41), 0x36]
		body << []u8{len: n - 2, init: u8(0x37)}
		mut dec := Decoder{}
		events := feed_all(mut dec, [frame(body), cube_message(9, 1, 2, 3)])
		assert events.map(it.kind) == [EventKind.cube], 'message of ${n} bytes'
	}
}

fn test_large_message_inside_bundle() {
	// A 70,000 byte message, compressed as its first bytes plus one long
	// match that repeats the last of them, then a cube.
	n := 70000
	mut head := encode_varint(u64(n + 4))
	head << [u8(0x83), 0x56, 0x37]
	mut compressed := [u8(head.len << 4 | 15)]
	compressed << head
	compressed << [u8(1), 0] // match offset
	mut rest := n - 3 - 4 - 15
	for rest >= 255 {
		compressed << u8(255)
		rest -= 255
	}
	compressed << u8(rest)
	cube := cube_message(9, 1, 2, 3)
	compressed << literal_lz4(cube)
	mut payload := [u8(0xff), 0xff]
	mut size := []u8{len: 4}
	binary.little_endian_put_u32(mut size, u32(head.len + n - 3 + cube.len))
	payload << size
	payload << compressed
	mut dec := Decoder{
		trace: true
	}
	assert feed_all(mut dec, [frame(payload)]).map(it.kind) == [EventKind.cube]
	assert dec.messages.map(it.data.len) == [n, cube.len - 1]
}

fn test_position_from_effects_and_casts_on_the_player() {
	mut dec := Decoder{}
	events := feed_all(mut dec, [
		effect_message(0x2a, 55, 900, 7, 0, 9, 9, 9), // player not known yet
		position_message(0x2a, 900, 1, 2, 3),
		effect_message(0x2a, 900, 900, 7, 0, 4, 5, 6), // own skill, e.g. a dash
		effect_message(0x2a, 55, 900, 7, 0, 7, 8, 9), // a monster's effect on the player
		effect_message(0x2a, 55, 901, 7, 0, 9, 9, 9), // ... on somebody else
		effect_message(0x2a, 55, 55, 7, 0, 9, 9, 9), // ... on itself
		effect_message(0x2b, 55, 900, 7, 2, 10, 11, 12),
		effect_message(0x2b, 55, 900, 7, 0, 9, 9, 9), // stale position
		cast_message(55, 900, 2, 13, 14, 15),
		cast_message(55, 901, 2, 9, 9, 9),
		cast_message(900, 900, 0, 0, 0, 0), // no position
	])
	assert events[0].kind == .player_detected
	assert events[0].id == 900
	assert events[1..].all(it.kind == .player && it.id == 900)
	assert events[1..].map(it.pos) == [Vec3{1, 2, 3}, Vec3{4, 5, 6},
		Vec3{7, 8, 9}, Vec3{10, 11, 12}, Vec3{13, 14, 15}]
}

fn test_rearm_keeps_the_player_until_another_one_shows_up() {
	mut dec := Decoder{}
	feed_all(mut dec, [position_message(0x2a, 900, 1, 2, 3)])
	dec.rearm_player()
	// The same character is still followed, also through effects by others.
	mut events := feed_all(mut dec, [effect_message(0x2a, 55, 900, 7, 0, 4, 5, 6)])
	assert events.map(it.kind) == [EventKind.player]
	// A monster's own effect (with a skill) does not take over, another
	// character's does - once.
	events = feed_all(mut dec, [effect_message(0x2a, 55, 55, 7, 0, 9, 9, 9),
		position_message(0x2a, 1234, 7, 8, 9), position_message(0x2a, 900, 9, 9, 9)])
	assert events.map(it.kind) == [EventKind.player_detected, .player]
	assert events[0].id == 1234
	assert events[1].pos == Vec3{7, 8, 9}
}

// Messages copied from a capture of leaving an instance (local player
// 11682 afterwards): opcode and data, without the size.
const real_zone_effect = '2a38a25b011101eb2e0000ffffffffffffffff8075d52abb030000a25b0100b418bfc6f97d0547004026c4'
const real_self_spawn_start = '3336a25b5e91c12837'
const real_dash_effect = '2a38a25b0113273b3c5101e09304000000000011ae0731a1010000a25b0139b92100006c0504c823e453c7c387e246'
const real_self_cast = '0238a25b0039b921000100a25bf960b143904e0200'
// A boss (44978) and the party members it aimed at.
const real_boss_effect = '2a38b2df020113d403bd641209b80b0000000000009f770231a1010000d75401463de80000b93352c606c46546e5870ec3'
const real_boss_refresh_stale = '2b38b2df0213c5038ba4bf072c3300000000000067910231a1010000dc0f010032c8000005e345c6b4566b46e66f1cc3'
const real_boss_refresh = '2b38b2df0213c8038ba4bf07102700000000000067910231a1010000dc0f010032c80002357849c69982694600001cc3'
const real_boss_cast = '0238b2df0200d89712004b02ed04ac65b2c1506341c60132664600001fc3904e01e807'
const real_boss_cast_start = '0938b2df0202ec9712000102a42fc8dedebeb9dd32c608f16746ec880ac3f60901904e'
const real_monster_own_effect = '2a389d97020113134135bc008813000000000000ff800231a10100009d97020120d2120000a5fef5c64f50eb460040aec4'

fn real(messages []string) [][]u8 {
	return messages.map(frame(hex_bytes(it)))
}

fn test_real_zone_change_messages() {
	mut dec := Decoder{}
	feed_all(mut dec, [position_message(0x2a, 12384, 1, 2, 3)]) // id in the instance
	dec.new_connection() // the app does this for a new server connection
	events := feed_all(mut dec, real([real_monster_own_effect, real_zone_effect,
		real_self_spawn_start, real_dash_effect, real_self_cast]))
	assert events.map(it.kind) == [EventKind.player_detected, .player, .player]
	assert events[0].id == 11682
	assert close_to(events[1].pos.x, -24460.35) && close_to(events[1].pos.y, 34173.97)
	assert close_to(events[2].pos.x, -135189.69) && close_to(events[2].pos.y, -54244.14)
		&& close_to(events[2].pos.z, 28995.88)
}

fn test_real_self_spawn_names_the_player() {
	mut dec := Decoder{}
	events := feed_all(mut dec, real([real_self_spawn_start, real_dash_effect]))
	assert events.map(it.kind) == [EventKind.player_detected, .player]
	assert events[0].id == 11682
}

fn test_real_effects_and_casts_give_the_target_position() {
	// Each party member in turn is the local player.
	for id, msg in {
		u64(10839): real_boss_effect
		2012:       real_boss_refresh
		621:        real_boss_cast
		6052:       real_boss_cast_start
	} {
		mut dec := Decoder{}
		feed_all(mut dec, [position_message(0x2a, id, 1, 2, 3)])
		events := feed_all(mut dec, real([real_boss_effect, real_boss_refresh_stale,
			real_boss_refresh, real_boss_cast, real_boss_cast_start]))
		assert events.len == 1, 'player ${id}'
		want := match msg {
			real_boss_effect { Vec3{-13452.93, 14705.01, -142.53} }
			real_boss_refresh { Vec3{-12894.05, 14944.65, -156.0} }
			real_boss_cast { Vec3{-12376.83, 14732.50, -159.0} }
			else { Vec3{-11447.43, 14844.26, -138.53} }
		}
		assert close_to(events[0].pos.x, want.x) && close_to(events[0].pos.y, want.y)
			&& close_to(events[0].pos.z, want.z), 'player ${id}'
	}
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

// Objects and NPCs, from the same capture (opcode and data, without the size).
const real_server_time = '003645060331a1010000'
const real_npc_spawn = '4136bbf0020420001f9f240000024ec903c89d6b53c70068d44682a33241f1070132326400000064000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000006000100010000009e299d7300'
const real_npc_start = '1b37bbf002044ec903c89d6b53c70068d4465faa5faa01'
const real_npc_step = '1c37bbf002047ccd03c8168853c7005cd4465faa5faa01'
const real_npc_despawn = '4236bbf0020001'
// A rarer NPC spawn variant with other fields, which is skipped.
const real_npc_spawn_other = '4136f1910185210031672c00080275a08f482e1aeac62cf95e47ec338342a62e5a38ac3cc4d03d3d668d59bb01af24af24640000006400000000000000000000000000000000000000640000006400000001000000000000000000000000000000000000000e0008010014000000622ba8a425bfec20f6a25900602ba8c200'

fn test_entities_are_off_by_default() {
	mut dec := Decoder{}
	events := feed_all(mut dec, real([real_npc_spawn, real_npc_step, real_npc_despawn]))
	assert events.len == 0
}

fn test_real_npc_is_followed() {
	mut dec := Decoder{
		entities: true
	}
	events := feed_all(mut dec, real([real_npc_step, real_npc_spawn_other, real_npc_spawn,
		real_npc_start, real_npc_step, real_npc_despawn, real_npc_step]))
	assert events.map(it.kind) == [EventKind.entity, .entity_moved, .entity_moved, .entity_removed]
	assert events.all(it.id == 47163)
	info := events[0].info
	assert info.category == .npc
	assert info.template == 2400031
	assert info.flags == '042000 0002'
	assert close_to(info.heading, 11.16)
	assert info.hp == 50 && info.max_hp == 50
	assert info.age == -1
	assert close_to(events[0].pos.x, -134949.22) && close_to(events[0].pos.z, 27188.0)
	assert close_to(events[2].pos.x, -134965.94) && close_to(events[2].pos.y, -54152.09)
	assert events[3].reason == 1
}

fn test_real_object_entity_with_age() {
	mut dec := Decoder{
		entities: true
	}
	mut messages := real([real_server_time])
	messages << hex_bytes(real_other_spawn)
	messages << hex_bytes(real_cube_spawn)
	messages << hex_bytes(real_despawn)
	events := feed_all(mut dec, messages)
	assert events.map(it.kind) == [EventKind.entity, .entity, .cube, .cube_removed, .entity_removed]
	assert events[0].info.category == .object
	assert events[0].info.template == 0x0013D626
	assert events[1].id == 69466
	assert events[1].info.template == cube_template
	assert events[1].info.flags == '0400 010101'
	assert close_to(events[1].info.heading, 111.09)
	// Created 1790906558676, server clock 1791823644229 (ms).
	assert close_to(events[1].info.age, 917085.553)
	assert events[4].id == 69466 && events[4].reason == removed_destroyed
	// Without the server clock the age is unknown; a short message has no details.
	mut other := Decoder{
		entities: true
	}
	messages = [hex_bytes(real_cube_spawn), cube_message(7, 1, 2, 3)]
	short := feed_all(mut other, messages)
	assert short[0].info.age == -1
	assert short[2].kind == .entity && short[2].info.flags == '0000' && short[2].info.age == -1
	other.forget_entities()
	assert feed_all(mut other, [hex_bytes(real_despawn)]).map(it.kind) == [
		EventKind.cube_removed,
	]
}

const real_enter_map = '21360100000056040000af4c2b0000000000f71305c8d32153c70014e046a3f5aa4300000000000000000000004f0000'

fn test_real_map_entered() {
	mut dec := Decoder{}
	events := feed_all(mut dec, real([real_enter_map, real_enter_map[..40]]))
	assert events.map(it.kind) == [EventKind.map_entered]
	assert events[0].id == 1110
	assert close_to(events[0].pos.x, -136271.86) && close_to(events[0].pos.y, -54049.82)
		&& close_to(events[0].pos.z, 28682.0)
}

fn test_login_server_and_own_name() {
	// 15 36: 2 bytes, two clock values, 3 bytes, the account string, the
	// game server id as digits, ... (a made-up account string here).
	mut login := [u8(0x15), 0x36, 0, 0]
	login << []u8{len: 16, init: u8(index + 1)}
	login << [u8(0), 1, 4]
	account := '123456:00000000-0000-0000-0000-000000000000'
	login << u8(account.len)
	login << account.bytes()
	login << u8(4)
	login << '2304'.bytes()
	login << u8(4)
	login << '5301'.bytes()
	login << [u8(2), 0x1e, 0]
	// 33 36 as captured up to the name, then a made-up name.
	mut own := hex_bytes(real_self_spawn_start)
	own << u8(8)
	own << 'TestName'.bytes()
	own << [u8(0), 9, 0x23, 0]
	mut dec := Decoder{}
	events := feed_all(mut dec, [frame(login), frame(own)])
	assert events.map(it.kind) == [EventKind.game_server, .player_detected, .player_name]
	assert events[0].id == 2304
	assert events[2].id == 11682 && events[2].name == 'TestName'
	// Something that is not a name, or not a server id, is not reported.
	assert parse_self_name(hex_bytes(real_self_spawn_start + '03410a42')) == none
	assert parse_self_name(hex_bytes(real_self_spawn_start)) == none
	mut odd := login.clone()
	odd[login.len - 9] = `x`
	assert parse_login_server(odd) == none
	assert parse_login_server(login[..30]) == none
}

fn test_opening_any_tracked_object() {
	mut dec := Decoder{
		entities: true
	}
	events := feed_all(mut dec, [hex_bytes(real_cube_spawn), hex_bytes(real_open_start),
		hex_bytes(real_open_done), hex_bytes(real_despawn), hex_bytes(real_open_done)])
	assert events.map(it.kind) == [EventKind.entity, .cube, .cube_opening, .entity_opened,
		.cube_opened, .cube_removed, .entity_removed, .cube_opened]
	assert events[3].id == 69466 && events[3].actor == 10029
}

fn test_an_npc_is_never_the_player() {
	// NPC 47163 puts an effect on itself without a skill, like a landing player.
	own_effect := position_message(0x2a, 47163, 1, 2, 3)
	mut dec := Decoder{}
	// Its spawn was seen first: it is not taken for the player.
	mut events := feed_all(mut dec, [frame(hex_bytes(real_npc_spawn)), own_effect])
	assert events.len == 0
	assert dec.self_id == none
	// Its effect came first: the guess is dropped when the spawn shows what it is.
	mut late := Decoder{}
	events = feed_all(mut late, [own_effect, frame(hex_bytes(real_npc_spawn)), own_effect,
		position_message(0x2a, 900, 4, 5, 6)])
	assert events.map(it.kind) == [EventKind.player_detected, .player, .player_lost, .player_detected,
		.player]
	assert events[2].id == 47163 && events[3].id == 900
	// Objects and other players are not the player either.
	mut dec2 := Decoder{}
	mut other := [u8(0x45), 0x36]
	other << encode_varint(7129)
	other << [u8(3), 0x20, 0xa0, 1, 7, 4]
	other << 'Abcd'.bytes()
	events = feed_all(mut dec2, [hex_bytes(real_cube_spawn), frame(other),
		position_message(0x2a, 69466, 1, 2, 3), position_message(0x2a, 7129, 1, 2, 3)])
	assert events.map(it.kind) == [EventKind.cube]
}

fn test_a_named_player_is_kept_until_the_next_connection() {
	mut dec := Decoder{}
	mut events := feed_all(mut dec, [frame(hex_bytes(real_npc_spawn)),
		frame(hex_bytes(real_self_spawn_start))])
	assert events.map(it.kind) == [EventKind.player_detected]
	assert dec.self_id or { 0 } == 11682
	// No position for a while: the app re-arms, but the id the game gave stays.
	dec.rearm_player()
	events = feed_all(mut dec, [position_message(0x2a, 900, 1, 2, 3),
		frame(hex_bytes(real_dash_effect))])
	assert events.map(it.kind) == [EventKind.player]
	assert events[0].id == 11682
	// Another server: ids start over, also the ones known not to be the player.
	dec.new_connection()
	events = feed_all(mut dec, [position_message(0x2a, 47163, 7, 8, 9)])
	assert events.map(it.kind) == [EventKind.player_detected, .player]
	assert events[0].id == 47163
}
