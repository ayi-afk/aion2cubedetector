module wire

import encoding.binary
import rand
import x.crypto.chacha20poly1305

// What Cube Watch and the backend say to each other is encrypted, so that
// the reports cannot simply be read or made up by somebody on the way:
// ChaCha20-Poly1305 - fast, and a message that was changed, cut or made
// with another key is recognised and dropped - with one key both programs
// carry.
//
// The key is not in the executables as a piece of data. It is put together
// when the program starts, from numbers that sit in different places of
// this package. That keeps eyes and ready-made tools off the traffic; who
// takes the program apart will find it - it is not a secret the way a
// password is. (The backend's --client-key is: it travels inside the
// encrypted hello.) Change the numbers and both programs have to be built
// again; old ones can then no longer talk to new ones.
//
// A sealed message is one binary websocket frame:
//
//   12 bytes nonce | ciphertext | 16 bytes tag
//
// The nonce is 4 bytes chosen at random for the connection (their first
// bit says who sent it) and a counter, so it does not repeat under the key.

const nonce_size = chacha20poly1305.nonce_size
// A sealed message is this much longer than its text.
pub const seal_overhead = chacha20poly1305.nonce_size + chacha20poly1305.tag_size

const link_key = make_link_key()
const from_client = [u8(`c`)]
const from_server = [u8(`s`)]

fn make_link_key() []u8 {
	mut key := u64(0xf14f11aaa1029ef9)
	mut out := []u8{cap: chacha20poly1305.key_size}
	for part in [mix_first, u64(max_near_items) * mix_second, mix_third ^ u64(max_frame_payload),
		mix_fourth] {
		key += 1
		key ^= part
		key = (key ^ (key >> 30)) * 0xbf58476d1ce4e5b9
		key = (key ^ (key >> 27)) * 0x94d049bb133111eb
		key ^= key >> 31
		for shift in 0 .. 8 {
			out << u8(key >> (8 * shift))
		}
	}
	return out
}

// Sealer encrypts the messages of one side of one connection.
pub struct Sealer {
	server bool
	salt   u32
mut:
	count u64
}

// new_sealer is made once per connection; `server` says which side seals.
pub fn new_sealer(server bool) Sealer {
	salt := rand.u32() & 0x7fffffff
	return Sealer{
		server: server
		salt:   if server { salt | 0x80000000 } else { salt }
	}
}

// seal returns the message as the payload of a binary frame.
pub fn (mut s Sealer) seal(text string) []u8 {
	s.count++
	mut out := []u8{len: nonce_size, cap: text.len + seal_overhead}
	binary.big_endian_put_u32(mut out, s.salt)
	binary.little_endian_put_u64_at(mut out, s.count, 4)
	// the text is only read: no copy of it
	out << chacha20poly1305.encrypt(unsafe { text.str.vbytes(text.len) }, link_key, out[..nonce_size],
		if s.server {
		from_server
	} else {
		from_client
	}) or { return []u8{} }
	return out
}

// open returns the text of a sealed message that the other side (`server`:
// the backend) made, or none when it is not one.
pub fn open(data []u8, server bool) ?string {
	if data.len < seal_overhead || (data[0] & 0x80 != 0) != server {
		return none
	}
	text := chacha20poly1305.decrypt(data[nonce_size..], link_key, data[..nonce_size],
		if server { from_server } else { from_client }) or { return none }
	return text.bytestr()
}
