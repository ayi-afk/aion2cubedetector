module main

import os

// play_alert plays the configured cube alert without blocking the GUI.
// Returns an error message when the custom file cannot be played.
fn play_alert(mode SoundMode, file string) ! {
	match mode {
		.off {}
		.windows {
			play_windows_sound()
		}
		.melody {
			spawn play_melody()
		}
		.custom {
			play_custom(file)!
		}
	}
}

fn play_windows_sound() {
	play := proc_address('winmm.dll', 'PlaySoundW')
	if play != unsafe { nil } {
		// Uses the sound assigned to "Exclamation" in the Windows sound scheme.
		call_playsound := FnPlaySound(play)
		if call_playsound('SystemExclamation'.to_wide(), unsafe { nil }, snd_alias | snd_async | snd_nodefault) != 0 {
			return
		}
	}
	C.MessageBeep(mb_iconexclamation)
}

// play_melody is the distinct alert from cube_watch.py; it does not depend
// on the Windows sound scheme.
fn play_melody() {
	for note in [[880, 160], [1175, 160], [1568, 320], [880, 160],
		[1568, 320]] {
		if C.Beep(u32(note[0]), u32(note[1])) == 0 {
			C.MessageBeep(mb_iconexclamation)
			return
		}
	}
}

fn play_custom(file string) ! {
	if file == '' {
		return error('No custom sound file selected.')
	}
	if !os.is_file(file) {
		return error('Sound file not found: ${file}')
	}
	if os.file_ext(file).to_lower() == '.wav' {
		play := proc_address('winmm.dll', 'PlaySoundW')
		if play == unsafe { nil } {
			return error('winmm.dll is unavailable')
		}
		call_playsound := FnPlaySound(play)
		if call_playsound(file.to_wide(), unsafe { nil }, snd_filename | snd_async | snd_nodefault) == 0 {
			return error('Windows could not play ${file}')
		}
		return
	}
	// MCI handles compressed formats such as MP3 and WMA.
	mci := proc_address('winmm.dll', 'mciSendStringW')
	if mci == unsafe { nil } {
		return error('winmm.dll is unavailable')
	}
	send := FnMciSendString(mci)
	send('close cubewatch_alert'.to_wide(), unsafe { nil }, 0, unsafe { nil })
	path := file.replace('"', '')
	if send('open "${path}" type mpegvideo alias cubewatch_alert'.to_wide(), unsafe { nil },
		0, unsafe { nil }) != 0 {
		return error('Windows could not open ${file}')
	}
	if send('play cubewatch_alert'.to_wide(), unsafe { nil }, 0, unsafe { nil }) != 0 {
		return error('Windows could not play ${file}')
	}
}
