param(
    [switch]$Check,
    [switch]$InstallShortcut
)

$ErrorActionPreference = 'SilentlyContinue'
$LauncherRoot = Split-Path -Parent $PSScriptRoot

function Read-IniConfig {
    $cfg = @{ MANUAL_PROXY = ""; IDE_PATH = "" }
    $iniPath = Join-Path $LauncherRoot "config.ini"
    if (-not (Test-Path -LiteralPath $iniPath)) { return $cfg }
    foreach ($line in (Get-Content -LiteralPath $iniPath -Encoding UTF8)) {
        $trim = $line.Trim()
        if (-not $trim -or $trim.StartsWith('#') -or $trim.StartsWith(';')) { continue }
        if ($trim -match '^([A-Za-z0-9_]+)\s*=\s*(.*)$') {
            $cfg[$Matches[1].ToUpper()] = $Matches[2].Trim().Trim('"')
        }
    }
    return $cfg
}

function Test-TcpAlive {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 150)
    if (-not $HostName -or $Port -le 0 -or $Port -gt 65535) { return $false }
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $tcp.EndConnect($ar)
            return $true
        }
    } catch {} finally {
        if ($tcp) { try { $tcp.Close() } catch {} }
    }
    return $false
}

function ConvertFrom-ProxyString {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $s = $Raw.Trim()

    if ($s -match '^\d+$') {
        return @{ Url = "http://127.0.0.1:$s"; Host = "127.0.0.1"; Port = [int]$s }
    }

    # Windows multi-protocol string: "http=127.0.0.1:7890;https=127.0.0.1:7890;socks=127.0.0.1:7891"
    if ($s -match '=') {
        $map = @{}
        foreach ($part in ($s -split ';')) {
            if ($part -match '^\s*([a-zA-Z0-9]+)\s*=\s*(.+?)\s*$') {
                $map[$Matches[1].ToLower()] = $Matches[2]
            }
        }
        $pickedScheme = 'http'
        $pickedVal = $null
        if ($map.ContainsKey('https')) { $pickedVal = $map['https'] }
        elseif ($map.ContainsKey('http')) { $pickedVal = $map['http'] }
        elseif ($map.ContainsKey('socks')) { $pickedScheme = 'socks5'; $pickedVal = $map['socks'] }
        if (-not $pickedVal) { return $null }
        $s = if ($pickedVal -match '^[a-zA-Z0-9]+://') { $pickedVal } else { "${pickedScheme}://$pickedVal" }
    } elseif ($s -notmatch '^[a-zA-Z0-9]+://') {
        $s = "http://$s"
    }

    $s = ($s -replace '^socks://', 'socks5://').TrimEnd('/')
    if ($s -notmatch ':\d+$') { return $null }
    try {
        $uri = [Uri]$s
        if ($uri.Host -and $uri.Port -gt 0) {
            return @{ Url = "$($uri.Scheme)://$($uri.Host):$($uri.Port)"; Host = $uri.Host; Port = $uri.Port }
        }
    } catch {}
    return $null
}

function Test-LoopbackProxyKind {
    param([int]$Port, [string]$HostName = '127.0.0.1')
    if ($Port -le 0 -or $Port -gt 65535) { return $null }
    $urlHost = if ($HostName -eq '::1') { '[::1]' } else { $HostName }

    # Single TCP connection checks liveness + HTTP proxy behavior without touching external internet
    $tcp = $null
    $connected = $false
    try {
        $family = if ($HostName -eq '::1') { [System.Net.Sockets.AddressFamily]::InterNetworkV6 } else { [System.Net.Sockets.AddressFamily]::InterNetwork }
        $tcp = New-Object System.Net.Sockets.TcpClient($family)
        $ar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(120)) { return $null }
        $tcp.EndConnect($ar)
        $connected = $true
        $tcp.ReceiveTimeout = 180
        $tcp.SendTimeout = 180
        $stream = $tcp.GetStream()
        $req = [System.Text.Encoding]::ASCII.GetBytes("GET / HTTP/1.1`r`nHost: ${urlHost}:$Port`r`nConnection: close`r`n`r`n")
        $stream.Write($req, 0, $req.Length)
        $buf = New-Object byte[] 512
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -gt 0) {
            $resp = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
            if ($resp -match '^HTTP/1\.\d\s+(400|403|405|407|501)\b' -and $resp -notmatch '"hello"\s*:') {
                return "http://${urlHost}:$Port"
            }
            if ($resp -match '^HTTP/') {
                return $null
            }
        }
    } catch {} finally {
        if ($tcp) { try { $tcp.Close() } catch {} }
    }
    if (-not $connected) { return $null }

    # Fallback: SOCKS5 handshake probe (0x05 0x01 0x00 -> 0x05 0x00)
    try {
        $family = if ($HostName -eq '::1') { [System.Net.Sockets.AddressFamily]::InterNetworkV6 } else { [System.Net.Sockets.AddressFamily]::InterNetwork }
        $tcp = New-Object System.Net.Sockets.TcpClient($family)
        $ar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(120)) { return $null }
        $tcp.EndConnect($ar)
        $tcp.ReceiveTimeout = 150
        $tcp.SendTimeout = 150
        $stream = $tcp.GetStream()
        $stream.Write([byte[]]@(5, 1, 0), 0, 3)
        $buf = New-Object byte[] 16
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -ge 2 -and $buf[0] -eq 5 -and $buf[1] -eq 0) {
            return "socks5://${urlHost}:$Port"
        }
    } catch {} finally {
        if ($tcp) { try { $tcp.Close() } catch {} }
    }
    return $null
}

function Resolve-PacProxy {
    param([string]$PacUrl)
    if ([string]::IsNullOrWhiteSpace($PacUrl) -or $PacUrl -notmatch '^https?://(127\.0\.0\.1|localhost)(:\d+)?/') { return $null }
    try {
        $req = [System.Net.HttpWebRequest]::Create($PacUrl)
        $req.Proxy = $null
        $req.Timeout = 500
        $req.ReadWriteTimeout = 500
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $reader.ReadToEnd()
        $reader.Close()
        $resp.Close()
        if ($body -match '\bPROXY\s+([0-9A-Za-z\.\-]+:\d+)') {
            return ConvertFrom-ProxyString $Matches[1]
        }
        if ($body -match '\bSOCKS5?\s+([0-9A-Za-z\.\-]+:\d+)') {
            return ConvertFrom-ProxyString ("socks5://" + $Matches[1])
        }
    } catch {}
    return $null
}

function Resolve-ProxyEndpoint {
    param([hashtable]$Config)
    $preferredOrder = @(7890, 7892, 7897, 10809, 10808, 2080, 1080, 7891, 7893, 8118, 7899, 20171, 20172)
    $ignoredApiPorts = @(9090, 9097, 10085, 10810, 8045)

    # 0. config.ini manual override
    if (-not [string]::IsNullOrWhiteSpace($Config['MANUAL_PROXY'])) {
        $parsed = ConvertFrom-ProxyString $Config['MANUAL_PROXY']
        if ($parsed) {
            $alive = Test-TcpAlive $parsed.Host $parsed.Port
            return @{ Url = $parsed.Url; Source = "config.ini MANUAL_PROXY (Alive=$alive)" }
        }
    }

    # 1. Windows System Proxy Registry (ProxyServer / AutoConfigURL)
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($reg) {
        if ($reg.ProxyEnable -eq 1 -and $reg.ProxyServer) {
            $parsed = ConvertFrom-ProxyString $reg.ProxyServer
            if ($parsed -and (Test-TcpAlive $parsed.Host $parsed.Port)) {
                return @{ Url = $parsed.Url; Source = "WindowsSystemProxy ($($reg.ProxyServer))" }
            }
        }
        if ($reg.AutoConfigURL) {
            $pac = Resolve-PacProxy $reg.AutoConfigURL
            if ($pac -and (Test-TcpAlive $pac.Host $pac.Port)) {
                return @{ Url = $pac.Url; Source = "WindowsSystemPAC ($($reg.AutoConfigURL))" }
            }
        }
    }

    # 2. Active Proxy Core Processes (when System Proxy is OFF)
    $coreRegex = '^(MoonCloudCore|xray|v2ray|mihomo.*|clash.*|verge-mihomo|sing-box|nekobox|nekoray|flclash.*|hiddify.*|ss-local|Shadowsocks.*|naive|hysteria.*|tuic.*|privoxy|trojan.*|v2raya|sstap|netch)$'
    $coreProcs = Get-Process | Where-Object { $_.ProcessName -match $coreRegex }
    if ($coreProcs) {
        $pidMap = @{}
        foreach ($p in $coreProcs) { $pidMap["$($p.Id)"] = $p.ProcessName }
        $candidates = @()
        $seenPorts = @{}
        foreach ($line in (netstat -ano -p tcp | Select-String 'LISTENING')) {
            if ($line -match '^\s*TCP\s+(\S+):(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$') {
                $addr = $Matches[1]; $port = [int]$Matches[2]; $pidStr = $Matches[3]
                if ($pidMap.ContainsKey($pidStr) -and $addr -in @('127.0.0.1','0.0.0.0','[::]','[::1]') -and ($port -notin $ignoredApiPorts)) {
                    $probeHost = if ($addr -eq '[::1]') { '::1' } else { '127.0.0.1' }
                    $key = "${probeHost}:$port"
                    if (-not $seenPorts.ContainsKey($key)) {
                        $seenPorts[$key] = $true
                        $rank = [Array]::IndexOf($preferredOrder, $port)
                        $candidates += [PSCustomObject]@{ Port = $port; Host = $probeHost; Proc = $pidMap[$pidStr]; SortKey = $(if ($rank -ge 0) { $rank } else { 9999 + $port }) }
                    }
                }
            }
        }
        foreach ($item in ($candidates | Sort-Object SortKey)) {
            $url = Test-LoopbackProxyKind -Port $item.Port -HostName $item.Host
            if ($url) {
                return @{ Url = $url; Source = "CoreProcess ($($item.Proc)@$($item.Host):$($item.Port))" }
            }
        }
    }

    # 3. Existing User/Machine Proxy Environment Variables (liveness-verified)
    foreach ($envName in @('HTTPS_PROXY', 'HTTP_PROXY', 'https_proxy', 'http_proxy')) {
        $val = [Environment]::GetEnvironmentVariable($envName, 'User')
        if (-not $val) { $val = [Environment]::GetEnvironmentVariable($envName, 'Machine') }
        if ($val) {
            $parsed = ConvertFrom-ProxyString $val
            if ($parsed -and (Test-TcpAlive $parsed.Host $parsed.Port)) {
                return @{ Url = $parsed.Url; Source = "SystemEnv ($envName)" }
            }
        }
    }

    # 4. Common Proxy Ports Fallback Probe
    foreach ($p in @(7890, 7892, 7897, 10809, 10808, 2080, 1080, 7891, 7893, 8118, 7899)) {
        $url = Test-LoopbackProxyKind -Port $p
        if ($url) {
            return @{ Url = $url; Source = "CommonPortProbe ($p)" }
        }
    }

    # 5. Pure TUN / Direct fallback
    return @{ Url = $null; Source = "Direct/TUN (No live local HTTP/SOCKS proxy port)" }
}

function Resolve-IdePath {
    param([hashtable]$Config)

    # 0. config.ini override
    if (-not [string]::IsNullOrWhiteSpace($Config['IDE_PATH']) -and (Test-Path -LiteralPath $Config['IDE_PATH'])) {
        return $Config['IDE_PATH']
    }

    # 1. Sibling / Standard install locations
    $candidates = @(
        (Join-Path $LauncherRoot 'Antigravity.exe'),
        (Join-Path $LauncherRoot 'app\Antigravity.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'),
        (Join-Path $env:ProgramFiles 'Antigravity\Antigravity.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Antigravity\Antigravity.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }

    # 2. Uninstall registry keys (HKCU + HKLM + Wow6432)
    $hives = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $found = Get-ItemProperty $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'Antigravity' } |
            ForEach-Object {
                if ($_.InstallLocation) {
                    Join-Path $_.InstallLocation 'Antigravity.exe'
                    Join-Path $_.InstallLocation 'app\Antigravity.exe'
                }
                if ($_.DisplayIcon) {
                    $iconPath = ($_.DisplayIcon -split ',')[0].Trim('"')
                    if ($iconPath -like '*Antigravity.exe') { $iconPath }
                }
            } |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
            Select-Object -First 1
        if ($found) { return $found }
    }

    # 3. Fixed drive common directories (handles portable / non-C: custom installs without registry)
    foreach ($drv in ([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })) {
        foreach ($sub in @('Programs\antigravity\Antigravity.exe', 'Antigravity\Antigravity.exe', 'Program Files\Antigravity\Antigravity.exe')) {
            $p = Join-Path $drv.RootDirectory.FullName $sub
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }

    # 4. Start Menu / Desktop shortcuts
    $sh = New-Object -ComObject WScript.Shell
    $lnkDirs = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        ([Environment]::GetFolderPath('Desktop'))
    )
    foreach ($d in $lnkDirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d -Recurse -Filter '*Antigravity*.lnk' -ErrorAction SilentlyContinue)) {
            $t = $sh.CreateShortcut($f.FullName).TargetPath
            if ($t -and ($t -like '*Antigravity.exe') -and (Test-Path -LiteralPath $t)) { return $t }
        }
    }

    $cmd = Get-Command 'Antigravity.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-GoogleBackendReachable {
    param([string]$ProxyUrl)
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { return "SKIP (curl.exe missing)" }
    $curlArgs = @('-s', '-o', 'NUL', '-w', '%{http_code}', '--max-time', '4')
    if ($ProxyUrl) {
        $curlProxy = $ProxyUrl -replace '^socks5://', 'socks5h://'
        $curlArgs += @('-x', $curlProxy)
    }
    $curlArgs += 'https://daily-cloudcode-pa.googleapis.com/'
    $code = & curl.exe @curlArgs 2>$null
    if ($code -and $code -ne '000') {
        return "OK (HTTP $code - Google backend reachable)"
    }
    return "FAIL (Timeout/Blocked - check VPN node or TUN routing)"
}

$cfg = Read-IniConfig
$idePath = Resolve-IdePath -Config $cfg

if ($InstallShortcut) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $vbsPath = Join-Path $LauncherRoot '1-静默启动Antigravity.vbs'
    if (-not (Test-Path -LiteralPath $vbsPath)) {
        Write-Host "[ERROR] Missing VBS launcher: $vbsPath" -ForegroundColor Red
        exit 1
    }
    $lnkPath = Join-Path $desktop 'Antigravity-RE.lnk'
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($lnkPath)
    $lnk.TargetPath = "$env:SystemRoot\System32\wscript.exe"
    $lnk.Arguments = "`"$vbsPath`""
    $lnk.WorkingDirectory = $LauncherRoot
    if ($idePath) { $lnk.IconLocation = "$idePath,0" }
    $lnk.Description = "Antigravity IDE (Universal Proxy Auto-Detect)"
    $lnk.Save()
    Write-Host "[OK] Desktop shortcut created: $lnkPath" -ForegroundColor Green
    if (-not $idePath) {
        Write-Host "[WARN] Antigravity.exe not detected yet; configure IDE_PATH in config.ini if installed in a custom folder." -ForegroundColor Yellow
    }
    exit 0
}

$proxyInfo = Resolve-ProxyEndpoint -Config $cfg

if ($Check) {
    Write-Host "=== Antigravity 通用启动器环境诊断 ===" -ForegroundColor Cyan
    Write-Host "Launcher : $LauncherRoot"
    Write-Host "IDE Path : $(if ($idePath) { $idePath } else { 'NOT FOUND (可在 config.ini 指定 IDE_PATH)' })"
    Write-Host "Proxy    : $(if ($proxyInfo.Url) { $proxyInfo.Url } else { 'NONE (纯 TUN / 直连模式)' })"
    Write-Host "Source   : $($proxyInfo.Source)"
    Write-Host "Backend  : Probing https://daily-cloudcode-pa.googleapis.com ..."
    $reach = Test-GoogleBackendReachable -ProxyUrl $proxyInfo.Url
    Write-Host "Result   : $reach" -ForegroundColor $(if ($reach -like 'OK*') { 'Green' } else { 'Yellow' })
    exit $(if ($idePath) { 0 } else { 1 })
}

if (-not $idePath) {
    $ws = New-Object -ComObject WScript.Shell
    $ws.Popup("未在当前电脑找到 Antigravity.exe。`r`n请确认已安装 Antigravity，或在启动器目录 config.ini 中填写 IDE_PATH。", 6, "Antigravity 启动失败", 16) | Out-Null
    exit 1
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $idePath
$psi.WorkingDirectory = Split-Path -Parent $idePath
$psi.UseShellExecute = $true
$psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal

if ($proxyInfo.Url) {
    $env:HTTP_PROXY  = $proxyInfo.Url
    $env:HTTPS_PROXY = $proxyInfo.Url
    $env:http_proxy  = $proxyInfo.Url
    $env:https_proxy = $proxyInfo.Url
    $env:ALL_PROXY   = $proxyInfo.Url
    $env:all_proxy   = $proxyInfo.Url
    $existingNoProxy = if ($env:NO_PROXY) { $env:NO_PROXY } elseif ($env:no_proxy) { $env:no_proxy } else { '' }
    $noProxyParts = @($existingNoProxy -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($reqHost in @('localhost', '127.0.0.1', '::1')) {
        if ($noProxyParts -notcontains $reqHost) { $noProxyParts += $reqHost }
    }
    $env:NO_PROXY = $env:no_proxy = ($noProxyParts -join ',')
    $psi.Arguments   = "--proxy-server=`"$($proxyInfo.Url)`""
} else {
    foreach ($k in 'HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy','ALL_PROXY','all_proxy') {
        Remove-Item "Env:$k" -ErrorAction SilentlyContinue
    }
}

[System.Diagnostics.Process]::Start($psi) | Out-Null