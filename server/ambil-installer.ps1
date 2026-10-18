<#
  ambil-installer.ps1   [SERVER 192.168.1.88]

  Unduh installer UrBackup Client ke server dengan BEBERAPA KONEKSI SEKALIGUS (file dipotong jadi beberapa bagian
  yang diambil bersamaan lewat HTTP Range, lalu digabung). Berguna kalau host urbackup.org membatasi laju PER KONEKSI,
  sehingga satu koneksi (BITS / browser) sangat lambat.

  - Lanjut otomatis kalau putus atau dihentikan (Ctrl+C): jalankan lagi perintah yang sama, bagian yang sudah ada dipakai.
  - Setelah selesai, SHA256 dibandingkan dengan hash resmi. Cocok -> disimpan sebagai installer untuk PC.
    Beda -> disimpan sebagai <Tujuan>.tidak-cocok dan TIDAK dipakai penerima.
  - Hanya membaca dari -Url dan menulis di -Tujuan (dan berkas .partN di sampingnya). Tidak mengubah apa pun yang lain.

  Contoh (PowerShell di server):
    powershell -ExecutionPolicy Bypass -File ambil-installer.ps1
    powershell -ExecutionPolicy Bypass -File ambil-installer.ps1 -Bagian 16
#>
param(
    [string]$Url    = 'https://hndl.urbackup.org/Client/2.5.32/UrBackup%20Client%202.5.32.exe',
    [string]$Tujuan = 'C:\k8-backup\installer\UrBackupClient.exe',
    [int]$Bagian    = 8,
    # Hash resmi UrBackup Client 2.5.32 (manifest winget UrBackup.UrBackup.Client). Kosongkan untuk tidak memeriksa.
    [string]$Sha256 = '4F531D823DB8CCAA384D383D26BAAB050C3739AE7F9B2E34566F4CA0466BF90A',
    [int]$BatasMs   = 30000,
    [switch]$PakaiProxy
)
$ErrorActionPreference = 'Stop'
if ($Bagian -lt 1) { $Bagian = 1 }
if ($Bagian -gt 32) { $Bagian = 32 }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }
# Bawaan .NET hanya 2 koneksi per host; tanpa ini "paralel" sebenarnya cuma 2.
[Net.ServicePointManager]::DefaultConnectionLimit = 64

function Info($t, $warna) { if ($warna) { Write-Host $t -ForegroundColor $warna } else { Write-Host $t } }
function Ukuran-MB($b) { return ([math]::Round($b / 1MB, 1)).ToString([Globalization.CultureInfo]::InvariantCulture) }
function Hex($bytes) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($x in $bytes) { [void]$sb.Append($x.ToString('x2')) }
    return $sb.ToString()
}
function Sha256-Berkas($berkas) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $f = [IO.File]::OpenRead($berkas)
    try { return (Hex ($sha.ComputeHash($f))) }
    finally { $f.Close(); $sha.Dispose() }
}

# Kerja satu bagian (dijalankan di runspace terpisah). Melanjutkan dari berkas .partN yang ada.
$Pekerja = @'
param($url, $mulai, $akhir, $berkas, $batas, $pakaiProxy, $prog, $idx)
$total = [long]($akhir - $mulai + 1)
$sudah = [long]0
if (Test-Path -LiteralPath $berkas) { $sudah = [long](Get-Item -LiteralPath $berkas).Length }
if ($sudah -gt $total) { Remove-Item -LiteralPath $berkas -Force; $sudah = [long]0 }
$prog[$idx] = $sudah
$galat = ''
$beruntun = 0
while ($sudah -lt $total -and $beruntun -lt 6) {
    $antar = $sudah
    $res = $null; $st = $null; $fs = $null
    try {
        $req = [Net.HttpWebRequest][Net.WebRequest]::Create($url)
        $req.Timeout = $batas
        $req.ReadWriteTimeout = $batas
        $req.UserAgent = 'K8Backup/ambil-installer'
        if (-not $pakaiProxy) { $req.Proxy = $null }
        $req.AddRange([long]($mulai + $sudah), [long]$akhir)
        $res = $req.GetResponse()
        if ([int]$res.StatusCode -ne 206) { throw ('server tidak mendukung unduhan bertahap (HTTP ' + [int]$res.StatusCode + ')') }
        $st = $res.GetResponseStream()
        $fs = New-Object IO.FileStream($berkas, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $buf = New-Object byte[] 65536
        while ($sudah -lt $total) {
            $n = $st.Read($buf, 0, [int][math]::Min([long]$buf.Length, [long]($total - $sudah)))
            if ($n -le 0) { break }
            $fs.Write($buf, 0, $n)
            $sudah += $n
            $prog[$idx] = $sudah
        }
    }
    catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; $galat = $e.Message }
    finally {
        if ($fs) { $fs.Close() }
        if ($st) { $st.Close() }
        if ($res) { $res.Close() }
    }
    if ($sudah -eq $antar) { $beruntun++; Start-Sleep -Seconds 2 } else { $beruntun = 0 }
}
if ($sudah -ge $total) { return 'OK' }
return ('GAGAL ' + $galat)
'@

$pool = $null
$jobs = @()
$tahap = ''
try {
    $dir = Split-Path -Parent $Tujuan
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # 1. ukuran total + dukungan Range (GET bytes=0-0)
    $tahap = 'cek'
    Info ('Mengecek ' + $Url + ' ...')
    $req = [Net.HttpWebRequest][Net.WebRequest]::Create($Url)
    $req.Timeout = $BatasMs
    $req.UserAgent = 'K8Backup/ambil-installer'
    if (-not $PakaiProxy) { $req.Proxy = $null }
    $req.AddRange([long]0, [long]0)
    $res = $req.GetResponse()
    $kode = [int]$res.StatusCode
    $cr = '' + $res.Headers['Content-Range']
    $res.Close()
    $total = [long]0
    if ($kode -eq 206 -and $cr -match '/(\d+)$') { $total = [long]$Matches[1] }
    if ($total -le 0) { throw 'Server tidak mendukung unduhan bertahap (Range). Pakai Start-BitsTransfer biasa.' }
    if ($total -lt 1048576) { throw ('Ukuran file aneh (' + $total + ' byte), bukan installer.') }
    $tahap = 'unduh'
    Info ('Ukuran file: ' + (Ukuran-MB $total) + ' MB, diambil dengan ' + $Bagian + ' koneksi.') 'Cyan'

    # 2. kalau berkas tujuan sudah ada dan benar, selesai
    if ((Test-Path -LiteralPath $Tujuan) -and ((Get-Item -LiteralPath $Tujuan).Length -eq $total)) {
        $sudahAda = Sha256-Berkas $Tujuan
        if (-not $Sha256 -or $sudahAda -ieq $Sha256) {
            Info ('Berkas sudah ada dan benar: ' + $Tujuan) 'Green'
            Info ('SHA256 ' + $sudahAda)
            return
        }
    }

    # 3. rencana bagian
    $ukBagian = [long][math]::Ceiling($total / [double]$Bagian)
    $rencana = @()
    for ($i = 0; $i -lt $Bagian; $i++) {
        $m = [long]($i * $ukBagian)
        if ($m -ge $total) { break }
        $a = [long][math]::Min($m + $ukBagian - 1, $total - 1)
        $rencana += , @($m, $a, ($Tujuan + '.part' + $i))
    }
    # Berkas .partN hanya sah untuk pembagian yang sama (ukuran + jumlah bagian + alamat). Kalau beda, mulai dari awal.
    $meta = $Tujuan + '.meta'
    $ciri = $Url + '|' + $total + '|' + $rencana.Count
    $metaLama = ''
    if (Test-Path -LiteralPath $meta) { try { $metaLama = ([IO.File]::ReadAllText($meta)).Trim() } catch { } }
    if ($metaLama -ne $ciri) {
        $sisa = @(Get-ChildItem -LiteralPath $dir -Filter ((Split-Path -Leaf $Tujuan) + '.part*') -ErrorAction SilentlyContinue)
        if ($sisa.Count -gt 0) {
            Info 'Sisa unduhan lama memakai pembagian yang berbeda; dibuang dan mulai dari awal.' 'Yellow'
            foreach ($f in $sisa) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
        }
        [IO.File]::WriteAllText($meta, $ciri)
    }
    $prog = [hashtable]::Synchronized(@{})
    $pool = [runspacefactory]::CreateRunspacePool(1, $rencana.Count)
    $pool.Open()
    $awal = [long]0
    for ($i = 0; $i -lt $rencana.Count; $i++) {
        $r = $rencana[$i]
        $prog[$i] = [long]0
        if (Test-Path -LiteralPath $r[2]) { $awal += [long](Get-Item -LiteralPath $r[2]).Length }
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($Pekerja).AddArgument($Url).AddArgument([long]$r[0]).AddArgument([long]$r[1]).AddArgument($r[2]).AddArgument($BatasMs).AddArgument([bool]$PakaiProxy).AddArgument($prog).AddArgument($i)
        $jobs += @{ PS = $ps; H = $ps.BeginInvoke(); Idx = $i }
    }
    if ($awal -gt 0) { Info ('Melanjutkan: ' + (Ukuran-MB $awal) + ' MB sudah ada dari unduhan sebelumnya.') 'Yellow' }

    # 4. tunggu + progres
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $tCetak = [long]0
    $bCetak = $awal
    while (@($jobs | Where-Object { -not $_.H.IsCompleted }).Count -gt 0) {
        Start-Sleep -Milliseconds 500
        $dt = $sw.ElapsedMilliseconds - $tCetak
        if ($dt -ge 3000) {
            $skr = [long]0
            foreach ($k in @($prog.Keys)) { $skr += [long]$prog[$k] }
            $kec = [math]::Round((($skr - $bCetak) / 1KB) / ($dt / 1000), 0)
            Info ('  ' + (Ukuran-MB $skr) + ' MB dari ' + (Ukuran-MB $total) + ' MB (' + [math]::Floor($skr * 100 / $total) + '%)   ' + $kec + ' KB/detik   [' + @($jobs | Where-Object { -not $_.H.IsCompleted }).Count + ' koneksi aktif]')
            $tCetak = $sw.ElapsedMilliseconds
            $bCetak = $skr
        }
    }
    $gagal = @()
    foreach ($j in $jobs) {
        $hasil = ''
        try { $hasil = '' + ($j.PS.EndInvoke($j.H) | Select-Object -Last 1) } catch { $hasil = 'GAGAL ' + $_.Exception.Message }
        if ($hasil -ne 'OK') { $gagal += ('bagian ' + $j.Idx + ': ' + $hasil) }
    }
    if ($gagal.Count -gt 0) {
        Info 'Sebagian unduhan gagal (bagian yang selesai tetap disimpan, jalankan lagi perintah yang sama untuk melanjutkan):' 'Red'
        foreach ($g in $gagal) { Info ('  ' + $g) 'Red' }
        exit 1
    }

    # 5. gabung + periksa
    Info ('Unduhan selesai dalam ' + [math]::Round($sw.Elapsed.TotalSeconds) + ' detik. Menggabungkan ...')
    $gabung = $Tujuan + '.gabung'
    if (Test-Path -LiteralPath $gabung) { Remove-Item -LiteralPath $gabung -Force }
    $out = [IO.File]::Open($gabung, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    try {
        foreach ($r in $rencana) {
            $in = [IO.File]::OpenRead($r[2])
            try { $in.CopyTo($out) } finally { $in.Close() }
        }
    } finally { $out.Close() }
    if ((Get-Item -LiteralPath $gabung).Length -ne $total) {
        Remove-Item -LiteralPath $gabung -Force
        throw 'Ukuran hasil gabungan tidak sama dengan ukuran file. Hapus berkas .part* lalu ulangi.'
    }
    $sha = Sha256-Berkas $gabung
    Info ('SHA256 ' + $sha)
    $cocok = ((-not $Sha256) -or ($sha -ieq $Sha256))
    if ($cocok) {
        if (Test-Path -LiteralPath $Tujuan) { Remove-Item -LiteralPath $Tujuan -Force }
        Move-Item -LiteralPath $gabung -Destination $Tujuan
        foreach ($r in $rencana) { Remove-Item -LiteralPath $r[2] -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $meta -Force -ErrorAction SilentlyContinue
        if ($Sha256) { Info 'COCOK dengan hash resmi UrBackup Client.' 'Green' } else { Info 'Hash resmi tidak diperiksa (-Sha256 kosong).' 'Yellow' }
        try {
            $sg = Get-AuthenticodeSignature -FilePath $Tujuan
            if ($sg) {
                $pen = ''
                if ($sg.SignerCertificate) { $pen = ' - ' + $sg.SignerCertificate.Subject }
                Info ('Tanda tangan: ' + $sg.Status + $pen)
            }
        } catch { }
        Info ('Selesai: ' + $Tujuan) 'Green'
        Info 'Berikutnya: jalankan k8-server.ps1; penerima akan menampilkan installer ini dan PC mengambilnya dari server.' 'Cyan'
    } else {
        $tolak = $Tujuan + '.tidak-cocok'
        if (Test-Path -LiteralPath $tolak) { Remove-Item -LiteralPath $tolak -Force }
        Move-Item -LiteralPath $gabung -Destination $tolak
        foreach ($r in $rencana) { Remove-Item -LiteralPath $r[2] -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $meta -Force -ErrorAction SilentlyContinue
        Info ('BEDA dari hash resmi (' + $Sha256 + ').') 'Red'
        Info ('File disimpan sebagai ' + $tolak + ' dan TIDAK dipakai penerima. Jangan dipasang di PC sebelum diperiksa.') 'Red'
        exit 2
    }
}
catch {
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    Info ('GAGAL: ' + $e.Message) 'Red'
    $jaringan = (($e -is [Net.WebException] -and $e.Status -ne [Net.WebExceptionStatus]::ProtocolError) -or ($e -is [Net.Sockets.SocketException]))
    if ($tahap -eq 'cek' -and -not $PakaiProxy -and $jaringan) {
        Info 'Kalau internet di server ini lewat proxy, jalankan lagi dengan tambahan: -PakaiProxy' 'Yellow'
    }
    exit 1
}
finally {
    foreach ($j in $jobs) { try { $j.PS.Stop() } catch { } try { $j.PS.Dispose() } catch { } }
    if ($pool) { try { $pool.Close(); $pool.Dispose() } catch { } }
}
