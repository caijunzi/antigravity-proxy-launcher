$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$launcherSrc = Join-Path $repoRoot "launcher"
$ps1Path = Join-Path $launcherSrc "core\launch.ps1"

$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ps1Path, [ref]$tokens, [ref]$errs)
if ($errs.Count -gt 0) { throw "Syntax error in launch.ps1: $($errs | Out-String)" }
$LauncherRoot = $launcherSrc
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    Invoke-Expression $fn.Extent.Text
}

function Assert-Eq($actual, $expected, $name) {
    if ($actual -ne $expected) { throw "FAIL [$name]: expected '$expected', got '$actual'" }
    Write-Host "PASS [$name]: $actual"
}

# 1. Proxy parser edge cases
Assert-Eq (ConvertFrom-ProxyString "127.0.0.1:7892").Url "http://127.0.0.1:7892" "bare host:port"
Assert-Eq (ConvertFrom-ProxyString "10809").Url "http://127.0.0.1:10809" "pure port"
Assert-Eq (ConvertFrom-ProxyString "http=127.0.0.1:7890;https=127.0.0.1:7897;socks=127.0.0.1:7891").Url "http://127.0.0.1:7897" "multi-proto prefers https"
Assert-Eq (ConvertFrom-ProxyString "socks=127.0.0.1:10808").Url "socks5://127.0.0.1:10808" "socks= scheme"
Assert-Eq (ConvertFrom-ProxyString "socks://127.0.0.1:10808").Url "socks5://127.0.0.1:10808" "socks:// normalized"
Assert-Eq (ConvertFrom-ProxyString "http://127.0.0.1:7892/").Url "http://127.0.0.1:7892" "trailing slash stripped"
Assert-Eq (ConvertFrom-ProxyString "http://localhost") $null "missing explicit port rejected"
Assert-Eq (ConvertFrom-ProxyString "") $null "empty string"
Assert-Eq (ConvertFrom-ProxyString "not_a_proxy") $null "garbage string"

# 2. Loopback protocol probe & PAC mocks
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

public static class RepoMockNet {
    public static int StartHttpReply(byte[] reply, bool ipv6 = false) {
        var l = new TcpListener(ipv6 ? IPAddress.IPv6Loopback : IPAddress.Loopback, 0);
        l.Start();
        int port = ((IPEndPoint)l.LocalEndpoint).Port;
        Task.Run(() => {
            try {
                using (var c = l.AcceptTcpClient())
                using (var s = c.GetStream()) {
                    byte[] buf = new byte[512];
                    s.Read(buf, 0, buf.Length);
                    s.Write(reply, 0, reply.Length);
                    s.Flush();
                }
            } catch {} finally { try { l.Stop(); } catch {} }
        });
        return port;
    }

    public static int StartSocks5Only() {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        int port = ((IPEndPoint)l.LocalEndpoint).Port;
        Task.Run(() => {
            try {
                using (var c1 = l.AcceptTcpClient()) {}
                using (var c2 = l.AcceptTcpClient())
                using (var s = c2.GetStream()) {
                    byte[] buf = new byte[16];
                    int n = s.Read(buf, 0, buf.Length);
                    if (n >= 2 && buf[0] == 5) {
                        s.Write(new byte[] { 5, 0 }, 0, 2);
                        s.Flush();
                    }
                }
            } catch {} finally { try { l.Stop(); } catch {} }
        });
        return port;
    }

    public static int StartPac(string pacBody) {
        string resp = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nConnection: close\r\nContent-Length: "
            + Encoding.UTF8.GetByteCount(pacBody) + "\r\n\r\n" + pacBody;
        return StartHttpReply(Encoding.UTF8.GetBytes(resp), false);
    }
}
'@

$pHttp = [RepoMockNet]::StartHttpReply([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 400 Bad Request`r`nConnection: close`r`n`r`n"), $false)
Assert-Eq (Test-LoopbackProxyKind -Port $pHttp) "http://127.0.0.1:$pHttp" "mock HTTP proxy 400"

$pApi = [RepoMockNet]::StartHttpReply([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n`r`n{`"hello`":`"mihomo`"}"))
Assert-Eq (Test-LoopbackProxyKind -Port $pApi) $null "mock Clash API 200 rejected"

$pSocks = [RepoMockNet]::StartSocks5Only()
Assert-Eq (Test-LoopbackProxyKind -Port $pSocks) "socks5://127.0.0.1:$pSocks" "mock SOCKS5-only proxy"

$pV6 = [RepoMockNet]::StartHttpReply([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 400 Bad Request`r`nConnection: close`r`n`r`n"), $true)
Assert-Eq (Test-LoopbackProxyKind -Port $pV6 -HostName '::1') "http://[::1]:$pV6" "mock IPv6 [::1] proxy"

$deadL = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$deadL.Start(); $deadPort = $deadL.LocalEndpoint.Port; $deadL.Stop()
Assert-Eq (Test-LoopbackProxyKind -Port $deadPort) $null "dead port rejected"

$pacPort = [RepoMockNet]::StartPac('function FindProxyForURL(url, host) { return "PROXY 127.0.0.1:10809; DIRECT"; }')
Assert-Eq (Resolve-PacProxy "http://127.0.0.1:$pacPort/proxy.pac").Url "http://127.0.0.1:10809" "local PAC extraction"

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$deadPac = Resolve-PacProxy "http://127.0.0.1:$deadPort/proxy.pac"
$sw.Stop()
Assert-Eq $deadPac $null "dead PAC rejected"
if ($sw.ElapsedMilliseconds -gt 3500) { throw "Dead PAC stalled ($($sw.ElapsedMilliseconds) ms)" }
Write-Host "PASS [dead PAC fast fail]: $($sw.ElapsedMilliseconds) ms"

# 3. Release packaging + Chinese/space path extraction check
& (Join-Path $repoRoot "scripts\build-release.ps1")
$pkgName = "Antigravity通用代理启动器-绿色版"
$zipPath = Join-Path $repoRoot "dist\Antigravity-Proxy-Launcher-Portable.zip"
$testDir = Join-Path $env:TEMP "Repo_测试 空格"
if (Test-Path -LiteralPath $testDir) { Remove-Item -LiteralPath $testDir -Recurse -Force }
Expand-Archive -LiteralPath $zipPath -DestinationPath $testDir -Force
$extracted = Join-Path $testDir $pkgName
if (-not (Test-Path -LiteralPath (Join-Path $extracted "core\launch.ps1"))) { throw "Zip layout check failed" }
$vbsPath = Join-Path $extracted "1-静默启动Antigravity.vbs"
if (-not (Test-Path -LiteralPath $vbsPath)) { throw "Missing VBS: $vbsPath" }
$w = Start-Process -FilePath "wscript.exe" -ArgumentList "//B","`"$vbsPath`"" -PassThru -Wait
Assert-Eq $w.ExitCode 0 "silent VBS execution from Chinese+space path"
Remove-Item -LiteralPath $testDir -Recurse -Force

Write-Host "ALL REPO TESTS PASSED." -ForegroundColor Green
