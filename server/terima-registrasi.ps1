<#
  terima-registrasi.ps1   [SERVER 192.168.1.88]  -  jalankan sebagai Administrator

  Penerima kecil untuk data PC yang dikirim k8.cmd (nama PC, divisi, nama orang, IP, drive, folder C:\).
  Menulis file  <Tujuan>\<Divisi>_<Nama>.csv  dengan format yang sama seperti launcher lama,
  jadi siapkan-divisi.ps1 dan cek-koneksi.ps1 langsung bisa membacanya.

  Keamanan:
    - HANYA menerima POST /daftar (dan GET /ping). Selain itu ditolak.
    - Hanya dari alamat yang diawali -Izinkan (default 192.168.6.). Yang lain mendapat 403.
    - Divisi harus ada di daftar baku, Nama hanya huruf/angka, nama PC hanya huruf/angka/strip.
      Nama file dibentuk dari nilai yang sudah lolos periksa, jadi tidak bisa keluar dari folder tujuan.
    - Isi (disk, folder C:\) dibersihkan dari karakter selain huruf/angka/spasi/_=|().- dan dibatasi panjangnya.
    - Badan permintaan maksimal 8 KB.
    - Berhenti sendiri setelah -MenitMaks (default 240 menit). Jalankan hanya selama pemasangan PC.
    - Tidak menerima atau menyimpan token / password apa pun.
    - Protokol HTTP biasa (data bukan rahasia: nama PC, IP, label drive). Jangan dibuka ke internet.

  Contoh:
    powershell -ExecutionPolicy Bypass -File terima-registrasi.ps1 -BukaFirewall
    (berhenti dengan Ctrl+C; aturan firewall yang dibuat skrip ikut dihapus)
#>
param(
    [string]$Tujuan     = 'E:\Repo\Divisi\_setup\registrasi',
    [int]$Port          = 8088,
    [string]$Prefix     = '',
    [string[]]$Izinkan  = @('192.168.6.'),
    [string]$AlamatFirewall = '192.168.6.0/24',
    [int]$MenitMaks     = 240,
    [switch]$BukaFirewall
)
$ErrorActionPreference = 'Stop'
if (-not $Prefix) { $Prefix = 'http://+:' + $Port + '/' }

$DivisiValid = @('Housekeeping', 'IT', 'Marketing', 'Purchasing', 'Finance', 'HRD', 'HR', 'Corsec', 'Legal', 'Senior Manager', 'Audit', 'Accounting', 'Kasir')
$NamaAturan = 'Kedaton8 Terima Registrasi'

function Bersihkan($s, $maks) {
    $t = '' + $s
    $t = $t -replace '[^A-Za-z0-9 _=|().\-]', '_'
    if ($t.Length -gt $maks) { $t = $t.Substring(0, $maks) }
    return $t
}

function Balas($ctx, $kode, $teks) {
    $b = [Text.Encoding]::UTF8.GetBytes($teks)
    $ctx.Response.StatusCode = $kode
    $ctx.Response.ContentType = 'text/plain; charset=utf-8'
    $ctx.Response.ContentLength64 = $b.Length
    $ctx.Response.OutputStream.Write($b, 0, $b.Length)
    $ctx.Response.Close()
}

function Baca-Form($teks) {
    $h = @{}
    foreach ($bag in ($teks -split '&')) {
        if (-not $bag) { continue }
        $i = $bag.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $bag.Substring(0, $i).ToLower()
        $v = [Uri]::UnescapeDataString(($bag.Substring($i + 1) -replace '\+', ' '))
        $h[$k] = $v
    }
    return $h
}

# Mengembalikan @{ Ok = $true/$false; Pesan = ...; Berkas = ...; Isi = ... }
function Periksa($f) {
    foreach ($k in @('komputer', 'divisi', 'nama')) {
        if (-not $f.ContainsKey($k) -or -not ('' + $f[$k]).Trim()) { return @{ Ok = $false; Pesan = ('kolom ' + $k + ' kosong') } }
    }
    $pc = ('' + $f['komputer']).Trim()
    if ($pc -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$') { return @{ Ok = $false; Pesan = 'nama komputer tidak valid' } }

    $d = ('' + $f['divisi']).Trim()
    $divisi = $null
    if ($d -ieq 'Mandiri' -or $d -eq '-') { $divisi = '-' } else {
        foreach ($v in $DivisiValid) { if ($v -ieq $d) { $divisi = $v } }
    }
    if (-not $divisi) { return @{ Ok = $false; Pesan = 'divisi tidak dikenal' } }

    $nama = ('' + $f['nama']).Trim()
    if ($nama -notmatch '^[A-Za-z0-9]{1,40}$') { return @{ Ok = $false; Pesan = 'nama tidak valid' } }

    $ips = @()
    $ipMentah = ''
    if ($f.ContainsKey('ip')) { $ipMentah = ('' + $f['ip']).Trim() }
    foreach ($ip in @($ipMentah -split '\|' | Where-Object { $_ })) {
        $x = $null
        if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [Net.IPAddress]::TryParse($ip, [ref]$x)) { return @{ Ok = $false; Pesan = 'IP tidak valid' } }
        $ips += $ip
    }
    if ($ips.Count -eq 0) { return @{ Ok = $false; Pesan = 'IP kosong' } }
    if ($ips.Count -gt 8) { return @{ Ok = $false; Pesan = 'IP terlalu banyak' } }

    $disk = ''
    if ($f.ContainsKey('disk')) { $disk = Bersihkan $f['disk'] 600 }
    $folderc = ''
    if ($f.ContainsKey('folderc')) { $folderc = Bersihkan $f['folderc'] 600 }

    $label = $divisi
    if ($label -eq '-') { $label = 'Mandiri' }
    $berkas = (($label + '_' + $nama) -replace '[^A-Za-z0-9_-]', '-') + '.csv'
    if ($berkas -notmatch '^[A-Za-z0-9_-]+\.csv$') { return @{ Ok = $false; Pesan = 'nama berkas tidak valid' } }
    $isi = 'Komputer,Divisi,Nama,IP,Disk,FolderC' + "`r`n" + $pc + ',' + $divisi + ',' + $nama + ',' + ($ips -join '|') + ',' + $disk + ',' + $folderc + "`r`n"
    return @{ Ok = $true; Pesan = 'ok'; Berkas = $berkas; Isi = $isi; Label = $label; Nama = $nama; PC = $pc }
}

function Alamat-Boleh($alamat) {
    foreach ($p in $Izinkan) { if ($alamat.StartsWith($p)) { return $true } }
    return $false
}

if (-not (Test-Path -LiteralPath $Tujuan)) { New-Item -ItemType Directory -Path $Tujuan -Force | Out-Null }
$tujuanPenuh = (Resolve-Path -LiteralPath $Tujuan).Path

$firewallDibuat = $false
if ($BukaFirewall) {
    & netsh advfirewall firewall delete rule name="$NamaAturan" | Out-Null
    & netsh advfirewall firewall add rule name="$NamaAturan" dir=in action=allow protocol=TCP localport=$Port remoteip=$AlamatFirewall profile=any | Out-Null
    $firewallDibuat = $true
    Write-Host ('Firewall: TCP ' + $Port + ' dibuka dari ' + $AlamatFirewall + ' (dihapus otomatis saat skrip berhenti).') -ForegroundColor Green
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Prefix)
$listener.Start()
$batas = (Get-Date).AddMinutes($MenitMaks)
Write-Host ('Penerima registrasi aktif di ' + $Prefix + '  ->  ' + $tujuanPenuh) -ForegroundColor Cyan
Write-Host ('Hanya dari: ' + ($Izinkan -join ', ') + '   Berhenti otomatis: ' + $batas.ToString('HH:mm') + '   (Ctrl+C untuk berhenti)') -ForegroundColor Cyan

try {
    while ((Get-Date) -lt $batas) {
        $tugas = $listener.GetContextAsync()
        while (-not $tugas.AsyncWaitHandle.WaitOne(500)) { if ((Get-Date) -ge $batas) { break } }
        if (-not $tugas.IsCompleted) { break }
        $ctx = $tugas.Result
        $dari = $ctx.Request.RemoteEndPoint.Address.ToString()
        $jam = (Get-Date).ToString('HH:mm:ss')
        try {
            if (-not (Alamat-Boleh $dari)) { Balas $ctx 403 'ditolak'; Write-Host ($jam + '  ' + $dari + '  DITOLAK (alamat tidak diizinkan)') -ForegroundColor Yellow; continue }
            $jalur = $ctx.Request.Url.AbsolutePath
            $metode = $ctx.Request.HttpMethod
            if ($jalur -eq '/ping' -and $metode -eq 'GET') { Balas $ctx 200 'ok'; continue }
            if ($jalur -ne '/daftar') { Balas $ctx 404 'tidak ada'; continue }
            if ($metode -ne 'POST') { Balas $ctx 405 'gunakan POST'; continue }
            $panjang = $ctx.Request.ContentLength64
            if ($panjang -lt 1 -or $panjang -gt 8192) { Balas $ctx 413 'ukuran tidak sesuai'; Write-Host ($jam + '  ' + $dari + '  DITOLAK (ukuran ' + $panjang + ')') -ForegroundColor Yellow; continue }
            $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
            $teks = $sr.ReadToEnd()
            $sr.Close()
            $hasil = Periksa (Baca-Form $teks)
            if (-not $hasil.Ok) { Balas $ctx 400 ('ditolak: ' + $hasil.Pesan); Write-Host ($jam + '  ' + $dari + '  DITOLAK (' + $hasil.Pesan + ')') -ForegroundColor Yellow; continue }
            $tujuanBerkas = Join-Path $tujuanPenuh $hasil.Berkas
            $baru = -not (Test-Path -LiteralPath $tujuanBerkas)
            $lama = ''
            if (-not $baru) {
                try { $lama = ('' + (Import-Csv -LiteralPath $tujuanBerkas | Select-Object -First 1).Komputer).Trim() } catch { }
            }
            [IO.File]::WriteAllText($tujuanBerkas, $hasil.Isi, (New-Object System.Text.UTF8Encoding($false)))
            $kata = 'DIPERBARUI'
            $warna = 'Green'
            if ($baru) { $kata = 'BARU' }
            elseif ($lama -and ($lama -ine $hasil.PC)) { $kata = 'DIGANTI (sebelumnya PC ' + $lama + ')'; $warna = 'Yellow' }
            Write-Host ($jam + '  ' + $dari + '  ' + $kata + '  ' + $hasil.PC + '  ->  ' + $hasil.Label + ' \ ' + $hasil.Nama) -ForegroundColor $warna
            Balas $ctx 200 ($hasil.Label + ' \ ' + $hasil.Nama + ' (' + $kata + ')')
        } catch {
            Write-Host ($jam + '  ' + $dari + '  GALAT: ' + $_.Exception.Message) -ForegroundColor Red
            try { Balas $ctx 500 'galat di server' } catch { }
        }
    }
    Write-Host 'Waktu habis. Penerima berhenti.' -ForegroundColor Yellow
}
finally {
    try { $listener.Stop(); $listener.Close() } catch { }
    if ($firewallDibuat) {
        & netsh advfirewall firewall delete rule name="$NamaAturan" | Out-Null
        Write-Host 'Aturan firewall penerima dihapus.' -ForegroundColor Green
    }
}
