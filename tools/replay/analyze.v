module main

import math
import proto

// --analyze: looks for objects the decoder does not know yet. Prints every
// spawned template (with how many of its objects players opened or that
// were destroyed - cubes do both), the opcodes seen, and the messages that
// carry a position close to the player (or to --at x,y,z).

struct TemplateStats {
mut:
	spawns    int
	objects   map[u64]bool
	opened    map[u64]bool
	destroyed map[u64]bool
	nearest   f64 = -1
	sample    proto.Vec3
}

struct TemplateRow {
	template  u32
	spawns    int
	objects   int
	opened    int
	destroyed int
	nearest   f64
	sample    proto.Vec3
}

struct OpStats {
	name string
mut:
	count    int
	min_size int
	max_size int
}

struct NearStats {
	key string
mut:
	hits    int
	nearest f64
	sample  proto.Vec3
}

// parse_at reads "x,y" or "x,y,z".
fn parse_at(text string) ?proto.Vec3 {
	parts := text.split(',').map(it.trim_space())
	if parts.len < 2 || parts.any(it == '') {
		return none
	}
	return proto.Vec3{parts[0].f64(), parts[1].f64(), if parts.len > 2 {
		parts[2].f64()
	} else {
		0.0
	}}
}

// reference_at returns where the player was at `timestamp`: `fixed` (--at)
// when given, else the last fix before it or the first one of the capture.
fn reference_at(fixed ?proto.Vec3, fixes []proto.Event, timestamp f64) ?proto.Vec3 {
	if at := fixed {
		return at
	}
	if fixes.len == 0 {
		return none
	}
	mut pos := fixes[0].pos
	for f in fixes {
		if f.timestamp > timestamp {
			break
		}
		pos = f.pos
	}
	return pos
}

fn op_name(data []u8) string {
	return '${data[0]:02x} ${data[1]:02x}'
}

fn pos_text(p proto.Vec3) string {
	return '(${p.x:.1f}, ${p.y:.1f}, ${p.z:.1f})'
}

fn analyze(messages []proto.RawMessage, fixes []proto.Event, opts Options) {
	fixed := parse_at(opts.at)
	mut templates := map[u32]&TemplateStats{}
	mut template_of := map[u64]u32{}
	mut ops := map[string]&OpStats{}
	mut near := map[string]&NearStats{}
	mut has_reference := false
	for m in messages {
		d := m.data
		name := op_name(d)
		mut op := ops[name] or {
			s := &OpStats{
				name:     name
				min_size: d.len
			}
			ops[name] = s
			s
		}
		op.count++
		op.min_size = math.min(op.min_size, d.len)
		op.max_size = math.max(op.max_size, d.len)

		reference := reference_at(fixed, fixes, m.timestamp)
		code := [d[0], d[1]]!
		if sp := proto.parse_spawn(d) {
			template_of[sp.id] = sp.template
			mut t := templates[sp.template] or {
				s := &TemplateStats{}
				templates[sp.template] = s
				s
			}
			t.spawns++
			t.objects[sp.id] = true
			if ref := reference {
				dist := math.hypot(sp.pos.x - ref.x, sp.pos.y - ref.y)
				if t.nearest < 0 || dist < t.nearest {
					t.nearest = dist
					t.sample = sp.pos
				}
			} else if t.spawns == 1 {
				t.sample = sp.pos
			}
		} else if code == proto.op_open_start || code == proto.op_open_done
			|| code == proto.op_despawn {
			id := proto.read_varint(d, 2)
			if id.status == .ok && id.value in template_of {
				mut t := templates[template_of[id.value]] or { continue }
				if code != proto.op_despawn {
					t.opened[id.value] = true
				} else if 2 + id.width < d.len && d[2 + id.width] == proto.removed_destroyed {
					t.destroyed[id.value] = true
				}
			}
		}

		ref := reference or { continue }
		has_reference = true
		for at in 2 .. d.len - 11 {
			p := proto.read_vec3(d, at)
			if !p.is_finite() {
				continue
			}
			dist := math.hypot(p.x - ref.x, p.y - ref.y)
			// --at without z compares the flat distance only.
			if dist > opts.near || (ref.z != 0 && math.abs(p.z - ref.z) > opts.near) {
				continue
			}
			key := '${name} @${at}'
			mut n := near[key] or {
				s := &NearStats{
					key:     key
					nearest: dist
					sample:  p
				}
				near[key] = s
				s
			}
			n.hits++
			if dist < n.nearest {
				n.nearest = dist
				n.sample = p
			}
		}
	}

	println('')
	println('== analysis of ${messages.len} messages')
	println('-- object spawns (opcode 34 36) by template; opened / destroyed = objects a player opened / that were destroyed')
	mut rows := []TemplateRow{}
	for template, t in templates {
		rows << TemplateRow{template, t.spawns, t.objects.len, t.opened.len, t.destroyed.len, t.nearest, t.sample}
	}
	rows.sort_with_compare(fn (a &TemplateRow, b &TemplateRow) int {
		if a.opened != b.opened {
			return b.opened - a.opened
		}
		if a.destroyed != b.destroyed {
			return b.destroyed - a.destroyed
		}
		return a.spawns - b.spawns
	})
	println('template    spawns objects opened destroyed  nearest  position of the nearest')
	for r in rows {
		nearest := if r.nearest < 0 { '-' } else { '${r.nearest:.0f}' }
		note := if r.template == proto.cube_template { '  <- cube (known)' } else { '' }
		println('0x${r.template:08X} ${r.spawns:6} ${r.objects:7} ${r.opened:6} ${r.destroyed:9} ${nearest:8}  ${pos_text(r.sample)}${note}')
	}
	if rows.len == 0 {
		println('(no object spawns)')
	}

	println('-- opcodes: count, message size')
	mut op_rows := ops.values()
	op_rows.sort(a.count > b.count)
	for o in op_rows {
		size := if o.min_size == o.max_size {
			'${o.min_size}'
		} else {
			'${o.min_size}-${o.max_size}'
		}
		println('${o.name}  ${o.count:6}  ${size}')
	}

	println('-- messages with a position within ${opts.near:.0f} units of you (opcode @byte offset of x): hits, closest, position')
	if !has_reference {
		println('(no player position in this capture - pass --at x,y,z, e.g. your XYZ from Cube Watch)')
		return
	}
	mut near_rows := near.values()
	near_rows.sort(a.hits < b.hits)
	for n in near_rows {
		println('${n.key:-10} ${n.hits:6} ${n.nearest:8.0f}  ${pos_text(n.sample)}')
	}
	if near_rows.len == 0 {
		println('(none)')
	}
}
