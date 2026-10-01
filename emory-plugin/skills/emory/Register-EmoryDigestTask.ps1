<#
  Register-EmoryDigestTask.ps1 - schedule the daily digest (Windows Task Scheduler, current user).

  Runs emory_digest.ps1 -Auto every weekday at 08:00 local. -Auto posts ONLY while
  Downloads\emory_autopost.txt reads "on" (the same revocable toggle the verdict cards use), and
  the digest itself stays silent on days with nothing to report. So registering this task adds
  no new standing authorization beyond what hands-off posting already has.

  Run once, as yourself (no elevation needed):
    powershell -ExecutionPolicy Bypass -File ~/.claude/skills/emory/Register-EmoryDigestTask.ps1
  Remove:
    Unregister-ScheduledTask -TaskName 'Emory Daily Digest' -Confirm:$false
  Change the hour with -At '07:30'.
#>
[CmdletBinding()]
param([string]$At = '08:00', [string]$TaskName = 'Emory Daily Digest')

$script = Join-Path $PSScriptRoot 'emory_digest.ps1'
if (-not (Test-Path -LiteralPath $script)) { throw "emory_digest.ps1 not found next to this script" }

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Auto"
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At $At
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'Posts Emory''s daily digest to #api-support-intake (weekdays, gated by emory_autopost.txt).' -Force | Out-Null
Write-Host "Registered '$TaskName': weekdays at $At -> emory_digest.ps1 -Auto (posts only while emory_autopost.txt = on)." -ForegroundColor Green
