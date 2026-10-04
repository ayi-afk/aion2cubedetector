module main

import os
import time

// Diagnostics for a windowed app that has no console: V panics and other
// stderr output go to %APPDATA%\CubeWatch\log.txt, and a native crash
// (e.g. inside a codec or shell extension loaded by the file dialog or MP3
// playback) is logged with the module it happened in before Windows ends
// the process.

fn C._wfreopen(path &u16, mode &u16, stream voidptr) voidptr
fn C.fflush(stream voidptr) int

type FnSetUnhandledExceptionFilter = fn (voidptr) voidptr

type FnGetModuleHandleEx = fn (u32, voidptr, &voidptr) int

type FnGetModuleFileName = fn (voidptr, &u16, u32) u32

type FnOleInitialize = fn (voidptr) int

const log_max_bytes = 256 * 1024
const module_from_address = u32(0x4)
const module_unchanged_refcount = u32(0x2)

fn log_path() string {
	return os.join_path(settings_dir(), 'log.txt')
}

fn setup_diagnostics() {
	os.mkdir_all(settings_dir()) or { return }
	path := log_path()
	if os.file_size(path) > log_max_bytes {
		os.rm(path) or {}
	}
	C._wfreopen(path.to_wide(), 'a'.to_wide(), C.stderr)
	set_filter := proc_address('kernel32.dll', 'SetUnhandledExceptionFilter')
	if set_filter != unsafe { nil } {
		install := FnSetUnhandledExceptionFilter(set_filter)
		install(voidptr(crash_filter))
	}
}

// crash_filter logs the exception code, address and module, then lets
// Windows terminate the process as usual.
fn crash_filter(info voidptr) int {
	unsafe {
		record := *(&voidptr(info))
		code := *(&u32(record))
		addr := *(&voidptr(&u8(record) + 16))
		mut mod_name := '?'
		mut offset := usize(0)
		get_handle := proc_address('kernel32.dll', 'GetModuleHandleExW')
		get_name := proc_address('kernel32.dll', 'GetModuleFileNameW')
		if get_handle != nil && get_name != nil {
			module_of := FnGetModuleHandleEx(get_handle)
			file_name := FnGetModuleFileName(get_name)
			handle := nil
			if module_of(module_from_address | module_unchanged_refcount, addr, &handle) != 0 {
				mut buf := [260]u16{}
				file_name(handle, &buf[0], 260)
				mod_name = string_from_wide(&buf[0])
				offset = usize(addr) - usize(handle)
			}
		}
		eprintln('${time.now().format_ss()} CRASH: exception 0x${code:08x} in ${mod_name} +0x${offset:x}')
		C.fflush(C.stderr)
	}
	return 0 // EXCEPTION_CONTINUE_SEARCH
}

// init_com: the file dialog and MP3 playback load shell / codec components
// that require COM on the UI thread; some crash without it.
fn init_com() {
	ole_init := proc_address('ole32.dll', 'OleInitialize')
	if ole_init != unsafe { nil } {
		init := FnOleInitialize(ole_init)
		init(unsafe { nil })
	}
}
