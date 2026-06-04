#!/usr/bin/env pwsh
# DNS stress test for AdGuard → Unbound pipeline.
# Uses raw UDP DNS packets with 2s timeout for high throughput.
#
# Usage:
#   ./scripts/dns-stress.ps1                        # defaults: 8 threads, 60s
#   ./scripts/dns-stress.ps1 -Server 192.168.10.3 -Threads 16 -DurationSec 120

param(
    [string]$Server = "",
    [int]$Threads = 8,
    [int]$DurationSec = 60,
    [int]$TimeoutMs = 500
)

$ErrorActionPreference = "Stop"

# --- Domain pools --------------------------------------------------------

$dnssecDomains = @(
    "cloudflare.com", "google.com", "verisign.com", "nic.cz",
    "isc.org", "nlnetlabs.nl", "ripe.net", "ietf.org", "icann.org",
    "switch.ch", "internetsociety.org", "apnic.net", "lacnic.net"
)

$popularDomains = @(
    "github.com", "stackoverflow.com", "microsoft.com", "apple.com",
    "amazon.com", "netflix.com", "reddit.com", "wikipedia.org",
    "twitter.com", "linkedin.com", "docker.com", "kubernetes.io",
    "grafana.com", "prometheus.io", "debian.org", "ubuntu.com",
    "archlinux.org", "nginx.org", "apache.org", "python.org",
    "nodejs.org", "rust-lang.org", "golang.org", "ruby-lang.org",
    "php.net", "npmjs.com", "pypi.org", "cloudflare.com",
    "akamai.com", "fastly.com", "letsencrypt.org"
)

$bigRecordDomains = @(
    "google.com", "microsoft.com", "amazon.com", "facebook.com",
    "salesforce.com", "hubspot.com", "mailchimp.com", "sendgrid.net",
    "outlook.com", "yahoo.com"
)

$dkimSelectors = @("google._domainkey", "selector1._domainkey", "selector2._domainkey", "s1._domainkey")

$allDomains = ($dnssecDomains + $popularDomains) | Sort-Object { Get-Random }

# --- Auto-detect DNS server -----------------------------------------------

if (-not $Server) {
    $iface = Get-DnsClientServerAddress -AddressFamily IPv4 |
        Where-Object { $_.ServerAddresses.Count -gt 0 } |
        Select-Object -First 1
    if ($iface) { $Server = $iface.ServerAddresses[0] }
    else { $Server = "192.168.10.3" }
}

# --- Worker scriptblock (runs in RunspacePool) ----------------------------

# DNS record type codes
$qtypeMap = @{ A=1; AAAA=28; MX=15; TXT=16; NS=2; SOA=6; SRV=33; CNAME=5; CAA=257; PTR=12 }
$queryTypes = @("A", "AAAA", "MX", "TXT", "NS", "SOA", "SRV", "CNAME", "CAA", "PTR")

$worker = {
    param($id, $server, $port, $durationSec, $timeoutMs, $domains, $dnssecDomains,
          $bigRecordDomains, $dkimSelectors, $queryTypes, $qtypeMap)

    # Build a raw DNS query packet
    function New-DnsQuery([string]$name, [int]$qtype) {
        $ms = [System.IO.MemoryStream]::new()
        $bw = [System.IO.BinaryWriter]::new($ms)
        # Header: random ID, RD=1, 1 question
        $txid = [System.BitConverter]::GetBytes([uint16](Get-Random -Max 65535))
        $bw.Write($txid[1]); $bw.Write($txid[0])  # ID (big-endian)
        $bw.Write([byte]0x01); $bw.Write([byte]0x00)  # flags: RD=1
        $bw.Write([byte]0x00); $bw.Write([byte]0x01)  # QDCOUNT=1
        $bw.Write([byte]0x00); $bw.Write([byte]0x00)  # ANCOUNT=0
        $bw.Write([byte]0x00); $bw.Write([byte]0x00)  # NSCOUNT=0
        $bw.Write([byte]0x00); $bw.Write([byte]0x00)  # ARCOUNT=0
        # Question section
        foreach ($label in $name.Split('.')) {
            $bw.Write([byte]$label.Length)
            $bw.Write([System.Text.Encoding]::ASCII.GetBytes($label))
        }
        $bw.Write([byte]0x00)  # root label
        $qt = [System.BitConverter]::GetBytes([uint16]$qtype)
        $bw.Write($qt[1]); $bw.Write($qt[0])  # QTYPE (big-endian)
        $bw.Write([byte]0x00); $bw.Write([byte]0x01)  # QCLASS=IN
        $bw.Flush()
        $ms.ToArray()
    }

    $rng = [System.Random]::new($id * 31 + [System.Environment]::TickCount)
    $deadline = [datetime]::UtcNow.AddSeconds($durationSec)
    $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($server), $port)

    $ok = 0; $fail = 0; $timeout = 0; $dnssecQ = 0; $tcpQ = 0; $total = 0
    $latencies = [System.Collections.Generic.List[double]]::new(4096)

    $udp = [System.Net.Sockets.UdpClient]::new()
    $udp.Client.ReceiveTimeout = $timeoutMs
    $udp.Client.SendTimeout = $timeoutMs

    try {
        while ([datetime]::UtcNow -lt $deadline) {
            $roll = $rng.Next(100)
            $name = $null; $qtype = 1

            if ($roll -lt 40) {
                # 40%: random subdomain → guaranteed cache miss
                $base = $domains[$rng.Next($domains.Count)]
                $sub = -join (1..10 | ForEach-Object { [char]$rng.Next(97,123) })
                $name = "$sub.$base"
                $qt = $queryTypes[$rng.Next($queryTypes.Count)]
                $qtype = $qtypeMap[$qt]
            } elseif ($roll -lt 60) {
                # 20%: DNSSEC domain + random subdomain
                $base = $dnssecDomains[$rng.Next($dnssecDomains.Count)]
                $sub = -join (1..8 | ForEach-Object { [char]$rng.Next(97,123) })
                $name = "$sub.$base"
                $qtype = 1  # A
                $dnssecQ++
            } elseif ($roll -lt 75) {
                # 15%: DKIM TXT (large records)
                $base = $bigRecordDomains[$rng.Next($bigRecordDomains.Count)]
                $sel = $dkimSelectors[$rng.Next($dkimSelectors.Count)]
                $name = "$sel.$base"
                $qtype = 16  # TXT
                $tcpQ++
            } elseif ($roll -lt 90) {
                # 15%: real domain, random type
                $base = $domains[$rng.Next($domains.Count)]
                $qt = $queryTypes[$rng.Next($queryTypes.Count)]
                $qtype = $qtypeMap[$qt]
                $name = $base
            } else {
                # 10%: reverse PTR
                $name = "$($rng.Next(1,255)).$($rng.Next(0,256)).$($rng.Next(0,256)).$($rng.Next(1,224)).in-addr.arpa"
                $qtype = 12  # PTR
            }

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $pkt = New-DnsQuery $name $qtype
                [void]$udp.Send($pkt, $pkt.Length, $ep)
                $remoteEp = $ep
                [void]$udp.Receive([ref]$remoteEp)
                $ok++
            }
            catch [System.Net.Sockets.SocketException] {
                $timeout++
            }
            catch {
                $fail++
            }
            $sw.Stop()
            $latencies.Add($sw.Elapsed.TotalMilliseconds)
            $total++
        }
    }
    finally {
        $udp.Close()
    }

    @{ ok = $ok; fail = $fail; timeout = $timeout; dnssec = $dnssecQ; tcp = $tcpQ; total = $total; latencies = $latencies }
}

# --- Launch with RunspacePool ---------------------------------------------

Write-Host "DNS Stress Test" -ForegroundColor Cyan
Write-Host "  Server:   ${Server}:53"
Write-Host "  Threads:  $Threads"
Write-Host "  Duration: ${DurationSec}s"
Write-Host "  Timeout:  ${TimeoutMs}ms per query"
Write-Host "  Domains:  $($allDomains.Count) base"
Write-Host ""
Write-Host "Starting..." -ForegroundColor Yellow

$pool = [runspacefactory]::CreateRunspacePool(1, $Threads)
$pool.Open()

$handles = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()

for ($i = 1; $i -le $Threads; $i++) {
    $ps = [powershell]::Create().AddScript($worker).AddArgument($i).AddArgument($Server).AddArgument(53)
    $ps.AddArgument($DurationSec).AddArgument($TimeoutMs)
    $ps.AddArgument($allDomains).AddArgument($dnssecDomains).AddArgument($bigRecordDomains)
    $ps.AddArgument($dkimSelectors).AddArgument($queryTypes).AddArgument($qtypeMap)
    $ps.RunspacePool = $pool
    $handles += @{ ps = $ps; handle = $ps.BeginInvoke() }
}

# Progress
while ($handles | Where-Object { -not $_.handle.IsCompleted }) {
    $running = ($handles | Where-Object { -not $_.handle.IsCompleted }).Count
    $elapsed = [math]::Round($sw.Elapsed.TotalSeconds)
    Write-Host "`r  [$elapsed/${DurationSec}s] $running threads active" -NoNewline
    Start-Sleep -Seconds 2
}
Write-Host ""
$sw.Stop()

# --- Collect results ------------------------------------------------------

$totals = @{ ok = 0; fail = 0; timeout = 0; dnssec = 0; tcp = 0; total = 0 }
$allLatencies = [System.Collections.Generic.List[double]]::new()

foreach ($h in $handles) {
    $result = $h.ps.EndInvoke($h.handle)
    if ($result) {
        foreach ($r in $result) {
            $totals.ok += $r.ok
            $totals.fail += $r.fail
            $totals.timeout += $r.timeout
            $totals.dnssec += $r.dnssec
            $totals.tcp += $r.tcp
            $totals.total += $r.total
            if ($r.latencies -and $r.latencies.Count -gt 0) {
                $allLatencies.AddRange([double[]]$r.latencies)
            }
        }
    }
    $h.ps.Dispose()
}
$pool.Close()

$qps = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($totals.total / $sw.Elapsed.TotalSeconds, 1) } else { 0 }
$failPct = if ($totals.total -gt 0) { [math]::Round(100 * ($totals.fail + $totals.timeout) / $totals.total, 2) } else { 0 }

Write-Host ""
Write-Host "Results" -ForegroundColor Cyan
Write-Host "  Duration:     $([math]::Round($sw.Elapsed.TotalSeconds, 1))s"
Write-Host "  Total:        $($totals.total) queries"
Write-Host "  Throughput:   $qps q/s"
Write-Host "  Success:      $($totals.ok)"
Write-Host "  Timeout:      $($totals.timeout)"
Write-Host "  Failed:       $($totals.fail) ($failPct% non-ok)"
Write-Host "  DNSSEC:       $($totals.dnssec) queries"
Write-Host "  Big/DKIM:     $($totals.tcp) queries (potential TCP)"

if ($allLatencies.Count -gt 0) {
    $sorted = $allLatencies | Sort-Object
    $count = $sorted.Count
    $min = [math]::Round($sorted[0], 2)
    $max = [math]::Round($sorted[$count - 1], 2)
    $avg = [math]::Round(($sorted | Measure-Object -Average).Average, 2)
    $median = [math]::Round($sorted[[math]::Floor($count * 0.5)], 2)
    $p95 = [math]::Round($sorted[[math]::Floor($count * 0.95)], 2)
    $p99 = [math]::Round($sorted[[math]::Floor($count * 0.99)], 2)

    Write-Host ""
    Write-Host "Latency" -ForegroundColor Cyan
    Write-Host "  Min:          ${min} ms"
    Write-Host "  Avg:          ${avg} ms"
    Write-Host "  Median:       ${median} ms"
    Write-Host "  p95:          ${p95} ms"
    Write-Host "  p99:          ${p99} ms"
    Write-Host "  Max:          ${max} ms"
}
