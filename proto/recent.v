module proto

// RecentFrames keeps the frames of the last `window` seconds in memory so
// they can be saved for offline analysis (e.g. an object the decoder does
// not know yet). Not thread safe; the owner serialises access.
pub struct RecentFrames {
pub:
	window    f64 = 60.0
	max_bytes int = 64 * 1024 * 1024 // safety cap on the frame data held
mut:
	frames []CapturedFrame
	head   int // frames before this index were dropped
	bytes  int
}

// Dropped frames are cut off the array once this many have piled up and
// they make up at least half of it.
const recent_compact_at = 1024

pub fn (mut r RecentFrames) add(frame CapturedFrame) {
	// A pcap file holds one link type; another adapter starts over.
	if r.head < r.frames.len && r.frames[r.head].linktype != frame.linktype {
		r.frames = []CapturedFrame{}
		r.head = 0
		r.bytes = 0
	}
	r.frames << frame
	r.bytes += frame.data.len
	for r.head < r.frames.len - 1
		&& (frame.timestamp - r.frames[r.head].timestamp > r.window || r.bytes > r.max_bytes) {
		r.bytes -= r.frames[r.head].data.len
		r.frames[r.head] = CapturedFrame{} // release the frame data
		r.head++
	}
	if r.head >= recent_compact_at && r.head * 2 >= r.frames.len {
		r.frames = r.frames[r.head..].clone()
		r.head = 0
	}
}

// snapshot returns the kept frames, oldest first.
pub fn (r &RecentFrames) snapshot() []CapturedFrame {
	return r.frames[r.head..].clone()
}
