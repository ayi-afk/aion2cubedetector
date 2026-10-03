module proto

import encoding.binary
import math
import os

// Minimal reader for pcapng and classic pcap capture files, used for
// offline replay and tests.

pub struct CapturedFrame {
pub:
	linktype  int
	timestamp f64
	data      []u8
}

struct PcapngInterface {
	linktype int
	units    f64 // timestamp units per second
}

pub fn read_capture_file(path string) ![]CapturedFrame {
	raw := os.read_bytes(path)!
	if raw.len < 24 {
		return error('${path}: file too short')
	}
	magic := binary.little_endian_u32_at(raw, 0)
	return match magic {
		0x0A0D0D0A { read_pcapng(raw)! }
		0xA1B2C3D4, 0xA1B23C4D { read_pcap(raw, magic == 0xA1B23C4D)! }
		else { error('${path}: not a pcap/pcapng file (big-endian files are not supported)') }
	}
}

fn read_pcap(raw []u8, nanos bool) ![]CapturedFrame {
	linktype := int(binary.little_endian_u32_at(raw, 20))
	divisor := if nanos { 1e9 } else { 1e6 }
	mut out := []CapturedFrame{}
	mut pos := 24
	for pos + 16 <= raw.len {
		sec := binary.little_endian_u32_at(raw, pos)
		frac := binary.little_endian_u32_at(raw, pos + 4)
		caplen := int(binary.little_endian_u32_at(raw, pos + 8))
		pos += 16
		if pos + caplen > raw.len {
			return error('truncated pcap record')
		}
		out << CapturedFrame{
			linktype:  linktype
			timestamp: f64(sec) + f64(frac) / divisor
			data:      raw[pos..pos + caplen].clone()
		}
		pos += caplen
	}
	return out
}

fn read_pcapng(raw []u8) ![]CapturedFrame {
	mut out := []CapturedFrame{}
	mut ifaces := []PcapngInterface{}
	mut pos := 0
	for pos + 12 <= raw.len {
		block_type := binary.little_endian_u32_at(raw, pos)
		total := int(binary.little_endian_u32_at(raw, pos + 4))
		if total < 12 || pos + total > raw.len {
			return error('corrupt pcapng block at offset ${pos}')
		}
		body := raw[pos + 8..pos + total - 4]
		match block_type {
			0x0A0D0D0A {
				if binary.little_endian_u32_at(body, 0) != 0x1A2B3C4D {
					return error('big-endian pcapng files are not supported')
				}
				// Interface ids restart in every section.
				ifaces.clear()
			}
			0x00000001 {
				ifaces << PcapngInterface{
					linktype: int(binary.little_endian_u16_at(body, 0))
					units:    interface_ts_units(body[8..])
				}
			}
			0x00000006 {
				iface_id := int(binary.little_endian_u32_at(body, 0))
				if iface_id >= ifaces.len {
					return error('packet references unknown interface ${iface_id}')
				}
				iface := ifaces[iface_id]
				ts := (u64(binary.little_endian_u32_at(body, 4)) << 32) | u64(binary.little_endian_u32_at(body,
					8))
				caplen := int(binary.little_endian_u32_at(body, 12))
				if 20 + caplen > body.len {
					return error('truncated enhanced packet block')
				}
				out << CapturedFrame{
					linktype:  iface.linktype
					timestamp: f64(ts) / iface.units
					data:      body[20..20 + caplen].clone()
				}
			}
			0x00000003 {
				if ifaces.len == 0 {
					return error('simple packet block before interface description')
				}
				origlen := int(binary.little_endian_u32_at(body, 0))
				caplen := math.min(origlen, body.len - 4)
				out << CapturedFrame{
					linktype: ifaces[0].linktype
					data:     body[4..4 + caplen].clone()
				}
			}
			else {}
		}
		pos += total
	}
	return out
}

// interface_ts_units reads the if_tsresol option (default microseconds).
fn interface_ts_units(options []u8) f64 {
	mut pos := 0
	for pos + 4 <= options.len {
		code := binary.little_endian_u16_at(options, pos)
		length := int(binary.little_endian_u16_at(options, pos + 2))
		if code == 0 {
			break
		}
		if code == 9 && length >= 1 && pos + 4 < options.len {
			v := options[pos + 4]
			return if v & 0x80 != 0 {
				math.pow(2, f64(v & 0x7f))
			} else {
				math.pow(10, f64(v))
			}
		}
		pos += 4 + ((length + 3) & ~3)
	}
	return 1e6
}
