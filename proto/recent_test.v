module proto

import math
import os

fn numbered_frame(i int, timestamp f64) CapturedFrame {
	return CapturedFrame{
		linktype:  dlt_en10mb
		timestamp: timestamp
		data:      [u8(i), u8(i >> 8), 0xaa]
	}
}

fn test_recent_frames_keep_only_the_window() {
	mut r := RecentFrames{}
	for i in 0 .. 5000 {
		r.add(numbered_frame(i, 1000.0 + f64(i) * 0.25))
	}
	frames := r.snapshot()
	// 0.25 s apart: the last 60 s hold frames 4759..4999.
	assert frames.len == 241
	assert frames[0].data == numbered_frame(4759, 0).data
	assert frames.last().data == numbered_frame(4999, 0).data
	// Dropped frames do not pile up in the backing array.
	assert r.frames.len < 2 * recent_compact_at + frames.len
	assert r.bytes == 3 * frames.len
}

fn test_recent_frames_respect_the_byte_cap() {
	mut r := RecentFrames{
		max_bytes: 10
	}
	for i in 0 .. 10 {
		r.add(numbered_frame(i, 5.0))
	}
	frames := r.snapshot()
	assert frames.len == 3
	assert frames[0].data == numbered_frame(7, 0).data
}

fn test_recent_frames_restart_on_another_link_type() {
	mut r := RecentFrames{}
	r.add(numbered_frame(1, 1.0))
	r.add(numbered_frame(2, 2.0))
	r.add(CapturedFrame{
		linktype:  dlt_raw
		timestamp: 3.0
		data:      [u8(9)]
	})
	frames := r.snapshot()
	assert frames.len == 1
	assert frames[0].linktype == dlt_raw
}

fn test_write_pcap_round_trip() {
	path := os.join_path(os.temp_dir(), 'cube_watch_test_${os.getpid()}.pcap')
	defer {
		os.rm(path) or {}
	}
	frames := [numbered_frame(1, 1760000000.25), numbered_frame(300, 1760000001.5),
		CapturedFrame{
			linktype:  dlt_en10mb
			timestamp: 1760000059.999999
			data:      []u8{len: 1500, init: u8(index)}
		}]
	write_pcap(path, frames)!
	back := read_capture_file(path)!
	assert back.len == frames.len
	for i, f in frames {
		assert back[i].linktype == f.linktype
		assert back[i].data == f.data
		assert math.abs(back[i].timestamp - f.timestamp) < 0.00001
	}
	write_pcap(path, []CapturedFrame{}) or {
		assert err.msg().contains('no frames')
		return
	}
	assert false
}
