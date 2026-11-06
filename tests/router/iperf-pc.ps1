# iperf3 client loop of the router tests on a Windows PC that has both a cable and Wi-Fi to the
# router. All devices share a 240 s cycle by the clock: the PC runs over the cable at 0 s
# (download) and 30 s (upload), over Wi-Fi at 60 s and 90 s; the phone uses 120 s and 150 s
# (iperf-phone.sh); 180-240 s is left for the router to change its settings. Each run: 4 TCP
# streams for 20 s after 2 s of warm-up, to the iperf3 server at <address> (ports 5201 and 5202).
#
#   powershell -ExecutionPolicy Bypass -File iperf-pc.ps1 -Server <address> [-Iperf <iperf3.exe>]
#
# Stop it with Ctrl+C. The clock of Windows must be synchronised (it is by default).
param([Parameter(Mandatory = $true)][string]$Server, [string]$Iperf)

# Windows PowerShell 5.1 leaves $PSScriptRoot empty in parameter defaults
if (-not $Iperf) { $Iperf = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'iperf3.exe' }

# The IPv4 address of the connected physical adapter of one kind, cable or Wi-Fi
function Get-Addr([bool]$wifi) {
    foreach ($a in Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' }) {
        if (($a.PhysicalMediaType -like '*802.11*') -ne $wifi) { continue }
        $ip = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($ip) { return $ip.IPAddress }
    }
}

function Wait-Slot([int]$second) {
    while (([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % 240) -ne $second) { Start-Sleep -Milliseconds 300 }
}

$cable = Get-Addr $false
$wifi = Get-Addr $true
Write-Host "cable $cable, Wi-Fi $wifi, server $Server"
if (-not $cable -or -not $wifi) {
    # Without an address the runs of that adapter are skipped; show what Windows sees
    Get-NetAdapter -Physical | Format-Table -AutoSize Name, Status, PhysicalMediaType, LinkSpeed
}
if (-not (Test-Path $Iperf)) { Write-Host "no $Iperf"; exit 1 }

$runs = @(
    @{ At = 0;  Port = 5201; Ip = $cable; Down = $true;  Name = 'cable, download' },
    @{ At = 30; Port = 5201; Ip = $cable; Down = $false; Name = 'cable, upload' },
    @{ At = 60; Port = 5202; Ip = $wifi;  Down = $true;  Name = 'Wi-Fi, download' },
    @{ At = 90; Port = 5202; Ip = $wifi;  Down = $false; Name = 'Wi-Fi, upload' }
)
while ($true) {
    foreach ($r in $runs) {
        if (-not $r.Ip) { continue }
        Wait-Slot $r.At
        # Binding to the adapter's address sends the run through that adapter
        $a = @('-c', $Server, '-p', $r.Port, '-B', $r.Ip, '-P', '4', '-t', '20', '-O', '2')
        if ($r.Down) { $a += '-R' }
        Write-Host "$(Get-Date -Format HH:mm:ss) $($r.Name)"
        & $Iperf @a | Select-String -Pattern 'SUM.*(sender|receiver)|error'
    }
}
