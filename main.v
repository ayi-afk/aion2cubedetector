module main

import os

// Cube Watch: watches AION 2 game traffic through Npcap and alerts when a
// cube spawns nearby. Runs in the system tray.

const wait_object_0 = u32(0)
const wait_abandoned = u32(0x80)

fn main() {
	start_hidden := '--tray' in os.args
	// `--replay capture.pcapng` plays a saved capture into the window in
	// real time; it runs alongside a normal instance.
	replay_at := os.args.index('--replay')
	if replay_at > 0 {
		if replay_at + 1 >= os.args.len {
			eprintln('usage: cube_watch --replay capture.pcapng')
			exit(2)
		}
		exit(run_app(false, os.real_path(os.args[replay_at + 1])))
	}
	// One instance only; a second launch brings the running window forward.
	mutex := C.CreateMutexW(unsafe { nil }, 0, 'Local\\CubeWatchSingleInstance'.to_wide())
	if C.GetLastError() == error_already_exists {
		if elevated_restart_flag in os.args {
			// Relaunched via "Run as administrator": wait for the previous
			// instance to exit and release the mutex.
			rc := C.WaitForSingleObject(mutex, 15000)
			if rc != wait_object_0 && rc != wait_abandoned {
				return
			}
		} else {
			existing := C.FindWindowW(window_class.to_wide(), unsafe { nil })
			if existing != unsafe { nil } {
				C.PostMessageW(existing, wm_show_instance, 0, 0)
			}
			return
		}
	}
	exit(run_app(start_hidden, ''))
}
