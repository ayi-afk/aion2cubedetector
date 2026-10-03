# Posts the newest cube_watch_*.rar to the Discord channel with the fix list
# from fixes.txt, then clears that list. Called by upload.bat. The webhook
# URL comes from DISCORD_WEBHOOK in .env (kept out of git) unless -Webhook
# is given.
param(
	[string]$Webhook,
	[switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

if (-not $Webhook -and (Test-Path '.env')) {
	foreach ($line in Get-Content '.env' -Encoding UTF8) {
		if ($line -match '^\s*DISCORD_WEBHOOK\s*=\s*(.+?)\s*$') {
			$Webhook = $Matches[1].Trim('"', "'")
		}
	}
}
if (-not $Webhook) {
	Write-Host 'No webhook: put DISCORD_WEBHOOK=https://discord.com/api/webhooks/... in .env'
	exit 1
}

$fixesFile = 'fixes.txt'
$fixesHeader = @'
# Fixes / changes for the next upload, one per line ('#' lines are ignored).
# upload.bat posts them with the build and then clears this list.
'@

$archive = Get-ChildItem -File -Filter 'cube_watch_*.rar' | Sort-Object Name -Descending | Select-Object -First 1
if (-not $archive) {
	Write-Host 'No cube_watch_*.rar found - run build.bat first.'
	exit 1
}

$fixes = @()
if (Test-Path $fixesFile) {
	$fixes = @(Get-Content $fixesFile -Encoding UTF8 |
		ForEach-Object { $_.Trim() } |
		Where-Object { $_ -ne '' -and -not $_.StartsWith('#') } |
		ForEach-Object { $_ -replace '^[-*]\s*', '' })
}

# cube_watch_2026-10-03_1432.rar -> 2026-10-03 14:32
$label = $archive.BaseName -replace '^cube_watch_', ''
if ($label -match '^(\d{4}-\d{2}-\d{2})_(\d{2})(\d{2})$') { $label = "$($Matches[1]) $($Matches[2]):$($Matches[3])" }

$lines = @("**Build new version: $label**", 'Trial: 7 days from the build time.')
if ($fixes.Count -gt 0) {
	$lines += ''
	$lines += 'Fixes:'
	$lines += $fixes | ForEach-Object { "- $_" }
}
$content = $lines -join "`n"
if ($content.Length -gt 1990) { $content = $content.Substring(0, 1987) + '...' } # Discord limit: 2000

Write-Host "File: $($archive.Name) ($([math]::Round($archive.Length / 1KB)) KB)"
Write-Host '--- message ---'
Write-Host $content
Write-Host '---------------'
if ($DryRun) {
	Write-Host 'Dry run: nothing sent, fixes.txt unchanged.'
	exit 0
}

$payload = Join-Path $env:TEMP 'cube_watch_upload.json'
$response = Join-Path $env:TEMP 'cube_watch_upload_response.txt'
[IO.File]::WriteAllText($payload, (@{ content = $content } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$code = & $curl -sS -o $response -w '%{http_code}' -F "payload_json=<$payload" -F "files[0]=@$($archive.FullName)" $Webhook
Remove-Item $payload -ErrorAction SilentlyContinue
if ($code -ne '200' -and $code -ne '204') {
	Write-Host "Upload failed (HTTP $code):"
	if (Test-Path $response) { Get-Content $response | Write-Host }
	Write-Host 'fixes.txt was kept.'
	exit 1
}
Remove-Item $response -ErrorAction SilentlyContinue
[IO.File]::WriteAllText((Join-Path (Get-Location) $fixesFile), $fixesHeader + "`r`n", (New-Object Text.UTF8Encoding $false))
Write-Host "Uploaded $($archive.Name). fixes.txt cleared."
