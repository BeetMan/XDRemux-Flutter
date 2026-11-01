param([Parameter(Mandatory=$true)][string]$FixtureDirectory)
$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot ('results/loopback-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$binary=Join-Path $PSScriptRoot 'target/windows/release/xdremux-transfer-poc.exe'
$files=@(Get-ChildItem -LiteralPath $FixtureDirectory -File)
if($files.Count -eq 0){throw 'No fixtures'}
$port=Get-Random -Minimum 35000 -Maximum 55000
$pin=[guid]::NewGuid().ToString('N')
function Start-TestProcess([string[]]$Arguments,[string]$LogName) {
    foreach($argument in $Arguments){if($argument.Contains('"')){throw 'Double quotes in arguments are not supported'}}
    $text=($Arguments | ForEach-Object {'"'+$_+'"'}) -join ' '
    Start-Process -FilePath $binary -ArgumentList $text -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root "$LogName.stdout") -RedirectStandardError (Join-Path $root "$LogName.stderr")
}
$receiver=Start-TestProcess @('receive','--dir',(Join-Path $root 'received'),'--port',([string]$port),'--seconds','12','--pin',$pin,'--accept-test-files','--report',(Join-Path $root 'received.json')) 'receiver'
$sender=$null
try {
    $deadline=[DateTime]::UtcNow.AddSeconds(8)
    do {
        if($receiver.HasExited){throw 'Receiver failed'}
        Start-Sleep -Milliseconds 50
        $ready=Get-Content -LiteralPath (Join-Path $root 'receiver.stdout') -Raw
    } until(($ready -match '"event":"ready"') -or [DateTime]::UtcNow -gt $deadline)
    if($ready -notmatch '"event":"ready"'){throw 'Ready timeout'}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $sender=Start-TestProcess (@('send','--host','127.0.0.1','--port',([string]$port),'--pin',$pin,'--report',(Join-Path $root 'sent.json'))+@($files.FullName)) 'sender'
    $sampledPeak=0L
    $sampledCpuMs=0.0
    while(-not $sender.HasExited){$sender.Refresh(); $sampledPeak=[Math]::Max($sampledPeak,$sender.WorkingSet64); $sampledCpuMs=[Math]::Max($sampledCpuMs,$sender.TotalProcessorTime.TotalMilliseconds); Start-Sleep -Milliseconds 5}
    $sender.WaitForExit()
    $clock.Stop()
    if($sender.ExitCode -ne 0){throw 'Send failed'}
    $receiver.WaitForExit()
    if($receiver.ExitCode -ne 0){throw 'Receive failed'}
    $received=@(Get-Content -LiteralPath (Join-Path $root 'received.json') -Raw | ConvertFrom-Json)
    if($received.Count -ne $files.Count){throw 'File count differs'}
    foreach($file in $files){
        $actual=@($received | Where-Object {$_.name -eq $file.Name})
        if($actual.Count -ne 1 -or -not $actual[0].success -or $actual[0].size -ne $file.Length -or $actual[0].sha256 -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'Integrity mismatch'}
    }
    $summary=[pscustomobject]@{files=$files.Count;bytes=($files | Measure-Object Length -Sum).Sum;wallMs=$clock.ElapsedMilliseconds;sampledPeakWorkingSetBytes=$sampledPeak;sampledCpuMs=$sampledCpuMs;receiverStartupMs=($ready | ConvertFrom-Json).startup_ms;allLengthsAndSha256Match=$true}
    $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'summary.json') -Encoding UTF8
    $summary | Format-List
    Write-Output "Evidence: $root"
} finally {
    foreach($process in @($sender,$receiver)){if($null -ne $process -and -not $process.HasExited){$process.Kill()}}
}
