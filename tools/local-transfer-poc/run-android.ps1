param(
    [Parameter(Mandatory=$true)][string]$AndroidHost,
    [Parameter(Mandatory=$true)][string]$WindowsHost,
    [Parameter(Mandatory=$true)][string]$AdbPath,
    [Parameter(Mandatory=$true)][string]$FixtureDirectory
)
$ErrorActionPreference='Stop'
$parsedIp=$null
if(-not [Net.IPAddress]::TryParse($AndroidHost,[ref]$parsedIp) -or -not [Net.IPAddress]::TryParse($WindowsHost,[ref]$parsedIp)){throw 'Use literal IP addresses'}
$androidPort=Get-Random -Minimum 35000 -Maximum 55000
$windowsPort=$androidPort+1
function Invoke-Adb {
    param([string[]]$Arguments)
    $output = & $AdbPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "ADB failed: $($Arguments[0])" }
    return $output
}
function Start-Tool {
    param([string]$Executable,[string[]]$Arguments,[string]$LogPrefix)
    foreach($argument in $Arguments) {if($argument.Contains('"')) {throw 'Double quotes in arguments are not supported'}}
    $text=($Arguments | ForEach-Object {'"'+$_+'"'}) -join ' '
    Start-Process -FilePath $Executable -ArgumentList $text -WindowStyle Hidden -PassThru -RedirectStandardOutput "$LogPrefix.stdout" -RedirectStandardError "$LogPrefix.stderr"
}
function Wait-Ready {
    param([System.Diagnostics.Process]$Process,[string]$Log)
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    while([DateTime]::UtcNow -lt $deadline) {
        if($Process.HasExited) {throw 'Receiver exited before ready'}
        if(Test-Path -LiteralPath $Log) {
            $readyText=Get-Content -LiteralPath $Log -Raw
            if($readyText -match '"event":"ready"'){return}
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'Receiver readiness timeout'
}
$fixtures=Get-ChildItem -LiteralPath $FixtureDirectory -File
if($fixtures.Count -eq 0 -or ($fixtures | Where-Object {$_.Name -notmatch '^xdremux-poc-[A-Za-z0-9._-]+$'})) {throw 'Only xdremux-poc-* fixtures are accepted'}
$manifest=@($fixtures | ForEach-Object {[pscustomobject]@{name=$_.Name;size=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
$runId=[guid]::NewGuid().ToString('N')
$root=Join-Path $PSScriptRoot "results/android-$runId"
New-Item -ItemType Directory -Path $root | Out-Null
$remote="/data/local/tmp/xdremux-poc-$runId"
$pin=[guid]::NewGuid().ToString('N')
$windowsBinary=Join-Path $PSScriptRoot 'target/windows/release/xdremux-transfer-poc.exe'
$androidBinary=Join-Path $PSScriptRoot 'target/android/aarch64-linux-android/release/xdremux-transfer-poc'
Invoke-Adb @('shell','mkdir','-p',"$remote/fixtures") | Out-Null
Invoke-Adb @('push',$androidBinary,"$remote/poc") | Out-Null
Invoke-Adb @('shell','chmod','700',"$remote/poc") | Out-Null
foreach($file in $fixtures) {Invoke-Adb @('push',$file.FullName,"$remote/fixtures/$($file.Name)") | Out-Null}
$androidReceiver=
$windowsReceiver=
$sender=
try {
$androidReceiver=Start-Tool $AdbPath @('shell',"$remote/poc receive --dir $remote/received --port $androidPort --seconds 35 --pin $pin --accept-test-files --report $remote/received.json") (Join-Path $root 'android-receiver')
Wait-Ready $androidReceiver (Join-Path $root 'android-receiver.stdout')
$winSenderArguments=@('send','--host',$AndroidHost,'--port',$androidPort.ToString(),'--pin',$pin,'--report',(Join-Path $root 'windows-sent.json')) + @($fixtures.FullName)
$clock=[Diagnostics.Stopwatch]::StartNew()
$sender=Start-Tool $windowsBinary $winSenderArguments (Join-Path $root 'windows-sender')
$peakWorkingSet=0L
while(-not $sender.HasExited){$sender.Refresh(); $peakWorkingSet=[Math]::Max($peakWorkingSet,$sender.WorkingSet64); Start-Sleep -Milliseconds 25}
$sender.WaitForExit()
$clock.Stop()
if($sender.ExitCode -ne 0) {throw 'Windows to Android send failed; inspect sender stderr'}
$windowsReceiver=Start-Tool $windowsBinary @('receive','--dir',(Join-Path $root 'windows-received'),'--port',$windowsPort.ToString(),'--seconds','20','--pin',$pin,'--accept-test-files','--report',(Join-Path $root 'windows-received.json')) (Join-Path $root 'windows-receiver')
Wait-Ready $windowsReceiver (Join-Path $root 'windows-receiver.stdout')
$paths=($fixtures | ForEach-Object {"$remote/fixtures/$($_.Name)"}) -join ' '
Invoke-Adb @('shell',"$remote/poc send --host $WindowsHost --port $windowsPort --pin $pin --report $remote/sent.json $paths") | Out-Null
$receiverWorkingSet=$windowsReceiver.WorkingSet64
$windowsReceiver.WaitForExit()
$androidReceiver.WaitForExit()
if($windowsReceiver.ExitCode -ne 0 -or $androidReceiver.ExitCode -ne 0){throw 'A receiver failed; inspect receiver stderr'}
Invoke-Adb @('pull',"$remote/received.json",(Join-Path $root 'android-received.json')) | Out-Null
Invoke-Adb @('pull',"$remote/sent.json",(Join-Path $root 'android-sent.json')) | Out-Null
foreach($name in @('windows-received','android-received')) {
    $actual=@(Get-Content -LiteralPath (Join-Path $root "$name.json") -Raw | ConvertFrom-Json)
    if($actual.Count -ne $manifest.Count){throw "$name file count differs"}
    foreach($expected in $manifest) {
        $file=@($actual | Where-Object {$_.name -eq $expected.name})
        if($file.Count -ne 1 -or -not $file[0].success -or $file[0].size -ne $expected.size -or $file[0].sha256 -ne $expected.sha256){throw "$name failed integrity check"}
    }
}
foreach($expected in $manifest) {if((Get-FileHash -LiteralPath (Join-Path $FixtureDirectory $expected.name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected.sha256){throw 'Source changed'}}
$summary=[pscustomobject]@{
    transport='direct LAN HTTPS; ADB used only for deployment/control/report retrieval'
    filesPerDirection=$manifest.Count
    bytesPerDirection=($manifest | Measure-Object size -Sum).Sum
    windowsSenderWallMs=$clock.ElapsedMilliseconds
    windowsSenderSampledPeakWorkingSetBytes=$peakWorkingSet
    windowsReceiverWorkingSetBytes=$receiverWorkingSet
    allLengthsAndSha256Match=$true
    sourceFilesUnchanged=$true
    remoteTestDirectory=$remote
    fixtures=$manifest
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'summary.json') -Encoding UTF8
$summary | Format-List transport,filesPerDirection,bytesPerDirection,windowsSenderWallMs,windowsSenderSampledPeakWorkingSetBytes,windowsReceiverWorkingSetBytes,allLengthsAndSha256Match
Write-Output "Evidence: $root"

} finally {
    foreach($process in @($sender,$windowsReceiver,$androidReceiver)) {
        if($null -ne $process -and -not $process.HasExited){$process.Kill()}
    }
}
