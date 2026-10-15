module main

import flag
import math
import os
import remote
import time
import wire

// fakeclient plays a Cube Watch client against a backend, to try the
// server and its map without the game: a character walks around a point
// and a cube at that point is seen, opened and seen again.
//
//   v run tools/fakeclient --addr 127.0.0.1:8081 --key ... --name Tester --server 2304

fn main() {
	mut fp := flag.new_flag_parser(os.args)
	fp.application('fakeclient')
	fp.skip_executable()
	addr := fp.string('addr', 0, '127.0.0.1:8081', 'backend: host:port, a host name alone (HTTPS) or ws:// / wss:// address')
	probe := fp.bool('probe', 0, false, 'only connect and say hello: tells whether the backend can be reached and answers (reports nothing)')
	hold := fp.int('hold', 0, 0, 'with --probe: stay connected this many seconds afterwards and say whether the connection held')
	key := fp.string('key', 0, '', 'client key of the backend')
	name := fp.string('name', 0, 'Tester', 'character name')
	server := fp.int('server', 0, 2304, 'game server id')
	map_id := fp.int('map', 0, 1110, 'map id')
	x := fp.float('x', 0, -134043.7, 'world X of the cube')
	y := fp.float('y', 0, -54024.8, 'world Y of the cube')
	seconds := fp.int('seconds', 0, 40, 'how long to run')
	respawn := fp.int('respawn', 0, 12, 'seconds from opening the cube to the next one')
	install := fp.string('install', 0, 'fakeclient0000001', 'installation id (characters with the same one belong together)')
	clients := fp.int('clients', 0, 1, 'load test: this many clients that only walk around (use --server 0 so no profiles are looked up)')
	watch := fp.bool('watch', 0, false, 'load test: the clients ask for the area around them, as with map overlay 2 on')
	prefix := fp.string('prefix', 0, 'Bot', 'load test: names of the clients (prefix, then a number); "Unknown-" keeps the backend from looking them up')
	fp.finalize() or {
		eprintln(err)
		exit(2)
	}
	if clients > 1 {
		swarm(clients, addr, key, server, u32(map_id), seconds, watch, prefix)
		return
	}
	mut link := remote.new_link(remote.Config{ addr: addr, key: key, install: install })
	link.start()
	if probe {
		where := if e := wire.parse_endpoint(addr) { e.str() } else { addr }
		for _ in 0 .. 60 {
			time.sleep(200 * time.millisecond)
			for msg in link.take_inbox() {
				if msg.t == wire.t_kinds {
					println('ok: ${where} answers, it tracks ${msg.kinds.len} kinds')
					for second in 0 .. hold {
						time.sleep(time.second)
						if !link.is_online() {
							println('the connection was lost after ${second + 1} s: ${link.problem()}')
							exit(1)
						}
					}
					if hold > 0 {
						println('still connected after ${hold} s')
					}
					exit(0)
				}
				if msg.t == wire.t_error {
					println('refused by ${where}: ${msg.msg}')
					exit(1)
				}
			}
			if link.problem() != '' {
				println('failed: ${link.problem()}')
				exit(1)
			}
		}
		println(if link.is_online() {
			'${where}: the websocket is open, but nothing answers the hello - a backend from before the encryption? Build and deploy the current one.'
		} else {
			'${where}: no connection'
		})
		exit(1)
	}
	cube := wire.ClientMsg{
		t:   wire.t_seen
		map: u32(map_id)
		x:   x
		y:   y
		z:   28616.0
		cat: wire.category_object
		tpl: 1301199
	}
	started := time.now()
	mut tracked := false
	mut entity := u64(61967)
	mut state := 'waiting'
	mut changed := time.now()
	for i := 0; time.since(started) < seconds * time.second; i++ {
		time.sleep(500 * time.millisecond)
		for msg in link.take_inbox() {
			if msg.t == wire.t_nearby {
				// the admin asks what is around: the cube, and something not tracked
				link.send(wire.ClientMsg{
					t:     wire.t_near
					key:   msg.msg
					items: [
						wire.NearItem{wire.category_object, 1301199, entity, x, y, 28616.0, 420},
						wire.NearItem{wire.category_npc, 2400804, 24835, x + 900, y - 300, 28600.0, 950},
					]
				})
			}
			if msg.t == wire.t_kinds {
				tracked = msg.kinds.any(it.tpl == cube.tpl)
				println('server tracks: ' +
					msg.kinds.map('${it.name} (${it.cat} ${it.tpl}, group "${it.group}")').join(', '))
			} else {
				println('server says: ${msg.t} ${msg.msg}')
			}
		}
		if !link.is_online() {
			if state != 'waiting' {
				println('offline')
				state = 'waiting'
			}
			continue
		}
		// walk a small circle next to the cube
		angle := f64(i) * 0.35
		link.send(wire.ClientMsg{
			t:      wire.t_me
			server: server
			name:   name
			map:    u32(map_id)
			x:      x + 1500 * math.cos(angle)
			y:      y + 1500 * math.sin(angle)
			z:      28620.0
		})
		if !tracked {
			continue
		}
		since := time.since(changed)
		if state == 'waiting' {
			println('online as ${name}@${server}; the cube is there')
			link.send(wire.ClientMsg{
				...cube
				id:  entity
				age: 63.0
			})
			state = 'there'
			changed = time.now()
		} else if state == 'there' && since > 6 * time.second {
			println('opening the cube')
			link.send(wire.ClientMsg{
				...cube
				t:    wire.t_taken
				id:   entity
				mine: true
			})
			link.send(wire.ClientMsg{
				...cube
				t:  wire.t_gone
				id: entity
			})
			state = 'taken'
			changed = time.now()
		} else if state == 'taken' && since > respawn * time.second {
			entity++
			println('a new cube spawned')
			link.send(wire.ClientMsg{
				...cube
				id:  entity
				age: 1.0
			})
			state = 'there'
			changed = time.now()
		}
	}
	link.close()
	time.sleep(300 * time.millisecond)
}

// swarm connects many clients at once; each walks its own circle and
// reports its position once a second.
fn swarm(n int, addr string, key string, server int, map_id u32, seconds int, watch bool, prefix string) {
	mut links := []&remote.Link{}
	mut watching := []bool{len: n}
	for _ in 0 .. n {
		mut link := remote.new_link(remote.Config{ addr: addr, key: key })
		link.start()
		links << link
	}
	started := time.now()
	for tick := 0; time.since(started) < seconds * time.second; tick++ {
		time.sleep(time.second)
		mut online := 0
		for i, mut link in links {
			link.take_inbox()
			if !link.is_online() {
				watching[i] = false
				continue
			}
			online++
			if watch && !watching[i] {
				watching[i] = true
				link.send(wire.ClientMsg{
					t:     wire.t_watch
					watch: true
				})
			}
			angle := f64(tick) * 0.2 + f64(i)
			link.send(wire.ClientMsg{
				t:      wire.t_me
				server: server
				name:   '${prefix}${i + 1}'
				map:    map_id
				x:      -150000 + f64(i % 20) * 15000 + 3000 * math.cos(angle)
				y:      -100000 + f64(i / 20) * 15000 + 3000 * math.sin(angle)
				z:      1000
			})
		}
		if tick % 5 == 0 {
			println('${online} of ${n} clients online')
		}
	}
	for mut link in links {
		link.close()
	}
	time.sleep(500 * time.millisecond)
}
