<#
  k8-server.ps1   [SERVER 192.168.1.88]  -  jalankan sebagai Administrator

  Penerima untuk k8.cmd di PC (menu Pasang/daftar dan Sinkron IP). Dijalankan HANYA saat dibutuhkan:
  selama pemasangan PC, dan saat ada PC yang berganti IP. Berhenti sendiri setelah -MenitMaks.

  Yang dilakukan:
    POST /daftar   catat PC (nama PC, divisi, nama orang, IP, drive, folder C:\) ke  <Tujuan>\<Divisi>_<Nama>.csv
                   (format sama dengan launcher lama, jadi siapkan-divisi.ps1 dan cek-koneksi.ps1 langsung membacanya)
                   Kalau badan permintaan memuat lama_divisi + lama_nama (menu 5, ganti nama), entri lama milik PC yang
                   sama dipindah ke <Tujuan>\_diganti\ (tidak dihapus). Nama baru milik PC lain ditolak (409), bukan ditimpa.
    POST /sinkron  PC yang sudah terdaftar melaporkan IP terbarunya. CSV diperbarui. Kalau PC itu SUDAH ditambahkan
                   di UrBackup lewat alamat IP, alamat lamanya diganti dengan yang baru. PC yang belum ada di UrBackup
                   TIDAK pernah ditambahkan otomatis.
    GET  /nonce    kode acak sekali pakai (60 detik) untuk membuktikan password
    GET  /ping     'ok k8-4' (tanpa password, untuk cek jangkauan)
    GET  /installer-info  'ok <ukuran> <sha256>' installer UrBackup Client yang disimpan di server (404 kalau tidak ada)
    GET  /installer       isi installer, mendukung Range (lanjut kalau putus). PC memakainya supaya tidak mengunduh
                          57 MB dari internet satu-satu. Dilayani di jalur terpisah, tidak menahan pendaftaran PC lain.
                          File: -BerkasInstaller, atau (bawaan) <folder induk skrip>\installer\UrBackupClient.exe,
                          atau file UrBackup*.exe terbaru di folder itu. PC memeriksa SHA256 terhadap hash resmi.
    GET  /k8.ps1   cadangan LAN untuk menu di PC (kalau GitHub tidak terjangkau). Isinya sama dengan k8.ps1 di repo
                   (tanpa rahasia), dengan alamat unduhan ulang diarahkan ke server ini.

  Password:
    - Diketik saat skrip dimulai (tersembunyi, diminta dua kali). TIDAK disimpan di disk, tidak dicatat di layar.
    - Tidak dikirim lewat jaringan. PC mengirim HMAC-SHA256(password, jalur + isi permintaan) dengan kode sekali pakai
      dari /nonce, jadi sadapan di LAN tidak bisa dipakai ulang.
    - 5 kali salah dari satu alamat dalam 10 menit = alamat itu dikunci 10 menit.
    - Pakai password yang panjang (>= 10 karakter). HMAC yang tersadap secara teori bisa ditebak offline kalau password pendek.

  Pembatasan lain:
    - Hanya dari alamat yang diawali -Izinkan (default 192.168.1. dan 192.168.6.). Yang lain mendapat 403.
    - Divisi harus dari daftar baku; Nama hanya huruf/angka; nama PC hanya huruf/angka/strip. Nama berkas dibentuk dari
      nilai yang sudah lolos periksa, jadi tidak bisa keluar dari folder tujuan.
    - Isi disk / folder C:\ dibersihkan dan dibatasi panjangnya. Badan permintaan maksimal 8 KB.
    - Alamat yang ditambahkan ke UrBackup adalah alamat SUMBER permintaan (bukan yang diklaim PC).
    - Protokol HTTP biasa di LAN (datanya bukan rahasia: nama PC, IP, label drive). Jangan dibuka ke internet.

  Contoh:
    powershell -ExecutionPolicy Bypass -File k8-server.ps1 -BukaFirewall
    (berhenti dengan Ctrl+C; aturan firewall yang dibuat skrip ikut dihapus)
#>
param(
    [string]$Tujuan         = 'E:\Divisi\_setup\registrasi',
    [int]$Port              = 8088,
    [string]$Prefix         = '',
    [string[]]$Izinkan      = @('192.168.1.', '192.168.6.'),
    [string]$AlamatFirewall = '192.168.1.0/24,192.168.6.0/24',
    [int]$MenitMaks         = 240,
    [string]$UbUrl          = 'http://127.0.0.1:55414',
    [string]$UbUser         = '',
    [string]$BerkasK8       = '',
    [string]$BerkasInstaller = '',
    [switch]$TanpaUrBackup,
    [switch]$BukaFirewall
)
$ErrorActionPreference = 'Stop'
$Versi = 'k8-4'
if (-not $Prefix) { $Prefix = 'http://+:' + $Port + '/' }
$Izinkan = @($Izinkan | ForEach-Object { ('' + $_) -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Izinkan.Count -eq 0) { Write-Host 'GAGAL: -Izinkan kosong.' -ForegroundColor Red; exit 1 }

$DivisiValid = @('Housekeeping', 'IT', 'Marketing', 'Purchasing', 'Finance', 'HRD', 'HR', 'Corsec', 'Legal', 'Senior Manager', 'Audit', 'Accounting', 'Kasir')
$NamaAturan = 'Kedaton8 Terima Registrasi'
$UrlGitHub = 'https://raw.githubusercontent.com/CahNdesoID/k8-backup/main/k8.ps1'
if (-not $BerkasK8 -and $PSScriptRoot) { $BerkasK8 = Join-Path (Split-Path -Parent $PSScriptRoot) 'k8.ps1' }

function Info($t, $warna) { if ($warna) { Write-Host $t -ForegroundColor $warna } else { Write-Host $t } }

function Baca-Rahasia($tanya) {
    $ss = Read-Host $tanya -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Hex($bytes) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($x in $bytes) { [void]$sb.Append($x.ToString('x2')) }
    return $sb.ToString()
}

function Hitung-Mac($kunci, $teks) {
    $h = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $kunci)
    try { return (Hex ($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($teks)))) }
    finally { $h.Dispose() }
}

function Sama-Aman($a, $b) {
    if ($a.Length -ne $b.Length) { return $false }
    $d = 0
    for ($i = 0; $i -lt $a.Length; $i++) { $d = $d -bor ([int][char]$a[$i] -bxor [int][char]$b[$i]) }
    return ($d -eq 0)
}

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

# Mengembalikan @{ Ok; Pesan; Berkas; Isi; Label; Nama; PC; IPs }
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
        $ips += $x.ToString()
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
    return @{ Ok = $true; Pesan = 'ok'; Berkas = $berkas; Isi = $isi; Label = $label; Nama = $nama; PC = $pc; IPs = $ips }
}

# Nama berkas CSV untuk pasangan Divisi/Nama (aturan sama dengan Periksa). '' kalau tidak valid.
function Berkas-Identitas($divisiMentah, $namaMentah) {
    $d = ('' + $divisiMentah).Trim()
    $divisi = $null
    if ($d -ieq 'Mandiri' -or $d -eq '-') { $divisi = '-' } else {
        foreach ($v in $DivisiValid) { if ($v -ieq $d) { $divisi = $v } }
    }
    if (-not $divisi) { return '' }
    $nama = ('' + $namaMentah).Trim()
    if ($nama -notmatch '^[A-Za-z0-9]{1,40}$') { return '' }
    $label = $divisi
    if ($label -eq '-') { $label = 'Mandiri' }
    $berkas = (($label + '_' + $nama) -replace '[^A-Za-z0-9_-]', '-') + '.csv'
    if ($berkas -notmatch '^[A-Za-z0-9_-]+\.csv$') { return '' }
    return $berkas
}

# Pindahkan entri lama ke <Tujuan>\_diganti\ HANYA kalau milik PC ini. Tidak pernah menghapus. Mengembalikan satu baris 'LAMA: ...'.
function Arsipkan-Lama($tujuanPenuh, $berkasLama, $pc) {
    $asal = Join-Path $tujuanPenuh $berkasLama
    $nm = [IO.Path]::GetFileNameWithoutExtension($berkasLama)
    if (-not (Test-Path -LiteralPath $asal -PathType Leaf)) { return ('LAMA: ' + $nm + ' tidak ada di server, tidak ada yang diarsipkan.') }
    $komp = ''
    try { $r = Import-Csv -LiteralPath $asal | Select-Object -First 1; $komp = ('' + $r.Komputer).Trim() } catch { }
    if (-not $komp) { return ('LAMA: ' + $nm + ' tidak bisa dibaca pemiliknya, TIDAK diubah. Periksa manual.') }
    if ($komp -ine $pc) { return ('LAMA: ' + $nm + ' milik PC ' + $komp + ', bukan PC ini. TIDAK diubah.') }
    try {
        $arsip = Join-Path $tujuanPenuh '_diganti'
        if (-not (Test-Path -LiteralPath $arsip)) { New-Item -ItemType Directory -Path $arsip -Force | Out-Null }
        $tujuan = Join-Path $arsip ($nm + '_' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.csv')
        Move-Item -LiteralPath $asal -Destination $tujuan -ErrorAction Stop
        return ('LAMA: ' + $nm + ' diarsipkan ke _diganti.')
    } catch {
        return ('LAMA: ' + $nm + ' GAGAL diarsipkan (' + $_.Exception.Message + '). Pindahkan file itu manual.')
    }
}

function Alamat-Boleh($alamat) {
    foreach ($p in $Izinkan) { if ($alamat.StartsWith($p)) { return $true } }
    return $false
}

# ---------------- installer UrBackup Client untuk PC (LAN) ----------------
function Sha256-Berkas($berkas) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $f = [IO.File]::OpenRead($berkas)
    try { return (Hex ($sha.ComputeHash($f))) }
    finally { $f.Close(); $sha.Dispose() }
}

# Tentukan file installer: -BerkasInstaller, atau <induk skrip>\installer\UrBackupClient.exe, atau UrBackup*.exe terbaru di sana.
function Cari-Installer {
    if ($BerkasInstaller) { return $BerkasInstaller }
    if (-not $PSScriptRoot) { return '' }
    $dir = Join-Path (Split-Path -Parent $PSScriptRoot) 'installer'
    $baku = Join-Path $dir 'UrBackupClient.exe'
    if (Test-Path -LiteralPath $baku -PathType Leaf) { return $baku }
    if (Test-Path -LiteralPath $dir -PathType Container) {
        $f = @(Get-ChildItem -LiteralPath $dir -Filter 'UrBackup*.exe' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($f.Count -gt 0) { return $f[0].FullName }
    }
    return $baku
}

# Ukuran + SHA256 file installer; dihitung ulang otomatis kalau file diganti saat server berjalan. $null kalau tidak ada.
$script:Inst = $null
function Info-Installer {
    $p = Cari-Installer
    if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    $fi = Get-Item -LiteralPath $p
    if ($script:Inst -and $script:Inst.Path -eq $fi.FullName -and $script:Inst.Len -eq $fi.Length -and $script:Inst.Tulis -eq $fi.LastWriteTimeUtc.Ticks) { return $script:Inst }
    $script:Inst = @{ Path = $fi.FullName; Len = [long]$fi.Length; Tulis = $fi.LastWriteTimeUtc.Ticks; Sha = (Sha256-Berkas $fi.FullName) }
    return $script:Inst
}

# Hash resmi yang tercatat di k8.ps1 ($UbSha256), untuk dibandingkan saat server mulai.
function Hash-Resmi {
    try {
        if ($BerkasK8 -and (Test-Path -LiteralPath $BerkasK8)) {
            $t = [IO.File]::ReadAllText($BerkasK8, [Text.Encoding]::UTF8)
            if ($t -match '\$UbSha256\s*=\s*''([0-9A-Fa-f]{64})''') { return $Matches[1].ToLower() }
        }
    } catch { }
    return ''
}

# Dijalankan di runspace terpisah supaya pengiriman 57 MB tidak menahan pendaftaran / sinkron PC lain.
$BlokKirim = @'
param($ctx, $path, $len, $rangeHdr)
$resp = $ctx.Response
$mulai = [long]0
$akhir = [long]($len - 1)
$parsial = $false
if ($rangeHdr -match '^bytes=(\d+)-(\d*)$') {
    $mulai = [long]$Matches[1]
    if ($Matches[2]) { $akhir = [math]::Min([long]$Matches[2], [long]($len - 1)) }
    if ($mulai -ge $len -or $mulai -gt $akhir) {
        try {
            $resp.StatusCode = 416
            $resp.AddHeader('Content-Range', 'bytes */' + $len)
            $resp.ContentLength64 = 0
            $resp.Close()
        } catch { }
        return 'RANGE-416'
    }
    $parsial = $true
}
$jumlah = [long]($akhir - $mulai + 1)
$fs = $null
$terkirim = [long]0
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    [void]$fs.Seek($mulai, [IO.SeekOrigin]::Begin)
    $resp.ContentType = 'application/octet-stream'
    $resp.AddHeader('Accept-Ranges', 'bytes')
    if ($parsial) {
        $resp.StatusCode = 206
        $resp.AddHeader('Content-Range', 'bytes ' + $mulai + '-' + $akhir + '/' + $len)
    } else {
        $resp.StatusCode = 200
    }
    $resp.ContentLength64 = $jumlah
    $buf = New-Object byte[] 262144
    $sisa = $jumlah
    $out = $resp.OutputStream
    while ($sisa -gt 0) {
        $n = $fs.Read($buf, 0, [int][math]::Min([long]$buf.Length, $sisa))
        if ($n -le 0) { break }
        $out.Write($buf, 0, $n)
        $sisa -= $n
        $terkirim += $n
    }
    $out.Close()
    $resp.Close()
    return ('OK ' + $terkirim + ' ' + [math]::Round($sw.Elapsed.TotalSeconds, 1))
} catch {
    try { $resp.Abort() } catch { }
    return ('PUTUS ' + $terkirim + ' ' + $_.Exception.Message)
} finally {
    if ($fs) { $fs.Close() }
}
'@

$script:Pool = $null
$script:Aktif = New-Object System.Collections.ArrayList
$MaksKirim = 6

function Mulai-Kirim($ctx, $inst, $dari) {
    $hdr = '' + $ctx.Request.Headers['Range']
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript($BlokKirim).AddArgument($ctx).AddArgument($inst.Path).AddArgument([long]$inst.Len).AddArgument($hdr)
    $h = $ps.BeginInvoke()
    [void]$script:Aktif.Add(@{ PS = $ps; H = $h; Dari = $dari; Rentang = $hdr })
}

# Tuntaskan pengiriman yang sudah selesai, catat hasilnya di layar.
function Bersih-Kirim {
    foreach ($a in @($script:Aktif)) {
        if (-not $a.H.IsCompleted) { continue }
        $hasil = ''
        try { $r = $a.PS.EndInvoke($a.H); $hasil = '' + ($r | Select-Object -Last 1) }
        catch { $hasil = 'PUTUS ' + $_.Exception.Message }
        try { $a.PS.Dispose() } catch { }
        $script:Aktif.Remove($a)
        $jam = (Get-Date).ToString('HH:mm:ss')
        $ket = ''
        if ($a.Rentang) { $ket = '  (lanjutan ' + $a.Rentang + ')' }
        if ($hasil -like 'OK *') { Info ($jam + '  ' + $a.Dari + '  INSTALLER terkirim  ' + ($hasil.Substring(3) -replace '^(\d+) (.*)$', '$1 byte dalam $2 detik') + $ket) 'Green' }
        elseif ($hasil -like 'RANGE-416*') { Info ($jam + '  ' + $a.Dari + '  INSTALLER: rentang tidak sah') 'Yellow' }
        elseif ($hasil -match '^PUTUS (\d+)') { Info ($jam + '  ' + $a.Dari + '  INSTALLER terputus di ' + $Matches[1] + ' byte (PC menutup koneksi / jaringan putus; PC akan mencoba lagi)' + $ket) 'Yellow' }
        else { Info ($jam + '  ' + $a.Dari + '  INSTALLER gagal  ' + $hasil + $ket) 'Yellow' }
    }
}

# ---------------- kode sekali pakai + penguncian ----------------
$script:Nonce = @{}
$script:Gagal = @{}
$rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider

function Nonce-Baru {
    $kini = Get-Date
    $basi = @($script:Nonce.Keys | Where-Object { $script:Nonce[$_] -lt $kini })
    foreach ($k in $basi) { $script:Nonce.Remove($k) }
    if ($script:Nonce.Count -ge 500) { return $null }
    $b = New-Object byte[] 16
    $rng.GetBytes($b)
    $n = Hex $b
    $script:Nonce[$n] = $kini.AddSeconds(60)
    return $n
}

function Nonce-Pakai($n) {
    $n = ('' + $n).ToLower()
    if (-not $script:Nonce.ContainsKey($n)) { return $false }
    $sah = ($script:Nonce[$n] -ge (Get-Date))
    $script:Nonce.Remove($n)
    return $sah
}

function Terkunci($ip) {
    if (-not $script:Gagal.ContainsKey($ip)) { return $false }
    $batas = (Get-Date).AddMinutes(-10)
    $sisa = @($script:Gagal[$ip] | Where-Object { $_ -gt $batas })
    $script:Gagal[$ip] = $sisa
    return ($sisa.Count -ge 5)
}

function Catat-Gagal($ip) {
    $lama = @()
    if ($script:Gagal.ContainsKey($ip)) { $lama = @($script:Gagal[$ip]) }
    $script:Gagal[$ip] = $lama + (Get-Date)
}

# ---------------- UrBackup (hanya untuk /sinkron) ----------------
$script:UbAktif = $false
$script:UbSes = ''
$script:UbPw = ''
function Ada($obj, $nama) { return ($null -ne $obj -and $null -ne $obj.PSObject.Properties[$nama]) }

function Ub-Panggil($aksi, $pasang) {
    $bagian = @()
    foreach ($k in $pasang.Keys) { $bagian += ($k + '=' + [Uri]::EscapeDataString([string]$pasang[$k])) }
    if ($script:UbSes) { $bagian += ('ses=' + [Uri]::EscapeDataString($script:UbSes)) }
    $badan = [Text.Encoding]::UTF8.GetBytes($bagian -join '&')
    $req = [Net.WebRequest]::Create($UbUrl.TrimEnd('/') + '/x?a=' + $aksi)
    $req.Method = 'POST'
    $req.ContentType = 'application/x-www-form-urlencoded; charset=utf-8'
    $req.Timeout = 10000
    $req.ReadWriteTimeout = 10000
    $req.Proxy = $null
    $req.ContentLength = $badan.Length
    $st = $req.GetRequestStream()
    $st.Write($badan, 0, $badan.Length)
    $st.Close()
    $res = $req.GetResponse()
    $rd = New-Object IO.StreamReader($res.GetResponseStream(), [Text.Encoding]::UTF8)
    $teks = $rd.ReadToEnd()
    $rd.Close()
    $res.Close()
    try { return ($teks | ConvertFrom-Json) } catch { throw 'balasan UrBackup bukan JSON' }
}

function Ub-Masuk {
    $script:UbSes = ''
    $r = Ub-Panggil 'login' @{}
    if ((Ada $r 'creating_filescache') -or (Ada $r 'upgrading_database')) { throw 'UrBackup masih menyiapkan database' }
    if ((Ada $r 'success') -and ($r.success -eq $true) -and (Ada $r 'session')) { $script:UbSes = [string]$r.session; return }
    if (-not $script:UbUserPakai) {
        $awal = ''
        if (Ada $r 'admin_only') { $awal = [string]$r.admin_only }
        $tanya = 'Username admin UrBackup'
        if ($awal) { $tanya += ' [' + $awal + ']' }
        $u = Read-Host $tanya
        if (-not $u) { $u = $awal }
        if (-not $u) { throw 'username UrBackup kosong' }
        $script:UbUserPakai = $u
    }
    if (-not $script:UbPw) {
        $script:UbPw = $env:UB_PASSWORD
        if (-not $script:UbPw) { $script:UbPw = Baca-Rahasia ('Password UrBackup untuk ' + $script:UbUserPakai) }
    }
    $r2 = Ub-Panggil 'login' ([ordered]@{ username = $script:UbUserPakai; password = $script:UbPw; plainpw = '1' })
    if ((Ada $r2 'success') -and ($r2.success -eq $true) -and (Ada $r2 'session')) { $script:UbSes = [string]$r2.session; return }
    $script:UbPw = ''
    throw 'login UrBackup ditolak (username/password salah)'
}

# Panggil dengan satu kali login ulang kalau sesi habis (error 1).
function Ub-Aman($aksi, $pasang) {
    if (-not $script:UbSes) { Ub-Masuk }
    $r = Ub-Panggil $aksi $pasang
    if ((Ada $r 'error') -and ([int]$r.error -eq 1)) {
        Ub-Masuk
        $r = Ub-Panggil $aksi $pasang
    }
    return $r
}

function Ub-Daftar-Extra {
    $r = Ub-Aman 'status' @{}
    if (-not (Ada $r 'extra_clients')) { throw 'akun UrBackup ini tidak punya hak mengatur client' }
    $hasil = @()
    foreach ($e in @($r.extra_clients)) { $hasil += (New-Object PSObject -Property @{ Host = ('' + $e.hostname).Trim(); Id = ('' + $e.id) }) }
    return $hasil
}

# Mengembalikan daftar baris laporan. Tidak pernah menambahkan PC yang belum ada di UrBackup.
function Sinkron-Ub($pcNama, $ipLama, $ipBaru, $ipUtama, $ipMilikPcLain) {
    $out = @()
    if (-not $script:UbAktif) { return @('UrBackup : tidak terhubung dari penerima ini, IP hanya dicatat.') }
    try {
        $ada = @(Ub-Daftar-Extra)
        $tercapai = @($ada | Where-Object { $ipBaru -contains $_.Host })
        $lamaAda = @($ada | Where-Object { ($ipLama -contains $_.Host) -and ($ipBaru -notcontains $_.Host) })
        $lewatNama = @($ada | Where-Object { $_.Host -ieq $pcNama })
        if ($lewatNama.Count -gt 0) { $out += ('UrBackup : PC ini ditambahkan lewat NAMA (' + $pcNama + '), tidak perlu diubah selama nama itu bisa di-resolve server.') }
        if ($tercapai.Count -eq 0 -and $lamaAda.Count -eq 0) {
            if ($lewatNama.Count -eq 0) { $out += 'UrBackup : PC ini belum ditambahkan di UrBackup (atau pakai alamat lain). Tidak ada yang diubah; PC tidak ditambahkan otomatis.' }
            return $out
        }
        if ($tercapai.Count -eq 0) {
            [void](Ub-Aman 'status' ([ordered]@{ hostname = $ipUtama }))
            $out += ('UrBackup : alamat baru ' + $ipUtama + ' ditambahkan.')
        } else {
            $out += ('UrBackup : alamat ' + ($tercapai[0].Host) + ' sudah ada, tidak perlu ditambah.')
        }
        foreach ($e in $lamaAda) {
            if ($ipMilikPcLain -contains $e.Host) {
                $out += ('UrBackup : alamat lama ' + $e.Host + ' dipertahankan karena tercatat milik PC lain.')
            } else {
                [void](Ub-Aman 'status' ([ordered]@{ hostname = $e.Id; remove = 'true' }))
                $out += ('UrBackup : alamat lama ' + $e.Host + ' dihapus.')
            }
        }
        $cek = @(Ub-Daftar-Extra)
        $targetAda = @($cek | Where-Object { ($ipBaru -contains $_.Host) -or ($_.Host -eq $ipUtama) })
        if ($targetAda.Count -gt 0) { $out += 'UrBackup : diperiksa ulang, alamat baru tercatat.' } else { $out += 'UrBackup : PERINGATAN, alamat baru tidak terlihat setelah disimpan. Cek manual di UrBackup > Status > tambah client.' }
    } catch {
        $out += ('UrBackup : GAGAL (' + $_.Exception.Message + '). CSV sudah diperbarui, ubah alamat client di UrBackup secara manual.')
    }
    return $out
}

# ---------------- penanganan permintaan ----------------
function Ip-Pc-Lain($tujuanPenuh, $berkasSendiri) {
    $h = @()
    foreach ($b in @(Get-ChildItem -LiteralPath $tujuanPenuh -Filter '*.csv' -File -ErrorAction SilentlyContinue)) {
        if ($b.Name -ieq $berkasSendiri) { continue }
        try {
            $r = Import-Csv -LiteralPath $b.FullName | Select-Object -First 1
            foreach ($x in @((('' + $r.IP) -split '\|') | Where-Object { $_ })) { $h += $x.Trim() }
        } catch { }
    }
    return $h
}

function Pilih-IpUtama($dari, $ipBaru) {
    if ($ipBaru -contains $dari) { return $dari }
    foreach ($ip in $ipBaru) { if (Alamat-Boleh $ip) { return $ip } }
    return $dari
}

function Tangani-Permintaan($ctx, $tujuanPenuh) {
    $dari = $ctx.Request.RemoteEndPoint.Address.ToString() -replace '^::ffff:', ''
    $jam = (Get-Date).ToString('HH:mm:ss')
    if (-not (Alamat-Boleh $dari)) { Balas $ctx 403 'ditolak'; Info ($jam + '  ' + $dari + '  DITOLAK (alamat tidak diizinkan)') 'Yellow'; return }
    $jalur = $ctx.Request.Url.AbsolutePath
    $metode = $ctx.Request.HttpMethod

    if ($jalur -eq '/ping' -and $metode -eq 'GET') { Balas $ctx 200 ('ok ' + $Versi); return }
    if ($jalur -eq '/nonce' -and $metode -eq 'GET') {
        if (Terkunci $dari) { Balas $ctx 429 'terlalu banyak percobaan salah, coba lagi 10 menit'; return }
        $n = Nonce-Baru
        if (-not $n) { Balas $ctx 503 'server sibuk, ulangi sebentar lagi'; return }
        Balas $ctx 200 $n
        return
    }
    if ($jalur -eq '/k8.ps1' -and $metode -eq 'GET') {
        if (-not $BerkasK8 -or -not (Test-Path -LiteralPath $BerkasK8)) { Balas $ctx 404 'k8.ps1 tidak ada di server (letakkan di folder induk skrip ini atau pakai -BerkasK8)'; return }
        $isi = [IO.File]::ReadAllText($BerkasK8, [Text.Encoding]::UTF8)
        $h = '' + $ctx.Request.UserHostName
        if ($h -match '^[A-Za-z0-9.\-]{1,64}(:\d{1,5})?$') { $isi = $isi.Replace($UrlGitHub, 'http://' + $h + '/k8.ps1') }
        Balas $ctx 200 $isi
        Info ($jam + '  ' + $dari + '  k8.ps1 diunduh dari server (cadangan LAN)') 'DarkGray'
        return
    }
    if (($jalur -eq '/installer-info' -or $jalur -eq '/installer') -and $metode -eq 'GET') {
        $i = $null
        try { $i = Info-Installer } catch { Info ($jam + '  GALAT membaca installer: ' + $_.Exception.Message) 'Red' }
        if (-not $i) { Balas $ctx 404 'installer tidak tersedia di server'; return }
        if ($jalur -eq '/installer-info') { Balas $ctx 200 ('ok ' + $i.Len + ' ' + $i.Sha); return }
        if ($script:Aktif.Count -ge $MaksKirim) { Balas $ctx 503 'server sedang melayani banyak PC, coba lagi sebentar'; return }
        Mulai-Kirim $ctx $i $dari
        return
    }
    if ($jalur -ne '/daftar' -and $jalur -ne '/sinkron') { Balas $ctx 404 'tidak ada'; return }
    if ($metode -ne 'POST') { Balas $ctx 405 'gunakan POST'; return }
    if (Terkunci $dari) { Balas $ctx 429 'terlalu banyak percobaan salah, coba lagi 10 menit'; Info ($jam + '  ' + $dari + '  DIKUNCI (percobaan salah berulang)') 'Yellow'; return }

    $panjang = $ctx.Request.ContentLength64
    if ($panjang -lt 1 -or $panjang -gt 8192) { Balas $ctx 413 'ukuran tidak sesuai'; Info ($jam + '  ' + $dari + '  DITOLAK (ukuran ' + $panjang + ')') 'Yellow'; return }
    $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
    $teks = $sr.ReadToEnd()
    $sr.Close()

    # --- buktikan password: &mac= selalu bagian paling akhir ---
    $ix = $teks.LastIndexOf('&mac=')
    $macKlien = ''
    $isiTanpaMac = ''
    if ($ix -gt 0) { $macKlien = $teks.Substring($ix + 5).Trim().ToLower(); $isiTanpaMac = $teks.Substring(0, $ix) }
    $f = Baca-Form $isiTanpaMac
    $nonceOk = $false
    if ($f.ContainsKey('nonce')) { $nonceOk = Nonce-Pakai $f['nonce'] }
    $macOk = $false
    if ($macKlien -match '^[0-9a-f]{64}$') {
        $macHitung = Hitung-Mac $kunci ($jalur + "`n" + $isiTanpaMac)
        $macOk = Sama-Aman $macKlien $macHitung
    }
    if (-not ($nonceOk -and $macOk)) {
        Catat-Gagal $dari
        Balas $ctx 401 'password salah atau kode kedaluwarsa'
        Info ($jam + '  ' + $dari + '  DITOLAK (password salah / kode kedaluwarsa)') 'Yellow'
        return
    }
    $script:Gagal.Remove($dari)

    $hasil = Periksa $f
    if (-not $hasil.Ok) { Balas $ctx 400 ('ditolak: ' + $hasil.Pesan); Info ($jam + '  ' + $dari + '  DITOLAK (' + $hasil.Pesan + ')') 'Yellow'; return }

    $tujuanBerkas = Join-Path $tujuanPenuh $hasil.Berkas
    $ada = Test-Path -LiteralPath $tujuanBerkas
    $lamaKomp = ''
    $lamaIp = @()
    if ($ada) {
        try {
            $r = Import-Csv -LiteralPath $tujuanBerkas | Select-Object -First 1
            $lamaKomp = ('' + $r.Komputer).Trim()
            $lamaIp = @((('' + $r.IP) -split '\|') | Where-Object { $_ } | ForEach-Object { $_.Trim() })
        } catch { }
    }

    if ($jalur -eq '/daftar') {
        # Ganti nama (menu 5): klien menyertakan identitas lama. Tidak boleh menimpa nama milik PC lain.
        $berkasLama = ''
        $barisLama = ''
        if ($f.ContainsKey('lama_divisi') -or $f.ContainsKey('lama_nama')) {
            $kdl = ''
            $knl = ''
            if ($f.ContainsKey('lama_divisi')) { $kdl = $f['lama_divisi'] }
            if ($f.ContainsKey('lama_nama')) { $knl = $f['lama_nama'] }
            $berkasLama = Berkas-Identitas $kdl $knl
            if (-not $berkasLama) {
                Balas $ctx 400 'ditolak: identitas lama tidak valid'
                Info ($jam + '  ' + $dari + '  GANTI NAMA ditolak (identitas lama tidak valid)') 'Yellow'
                return
            }
            if ($ada -and $lamaKomp -and ($lamaKomp -ine $hasil.PC)) {
                Balas $ctx 409 ('nama ' + $hasil.Label + ' \ ' + $hasil.Nama + ' sudah dipakai PC ' + $lamaKomp + ', bukan PC ini (' + $hasil.PC + '). Ganti nama tidak boleh menimpa orang lain. Kalau memang ganti PC, pakai menu 1 (Pasang / daftar).')
                Info ($jam + '  ' + $dari + '  GANTI NAMA ditolak: ' + $hasil.Label + ' \ ' + $hasil.Nama + ' milik PC ' + $lamaKomp + ', bukan ' + $hasil.PC) 'Yellow'
                return
            }
        }
        [IO.File]::WriteAllText($tujuanBerkas, $hasil.Isi, (New-Object System.Text.UTF8Encoding($false)))
        $kata = 'DIPERBARUI'
        $warna = 'Green'
        if (-not $ada) { $kata = 'BARU' }
        elseif ($lamaKomp -and ($lamaKomp -ine $hasil.PC)) { $kata = 'DIGANTI (sebelumnya PC ' + $lamaKomp + ')'; $warna = 'Yellow' }
        Info ($jam + '  ' + $dari + '  DAFTAR ' + $kata + '  ' + $hasil.PC + '  ->  ' + $hasil.Label + ' \ ' + $hasil.Nama) $warna
        if ($berkasLama) {
            if ($berkasLama -ieq $hasil.Berkas) { $barisLama = 'LAMA: sama dengan identitas baru, tidak ada yang diarsipkan.' }
            else { $barisLama = Arsipkan-Lama $tujuanPenuh $berkasLama $hasil.PC }
            Info ('                        ' + $barisLama) 'DarkGray'
        }
        $tambah = ''
        if ($barisLama) { $tambah = "`n" + $barisLama }
        Balas $ctx 200 ($hasil.Label + ' \ ' + $hasil.Nama + ' (' + $kata + ')' + $tambah)
        return
    }

    # --- /sinkron ---
    if (-not $ada) {
        Balas $ctx 404 'PC ini belum terdaftar di server. Pilih menu 1 (Pasang / daftar) dulu.'
        Info ($jam + '  ' + $dari + '  SINKRON ditolak: belum terdaftar (' + $hasil.Label + ' \ ' + $hasil.Nama + ')') 'Yellow'
        return
    }
    if ($lamaKomp -and ($lamaKomp -ine $hasil.PC)) {
        Balas $ctx 409 ('nama ini terdaftar untuk PC ' + $lamaKomp + ', bukan PC ini (' + $hasil.PC + '). Kalau memang ganti PC, pakai menu 1 (Pasang / daftar).')
        Info ($jam + '  ' + $dari + '  SINKRON ditolak: milik PC ' + $lamaKomp + ', bukan ' + $hasil.PC) 'Yellow'
        return
    }
    $ipUtama = Pilih-IpUtama $dari $hasil.IPs
    $lain = @(Ip-Pc-Lain $tujuanPenuh $hasil.Berkas)
    [IO.File]::WriteAllText($tujuanBerkas, $hasil.Isi, (New-Object System.Text.UTF8Encoding($false)))
    $berubah = $false
    foreach ($ip in $hasil.IPs) { if ($lamaIp -notcontains $ip) { $berubah = $true } }
    foreach ($ip in $lamaIp) { if ($hasil.IPs -notcontains $ip) { $berubah = $true } }
    $baris = @()
    $baris += ('SINKRON OK  ' + $hasil.Label + ' \ ' + $hasil.Nama + '  (PC ' + $hasil.PC + ')')
    $baris += ('IP lama  : ' + ($lamaIp -join ', '))
    $baris += ('IP baru  : ' + ($hasil.IPs -join ', ') + '   (utama: ' + $ipUtama + ')')
    $baris += Sinkron-Ub $hasil.PC $lamaIp $hasil.IPs $ipUtama $lain
    $kataLog = 'tidak ada perubahan IP'
    if ($berubah) { $kataLog = 'IP berubah' }
    Info ($jam + '  ' + $dari + '  SINKRON ' + $hasil.PC + '  ->  ' + $hasil.Label + ' \ ' + $hasil.Nama + '  (' + $kataLog + ')') 'Green'
    foreach ($b in $baris) { if ($b -like 'UrBackup*') { Info ('                        ' + $b) 'DarkGray' } }
    Balas $ctx 200 ($baris -join "`n")
}

# ---------------- mulai ----------------
$firewallDibuat = $false
$listener = $null
try {
    $sandi = $env:K8_SANDI
    if (-not $sandi) {
        $sandi = Baca-Rahasia 'Buat password pemasangan PC (min 8 karakter, tanpa spasi, tidak disimpan di disk)'
        if ($sandi -cnotmatch '^[\x21-\x7E]{8,64}$') { throw 'Password harus 8-64 karakter ASCII tanpa spasi.' }
        $ulang = Baca-Rahasia 'Ketik ulang password'
        if ($ulang -cne $sandi) { throw 'Kedua password tidak sama.' }
    }
    if ($sandi -cnotmatch '^[\x21-\x7E]{8,64}$') { throw 'Password harus 8-64 karakter ASCII tanpa spasi.' }
    $kunci = [Text.Encoding]::UTF8.GetBytes($sandi)
    $sandi = $null
    Remove-Item Env:K8_SANDI -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $Tujuan)) { New-Item -ItemType Directory -Path $Tujuan -Force | Out-Null }
    $tujuanPenuh = (Resolve-Path -LiteralPath $Tujuan).Path

    $script:UbUserPakai = $UbUser
    if (-not $TanpaUrBackup) {
        $uriUb = $null
        try { $uriUb = [Uri]$UbUrl } catch { throw ('Alamat UrBackup tidak valid: ' + $UbUrl) }
        if ($uriUb.Host -ne '127.0.0.1' -and $uriUb.Host -ne 'localhost') { throw 'Alamat UrBackup harus komputer ini (127.0.0.1) karena password dikirim tanpa enkripsi.' }
        try { Ub-Masuk; $script:UbAktif = $true; Info ('UrBackup terhubung (' + $UbUrl + '): sinkron IP akan memperbarui alamat client.') 'Green' }
        catch { Info ('UrBackup TIDAK terhubung: ' + $_.Exception.Message + '. Sinkron IP hanya mencatat ke CSV.') 'Yellow' }
    } else {
        Info 'Mode tanpa UrBackup: sinkron IP hanya mencatat ke CSV.' 'Yellow'
    }

    if ($BukaFirewall) {
        & netsh advfirewall firewall delete rule name="$NamaAturan" | Out-Null
        & netsh advfirewall firewall add rule name="$NamaAturan" dir=in action=allow protocol=TCP localport=$Port remoteip=$AlamatFirewall profile=any | Out-Null
        $firewallDibuat = $true
        Info ('Firewall: TCP ' + $Port + ' dibuka dari ' + $AlamatFirewall + ' (dihapus otomatis saat skrip berhenti).') 'Green'
    }

    # Installer untuk PC (opsional): tampilkan status, periksa terhadap hash resmi.
    $pInst = Cari-Installer
    $inst = $null
    try { $inst = Info-Installer } catch { Info ('Installer tidak bisa dibaca: ' + $_.Exception.Message) 'Yellow' }
    if ($inst) {
        $resmi = Hash-Resmi
        $ket = 'hash resmi tidak bisa dibandingkan (k8.ps1 tidak terbaca)'
        $wr = 'Yellow'
        if ($resmi) {
            if ($inst.Sha -eq $resmi) { $ket = 'COCOK dengan hash resmi UrBackup Client (PC akan memakainya)'; $wr = 'Green' }
            else { $ket = 'BEDA dari hash resmi di k8.ps1: PC akan MENOLAK file ini dan mengunduh dari internet. Pakai file asli dari urbackup.org.' }
        }
        Info ('Installer untuk PC: ' + $inst.Path + '  (' + [math]::Round($inst.Len / 1MB, 1) + ' MB)') 'Cyan'
        Info ('   SHA256 ' + $inst.Sha) 'Cyan'
        Info ('   ' + $ket) $wr
        try {
            $sg = Get-AuthenticodeSignature -FilePath $inst.Path
            if ($sg) {
                $pen = ''
                if ($sg.SignerCertificate) { $pen = ' - ' + $sg.SignerCertificate.Subject }
                Info ('   Tanda tangan: ' + $sg.Status + $pen) 'DarkGray'
            }
        } catch { }
    } else {
        Info ('Installer untuk PC: TIDAK ADA (' + $pInst + '). PC akan mengunduh 57 MB dari internet satu-satu.') 'Yellow'
        Info '   Taruh file UrBackup Client 2.5.32.exe di folder itu (nama bebas, awali "UrBackup"), lalu tidak perlu restart.' 'Yellow'
    }
    $script:Pool = [runspacefactory]::CreateRunspacePool(1, $MaksKirim)
    $script:Pool.Open()

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    $tanpaBatas = ($MenitMaks -le 0)
    $batas = (Get-Date).AddMinutes($MenitMaks)
    Info ('Penerima aktif di ' + $Prefix + '  ->  ' + $tujuanPenuh) 'Cyan'
    $ketBatas = 'Berhenti otomatis: ' + $batas.ToString('HH:mm')
    if ($tanpaBatas) { $ketBatas = 'Tanpa batas waktu' }
    Info ('Hanya dari: ' + ($Izinkan -join ', ') + '   ' + $ketBatas + '   (Ctrl+C untuk berhenti)') 'Cyan'

    while ($tanpaBatas -or (Get-Date) -lt $batas) {
        $tugas = $listener.GetContextAsync()
        while (-not $tugas.AsyncWaitHandle.WaitOne(500)) {
            Bersih-Kirim
            if (-not $tanpaBatas -and (Get-Date) -ge $batas) { break }
        }
        if (-not $tugas.IsCompleted) { break }
        $ctx = $tugas.Result
        try {
            Tangani-Permintaan $ctx $tujuanPenuh
        } catch {
            Info ((Get-Date).ToString('HH:mm:ss') + '  GALAT: ' + $_.Exception.Message) 'Red'
            try { Balas $ctx 500 'galat di server' } catch { }
        }
        Bersih-Kirim
    }
    Info 'Waktu habis. Penerima berhenti.' 'Yellow'
}
catch {
    Info ('GAGAL: ' + $_.Exception.Message) 'Red'
    $script:Keluar = 1
}
finally {
    if ($listener) { try { $listener.Stop(); $listener.Close() } catch { } }
    foreach ($a in @($script:Aktif)) { try { $a.PS.Stop() } catch { } try { $a.PS.Dispose() } catch { } }
    if ($script:Pool) { try { $script:Pool.Close(); $script:Pool.Dispose() } catch { } }
    if ($firewallDibuat) {
        & netsh advfirewall firewall delete rule name="$NamaAturan" | Out-Null
        Info 'Aturan firewall penerima dihapus.' 'Green'
    }
}
if ($script:Keluar) { exit $script:Keluar }
