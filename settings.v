module main

import json
import os
import proto

enum SoundMode {
	windows
	melody
	custom
	off
}

struct Settings {
mut:
	opacity       int = 100
	topmost       bool
	close_to_tray bool      = true
	sound_mode    SoundMode = .windows
	sound_file    string
	adapter       string
	port          int = proto.default_port
	// World direction of minimap north (degrees, see proto.Compass) and
	// whether the user calibrated it.
	north_deg        f64 = proto.default_north_deg
	north_calibrated bool
	// 1 = north_deg default is the measured AION 2 north (older files used +X).
	compass_version int
	// Cubes farther than this (planar world units) are left off the compass; 0 = no limit.
	compass_range int = default_compass_range
	// Compact view: only position and compass; it keeps its own window size.
	theme          string = theme_system // system / light / dark
	compact        bool
	compact_width  int
	compact_height int
	x              int = -1
	y              int = -1
	width          int
	height         int
}

fn settings_dir() string {
	return os.join_path(os.config_dir() or { os.home_dir() }, 'CubeWatch')
}

fn settings_path() string {
	return os.join_path(settings_dir(), 'settings.json')
}

fn load_settings() Settings {
	raw := os.read_file(settings_path()) or { return Settings{
		compass_version: 1
	} }
	mut s := json.decode(Settings, raw) or {
		eprintln('Ignoring unreadable settings file: ${err}')
		return Settings{
			compass_version: 1
		}
	}
	s.opacity = clamp(s.opacity, 20, 100)
	if s.port <= 0 || s.port > 65535 {
		s.port = proto.default_port
	}
	if s.compass_version < 1 {
		// Files from before the measured default kept north = +X unless calibrated.
		if !s.north_calibrated {
			s.north_deg = proto.default_north_deg
		}
		s.compass_version = 1
	}
	if s.compass_range !in compass_ranges {
		s.compass_range = default_compass_range
	}
	return s
}

fn save_settings(s Settings) ! {
	os.mkdir_all(settings_dir())!
	os.write_file(settings_path(), json.encode_pretty(s))!
}

fn clamp(v int, lo int, hi int) int {
	return if v < lo {
		lo
	} else if v > hi {
		hi
	} else {
		v
	}
}
