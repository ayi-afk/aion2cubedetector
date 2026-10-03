module main

import os

// Npcap can be installed in "Restrict Npcap driver's access to Administrators
// only" mode; capture then fails for non-elevated processes. These helpers
// detect that situation and relaunch the app elevated.

const elevated_restart_flag = '--elevated-restart'
const rrf_rt_reg_dword = u32(0x10)

enum NpcapAccess {
	unknown
	everyone
	admin_only
}

type FnIsUserAnAdmin = fn () int

type FnRegGetValue = fn (voidptr, &u16, &u16, u32, voidptr, voidptr, voidptr) i32

// is_elevated reports whether this process runs with an elevated
// administrator token (UAC "Run as administrator").
fn is_elevated() bool {
	f := proc_address('shell32.dll', 'IsUserAnAdmin')
	if f == unsafe { nil } {
		return false
	}
	is_admin := FnIsUserAnAdmin(f)
	return is_admin() != 0
}

// npcap_access reads the AdminOnly flag the Npcap installer stores in
// HKLM\SYSTEM\CurrentControlSet\Services\npcap\Parameters.
fn npcap_access() NpcapAccess {
	f := proc_address('advapi32.dll', 'RegGetValueW')
	if f == unsafe { nil } {
		return .unknown
	}
	reg_get_value := FnRegGetValue(f)
	mut value := u32(0)
	mut size := u32(sizeof(u32))
	rc := reg_get_value(voidptr(usize(0x80000002)), 'SYSTEM\\CurrentControlSet\\Services\\npcap\\Parameters'.to_wide(),
		'AdminOnly'.to_wide(), rrf_rt_reg_dword, unsafe { nil }, &value, &size)
	if rc != 0 {
		return .unknown
	}
	return if value != 0 { .admin_only } else { .everyone }
}

fn (a NpcapAccess) label() string {
	return match a {
		.unknown { 'unknown' }
		.everyone { 'all users' }
		.admin_only { 'administrators only' }
	}
}

// restart_elevated starts a new elevated instance through the UAC prompt.
// Returns false when the user cancelled the prompt or the launch failed.
fn restart_elevated(owner voidptr) bool {
	f := proc_address('shell32.dll', 'ShellExecuteW')
	if f == unsafe { nil } {
		return false
	}
	shell_execute := FnShellExecute(f)
	exe := os.executable()
	result := shell_execute(owner, 'runas'.to_wide(), exe.to_wide(), elevated_restart_flag.to_wide(),
		os.dir(exe).to_wide(), sw_show)
	// ShellExecute returns a value greater than 32 on success.
	return usize(result) > 32
}
