<#
  Register-EmoryDailyReviewTask.ps1 - schedule the END-OF-DAY review (Task Scheduler, current user).

  Runs emory_daily_review.ps1 -Auto every weekday at 17:30 local. It ALWAYS saves the day's review to
  Downloads\Emory_Daily_Reviews\<date>.html/.md, and posts to #api-support-intake ONLY while
  Downloads\emory_autopost.txt reads "on" (the same revocable toggle as the cards). Days with no cases
  are not posted.

  Run once, as yourself (no elevation needed):
    powershell -ExecutionPolicy Bypass -File ~/.claude/skills/emory/Register-EmoryDailyReviewTask.ps1
  Remove:
    Unregister-ScheduledTask -TaskName 'Emory End-of-Day Review' -Confirm:$false
  Change the time with -At '17:00'.
#>
[CmdletBinding()]
param([string]$At = '17:30', [string]$TaskName = 'Emory End-of-Day Review')

$script = Join-Path $PSScriptRoot 'emory_daily_review.ps1'
if (-not (Test-Path -LiteralPath $script)) { throw "emory_daily_review.ps1 not found next to this script" }

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Auto"
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At $At
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'Builds Emory''s end-of-day review of every case run today (saved locally; posted to #api-support-intake only while emory_autopost.txt = on).' -Force | Out-Null
Write-Host "Registered '$TaskName': weekdays at $At -> emory_daily_review.ps1 -Auto (always saves; posts only while emory_autopost.txt = on)." -ForegroundColor Green
