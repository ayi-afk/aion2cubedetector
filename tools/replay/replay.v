module main

import flag
import math
import os
import proto
import time

// replay feeds a pcap/pcapng capture through the same decoder the app uses
// and prints the cube spawns and local player positions it finds.

struct Options {
	port      int
	interval  f64
	positions bool
}

fn main() {
	mut fp := flag.new_flag_parser(os.args)
	fp.application('replay')
	fp.skip_executable()
	fp.description('Replay an AION 2 capture through the Cube Watch decoder.')
	fp.arguments_description('capture.pcapng [more captures...]')
	port := fp.int('port', `p`, proto.default_port, 'game server TCP port')
	interval := fp.float('interval', `i`, 2.0, 'seconds between printed player positions')
	positions := fp.bool('positions', 0, true, 'print player positions')
	files := fp.finalize() or {
		eprintln(err)
		println(fp.usage())
		exit(2)
	}
	if files.len == 0 {
		println(fp.usage())
		exit(2)
	}
	opts := Options{port, interval, positions}
	for file in files {
		replay(file, opts) or {
			eprintln('${file}: ${err}')
			exit(1)
		}
	}
}

fn stamp(ts f64) string {
	t := time.unix_microsecond(i64(ts), int((ts - math.floor(ts)) * 1e6)).local()
	return t.format_ss_milli()
}

fn who(dec proto.Decoder, actor u64) string {
	self_id := dec.self_id or { return '' }
	return if self_id == actor { ' (you)' } else { ' (another player)' }
}

fn replay(file string, opts Options) ! {
	frames := proto.read_capture_file(file)!
	println('== ${file}: ${frames.len} frames')
	mut dec := proto.Decoder{}
	mut streams := map[string]&proto.Stream{}
	mut payload_bytes := 0
	mut last_print := 0.0
	mut player := ?proto.Event(none)
	mut cubes := []proto.Event{}
	mut player_count := 0
	for f in frames {
		pkt := proto.game_packet(f.data, f.linktype, opts.port) or { continue }
		if pkt.payload.len == 0 {
			continue
		}
		payload_bytes += pkt.payload.len
		key := '${pkt.server}:${pkt.client_port}'
		mut stream := streams[key] or {
			s := &proto.Stream{}
			streams[key] = s
			println('[${stamp(f.timestamp)}] server flow ${key}')
			s
		}
		stream.feed(pkt.seq, pkt.payload, f.timestamp, mut dec)
		for ev in dec.take_events() {
			match ev.kind {
				.player_detected {
					println('[${stamp(ev.timestamp)}] player entity ${ev.id} detected')
				}
				.player {
					player = ev
					player_count++
					if opts.positions && ev.timestamp - last_print >= opts.interval {
						last_print = ev.timestamp
						println('[${stamp(ev.timestamp)}] player (${ev.pos.x:.1f}, ${ev.pos.y:.1f}, ${ev.pos.z:.1f})')
					}
				}
				.cube {
					cubes << ev
					mut rel := 'player position unknown'
					if p := player {
						dx, dy, dz := ev.pos.x - p.pos.x, ev.pos.y - p.pos.y, ev.pos.z - p.pos.z
						rel = 'distance ${math.hypot(dx, dy):.0f}, dX ${dx:+.0f}, dY ${dy:+.0f}, dZ ${dz:+.0f} (player fix ${ev.timestamp - p.timestamp:.1f}s old)'
					}
					println('[${stamp(ev.timestamp)}] CUBE object=${ev.id} at (${ev.pos.x:.1f}, ${ev.pos.y:.1f}, ${ev.pos.z:.1f}); ${rel}')
				}
				.cube_visible {
					println('[${stamp(ev.timestamp)}] cube ${ev.id} visible again')
				}
				.cube_opening {
					println('[${stamp(ev.timestamp)}] cube ${ev.id}: player ${ev.actor} started opening${who(dec,
						ev.actor)}')
				}
				.cube_opened {
					println('[${stamp(ev.timestamp)}] cube ${ev.id}: opened by player ${ev.actor}${who(dec,
						ev.actor)}')
				}
				.cube_removed {
					println('[${stamp(ev.timestamp)}] cube ${ev.id}: removed (reason 0x${ev.reason:02x})')
				}
			}
		}
	}
	println('-- ${streams.len} flow(s), ${payload_bytes} payload bytes, ${player_count} player positions, ${cubes.len} cube(s)')
}
