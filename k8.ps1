# =====================================================================================
#  k8.ps1  -  Kedaton 8: menu UrBackup Client (pasang / sinkron IP / muat ulang koneksi / cek status)
#
#  Dijalankan dari cmd ATAU PowerShell, Windows 8.1 / 10 / 11 (PowerShell 4.0 ke atas), satu baris:
#
#    powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=3072; irm https://raw.githubusercontent.com/CahNdesoID/k8-backup/main/k8.ps1 | iex"
#
#  Tidak ada token dan tidak ada password di file ini. Password pemasangan ditanya saat dipakai (tersembunyi),
#  tidak pernah dikirim lewat jaringan (yang dikirim hanya HMAC-SHA256 dengan kode sekali pakai dari server),
#  dan tidak disimpan di PC. Data yang dikirim ke server: nama PC, divisi, nama orang, IP, label/ukuran drive,
#  nama folder tingkat atas C:\. Isi file tidak dibaca.
# =====================================================================================

$K8Versi = 'k8-4'
$K8Url = 'https://raw.githubusercontent.com/CahNdesoID/k8-backup/main/k8.ps1'
if ($env:K8_URL) { $K8Url = $env:K8_URL }
$ServerIP = '192.168.1.88'
if ($env:K8_SERVER) { $ServerIP = $env:K8_SERVER }
$PortTerima = 8088
if ($env:K8_PORT) { $PortTerima = [int]$env:K8_PORT }
$PortUb = 55414
$UbVersi = '2.5.32'
$UbInstaller = 'https://hndl.urbackup.org/Client/' + $UbVersi + '/UrBackup%20Client%20' + $UbVersi + '.exe'
if ($env:K8_INSTALLER) { $UbInstaller = $env:K8_INSTALLER }
# Hash resmi installer UrBackup Client 2.5.32 (sama dengan manifest winget UrBackup.UrBackup.Client). Ganti bersama $UbVersi.
$UbSha256 = '4F531D823DB8CCAA384D383D26BAAB050C3739AE7F9B2E34566F4CA0466BF90A'
if ($env:K8_SHA256) { $UbSha256 = $env:K8_SHA256 }
$UnduhBatasMs = 20000
$AkarC = ''
if ($env:K8_AKARC) { $AkarC = $env:K8_AKARC }
$FolderData = Join-Path $env:ProgramData 'Kedaton8Backup'
$BerkasIdentitas = Join-Path $FolderData 'identitas.txt'
$script:Sandi = ''

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }

$DivisiValid = @('Housekeeping', 'IT', 'Marketing', 'Purchasing', 'Finance', 'HRD', 'HR', 'Corsec', 'Legal', 'Senior Manager', 'Audit', 'Accounting', 'Kasir')

# Folder tingkat atas C:\ yang dianggap SISTEM (tidak perlu dibackup). Selain ini = kemungkinan data pengguna.
$SistemC = '(?i)^(Windows|Windows\.old|Program Files|Program Files \(x86\)|ProgramData|Users|Recovery|PerfLogs|\$Recycle\.Bin|System Volume Information|Documents and Settings|MSOCache|Config\.Msi|\$WINDOWS\.~BT|\$WINDOWS\.~WS|\$WinREAgent|\$SysReset|Intel|AMD|NVIDIA|inetpub|OneDriveTemp|SWSetup|SWTOOLS|HP|Dell)$'
# Adaptor virtual / hotspot: alamatnya tidak relevan untuk server backup.
$AdaptorMaya = '(?i)wi-?fi direct|hosted network|vmware|virtualbox|vbox|hyper-v|vethernet|docker|tap-windows|bluetooth|tunnel|pseudo'
# Label drive yang mencurigakan sebagai partisi pemulihan/OEM.
$CurigaPulih = '(?i)recover|restore|winre|reserved|diag|factory|oem|hp_tools|lenovo_part'
# File kepercayaan server milik UrBackup Client (Windows: di folder program client).
$BerkasPercaya = @('server_idents.txt', 'session_idents.txt', 'new_server_idents.txt')

function Info($t, $warna) { if ($warna) { Write-Host $t -ForegroundColor $warna } else { Write-Host $t } }

function Baca-Rahasia($tanya) {
    $ss = Read-Host $tanya -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Tanya($t) { return ('' + (Read-Host $t)).Trim() }

function Ya-Tidak($t) {
    $j = Tanya ('  ' + $t + ' [Y = ya, T = batal]')
    return ($j -match '(?i)^y')
}

function Adalah-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Perintah untuk jendela Administrator: tampilkan pesan dulu (supaya jendela tidak tampak kosong saat menu diunduh),
# lalu ambil menu. Kalau gagal, jendela menunggu Enter supaya pesan galatnya sempat terbaca.
function Perintah-Naik {
    return ('Write-Host ''Mengambil menu Kedaton 8, tunggu sebentar ...''; [Net.ServicePointManager]::SecurityProtocol=3072; ' +
        'try { irm ''' + $K8Url + ''' | iex } catch { Write-Host (''GAGAL: '' + $_.Exception.Message) -ForegroundColor Red; [void](Read-Host ''Tekan Enter untuk menutup'') }')
}

function Naik-Admin {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -Command ' + (Perintah-Naik))
}

# ---------------- HMAC (password tidak pernah dikirim) ----------------
function Hex($bytes) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($x in $bytes) { [void]$sb.Append($x.ToString('x2')) }
    return $sb.ToString()
}

function Hitung-Mac($sandi, $teks) {
    $kunci = [Text.Encoding]::UTF8.GetBytes($sandi)
    $h = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $kunci)
    try { return (Hex ($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($teks)))) }
    finally { $h.Dispose() }
}

function Http($metode, $jalur, $badan) {
    $req = [Net.WebRequest]::Create('http://' + $ServerIP + ':' + $PortTerima + $jalur)
    $req.Method = $metode
    $req.Timeout = 8000
    $req.ReadWriteTimeout = 8000
    $req.Proxy = $null
    $req.KeepAlive = $false
    if ($null -ne $badan) {
        $b = [Text.Encoding]::UTF8.GetBytes($badan)
        $req.ContentType = 'application/x-www-form-urlencoded'
        $req.ContentLength = $b.Length
        try { $req.ServicePoint.Expect100Continue = $false } catch { }
        $st = $req.GetRequestStream()
        $st.Write($b, 0, $b.Length)
        $st.Close()
    }
    $res = $null
    try { $res = $req.GetResponse() }
    catch [Net.WebException] {
        $res = $_.Exception.Response
        if ($null -eq $res) { throw }
    }
    $rd = New-Object IO.StreamReader($res.GetResponseStream(), [Text.Encoding]::UTF8)
    $teks = $rd.ReadToEnd()
    $rd.Close()
    $kode = [int]$res.StatusCode
    $res.Close()
    return @{ Kode = $kode; Teks = $teks }
}

# Kirim permintaan yang ditandatangani password. Mengembalikan @{Kode; Teks}. Menanyakan password bila belum ada.
function Kirim-Bertanda($jalur, $pasang) {
    for ($coba = 1; $coba -le 3; $coba++) {
        if (-not $script:Sandi) {
            $script:Sandi = Baca-Rahasia '  Password pemasangan (minta ke IT, tidak tampil saat diketik)'
            if (-not $script:Sandi) { throw 'Password kosong.' }
        }
        $n = Http 'GET' '/nonce' $null
        if ($n.Kode -eq 429) { throw ('Server: ' + $n.Teks) }
        if ($n.Kode -ne 200) { throw ('Server menolak (HTTP ' + $n.Kode + '): ' + $n.Teks) }
        $bagian = @()
        foreach ($kv in $pasang) { $bagian += ($kv[0] + '=' + [Uri]::EscapeDataString('' + $kv[1])) }
        $bagian += ('nonce=' + $n.Teks.Trim())
        $isi = $bagian -join '&'
        $mac = Hitung-Mac $script:Sandi ($jalur + "`n" + $isi)
        $r = Http 'POST' $jalur ($isi + '&mac=' + $mac)
        if ($r.Kode -eq 401) {
            $script:Sandi = ''
            Info '  Password salah.' 'Red'
            continue
        }
        return $r
    }
    throw 'Password salah 3 kali. Tanyakan password yang benar ke IT.'
}

# ---------------- data PC ----------------
function Format-Disk($huruf, $label, $total, $bebas) {
    $lab = ('' + $label) -replace '[,;"|=:\r\n]', '_'
    $tg = [math]::Round($total / 1GB)
    $pg = [math]::Round(($total - $bebas) / 1GB)
    return ($huruf + '=' + $lab + '=' + $tg + '=' + $pg)
}

function Pindai {
    $semua = @()
    $utama = @()
    try {
        foreach ($n in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($n.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($n.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            $maya = (($n.Description + ' ' + $n.Name) -match $AdaptorMaya)
            foreach ($a in $n.GetIPProperties().UnicastAddresses) {
                if ($a.Address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { continue }
                $s = $a.Address.ToString()
                if ($s.StartsWith('169.254.') -or $s.StartsWith('127.')) { continue }
                $semua += $s
                if ($maya -or $s.StartsWith('192.168.137.')) { continue }
                $utama += $s
            }
        }
    } catch { }
    # Alamat hotspot Windows / adaptor virtual tidak dilaporkan; kalau hanya itu yang ada, pakai semuanya.
    $ips = @($utama)
    if ($ips.Count -eq 0) { $ips = @($semua) }
    $disk = @()
    try {
        foreach ($d in [IO.DriveInfo]::GetDrives()) {
            if ($d.DriveType -ne [IO.DriveType]::Fixed) { continue }
            if (-not $d.IsReady) { continue }
            $h = $d.Name.TrimEnd('\', '/').TrimEnd(':')
            if (-not $h) { continue }
            $disk += (Format-Disk $h $d.VolumeLabel $d.TotalSize $d.AvailableFreeSpace)
        }
    } catch { }
    $akar = $AkarC
    if (-not $akar) {
        $sd = $env:SystemDrive
        if (-not $sd) { $sd = 'C:' }
        $akar = $sd + '\'
    }
    $extra = @()
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $akar -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($f.Name -notmatch $SistemC) { $extra += ($f.Name -replace '[,;"|\r\n]', '_') }
        }
    } catch { }
    if ($ips.Count -gt 8) { $ips = @($ips | Select-Object -First 8) }
    return (New-Object PSObject -Property @{ IP = ($ips -join '|'); Disk = ($disk -join '|'); FolderC = ($extra -join '|') })
}

function Bidang-PC($p, $divisi, $nama) {
    return @(
        @('komputer', ('' + $env:COMPUTERNAME)),
        @('divisi',   $divisi),
        @('nama',     $nama),
        @('ip',       $p.IP),
        @('disk',     $p.Disk),
        @('folderc',  $p.FolderC)
    )
}

# ---------------- identitas lokal (Divisi / Nama) ----------------
function Normalisasi-Identitas($divisiMentah, $namaMentah) {
    $d = ('' + $divisiMentah).Trim()
    $divisi = $null
    if ($d -ieq 'Mandiri' -or $d -eq '-') {
        $divisi = '-'
    } else {
        $d = ($d -replace '-', ' ').Trim()
        foreach ($v in $DivisiValid) { if ($v -ieq $d) { $divisi = $v } }
        if (-not $divisi) { throw ('Divisi "' + $divisiMentah + '" tidak dikenal. Pilihan: ' + ($DivisiValid -join ', ') + ', Mandiri') }
    }
    $n = ('' + $namaMentah).Trim()
    if ($n -notmatch '^[A-Za-z0-9]{1,40}$') { throw ('Nama "' + $namaMentah + '" tidak valid. Pakai huruf dan angka saja, tanpa spasi (contoh: Rendi).') }
    if ($n -notmatch '(?i)Backup$') { $n = $n + 'Backup' }
    return @{ Divisi = $divisi; Nama = $n }
}

function Label-Divisi($d) { if ($d -eq '-') { return 'Mandiri' } else { return $d } }

function Baca-Identitas {
    if (-not (Test-Path -LiteralPath $BerkasIdentitas)) { return $null }
    try {
        $div = ''
        $nm = ''
        foreach ($baris in @(Get-Content -LiteralPath $BerkasIdentitas -ErrorAction Stop)) {
            if ($baris -match '^Divisi=(.*)$') { $div = $Matches[1].Trim() }
            if ($baris -match '^Nama=(.*)$') { $nm = $Matches[1].Trim() }
        }
        return (Normalisasi-Identitas $div $nm)
    } catch { return $null }
}

function Simpan-Identitas($divisi, $nama) {
    try {
        if (-not (Test-Path -LiteralPath $FolderData)) { New-Item -ItemType Directory -Path $FolderData -Force | Out-Null }
        $isi = 'Divisi=' + $divisi + "`r`n" + 'Nama=' + $nama + "`r`n"
        [IO.File]::WriteAllText($BerkasIdentitas, $isi, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Info ('  (identitas tidak bisa disimpan di PC ini: ' + $_.Exception.Message + ')') 'Yellow' }
}

# ---------------- UrBackup Client di PC ini ----------------
function Ub-Layanan {
    try { return @(Get-Service -ErrorAction Stop | Where-Object { $_.Name -like '*urbackup*' -or $_.DisplayName -like '*urbackup*' }) }
    catch { return @() }
}

function Layanan-Henti($s) {
    Stop-Service -InputObject $s -Force -ErrorAction Stop
    $s.WaitForStatus('Stopped', (New-TimeSpan -Seconds 30))
}

function Layanan-Mulai($s) {
    Start-Service -InputObject $s -ErrorAction Stop
    $s.WaitForStatus('Running', (New-TimeSpan -Seconds 30))
}

# Folder tempat UrBackup Client menyimpan file kepercayaan server.
function Cari-FolderClient {
    if ($env:K8_AKARCLIENT) { return $env:K8_AKARCLIENT }
    $kand = @()
    foreach ($s in (Ub-Layanan)) {
        try {
            $ip = '' + (Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $s.Name) -ErrorAction Stop).ImagePath
            $exe = ''
            if ($ip -match '^\s*"([^"]+)"') { $exe = $Matches[1] }
            elseif ($ip -match '^\s*(.+?\.exe)') { $exe = $Matches[1] }
            if ($exe) { $kand += [IO.Path]::GetDirectoryName($exe) }
        } catch { }
    }
    foreach ($p in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)) { if ($p) { $kand += (Join-Path $p 'UrBackup') } }
    $pertama = ''
    foreach ($k in $kand) {
        if (-not $k -or -not (Test-Path -LiteralPath $k)) { continue }
        if (-not $pertama) { $pertama = $k }
        foreach ($b in $BerkasPercaya) { if (Test-Path -LiteralPath (Join-Path $k $b)) { return $k } }
    }
    return $pertama
}

function Buka-Firewall {
    $aturan = @(
        @('UrBackup Client TCP (dari server)', 'TCP', '35621,35623'),
        @('UrBackup Client UDP (dari server)', 'UDP', '35622')
    )
    foreach ($a in $aturan) {
        $nama = $a[0]; $proto = $a[1]; $port = $a[2]
        & netsh advfirewall firewall delete rule name="$nama" | Out-Null
        & netsh advfirewall firewall add rule name="$nama" dir=in action=allow protocol=$proto localport=$port remoteip=$ServerIP profile=any | Out-Null
    }
    Info ('  Firewall: TCP 35621,35623 dan UDP 35622 dibuka khusus dari ' + $ServerIP) 'Green'
}

function Cek-Tcp($alamat, $port, $ms) {
    $tc = New-Object Net.Sockets.TcpClient
    try {
        $ar = $tc.BeginConnect($alamat, $port, $null, $null)
        return ($ar.AsyncWaitHandle.WaitOne($ms, $false) -and $tc.Connected)
    } catch { return $false }
    finally { $tc.Close() }
}

# ---------------- aksi: daftar ke server ----------------
function Daftar-Ke-Server($divisi, $nama) {
    $pc = $env:COMPUTERNAME
    $label = Label-Divisi $divisi
    $p = Pindai
    Info ('  Terdaftar: PC ' + $pc + '  ->  ' + $label + ' \ ' + $nama) 'Cyan'
    if ($p.IP) { Info ('  IP PC ini: ' + ($p.IP -replace '\|', ', ')) 'Cyan' } else { Info '  IP PC ini tidak terbaca (catat manual dari ipconfig).' 'Yellow' }
    Info '  Drive di PC ini:' 'Cyan'
    foreach ($e in @(($p.Disk -split '\|') | Where-Object { $_ })) {
        $a = $e -split '='
        $t = '     ' + $a[0] + ':  ' + $a[1] + '  ' + $a[2] + ' GB, terpakai ' + $a[3] + ' GB'
        if ($a[1] -match $CurigaPulih) { Info ($t + '   <-- CURIGA partisi pemulihan, jangan dibackup') 'Yellow' } else { Info $t }
    }
    if ($p.FolderC) {
        Info ('  Folder di C:\ yang BUKAN folder sistem baku: ' + ($p.FolderC -replace '\|', ', ')) 'Yellow'
        Info '     (tidak ikut backup default yang hanya mengambil C:\Users; tambahkan per PC kalau isinya data)' 'Yellow'
    }

    $terkirim = $false
    try {
        $r = Kirim-Bertanda '/daftar' (Bidang-PC $p $divisi $nama)
        if ($r.Kode -eq 200) {
            $terkirim = $true
            $warna = 'Green'
            if (('' + $r.Teks) -match 'DIGANTI') { $warna = 'Yellow' }
            Info ('  Data PC ini sudah diterima server: ' + ('' + $r.Teks).Trim()) $warna
            if ($warna -eq 'Yellow') { Info '  PERHATIAN: orang ini sebelumnya terdaftar di PC lain. Kalau bukan penggantian PC, kamu salah ketik Divisi/Nama.' 'Yellow' }
        } else {
            Info ('  Server menolak (HTTP ' + $r.Kode + '): ' + ('' + $r.Teks).Trim()) 'Yellow'
        }
    } catch {
        Info ('  Data PC ini BELUM terkirim ke server (' + $_.Exception.Message + ').') 'Yellow'
    }
    if (-not $terkirim) {
        $berkas = (($label + '_' + $nama) -replace '[^A-Za-z0-9_-]', '-') + '.csv'
        $isi = 'Komputer,Divisi,Nama,IP,Disk,FolderC' + "`r`n" + $pc + ',' + $divisi + ',' + $nama + ',' + $p.IP + ',' + $p.Disk + ',' + $p.FolderC + "`r`n"
        $tujuan = Join-Path $FolderData 'registrasi'
        if (-not (Test-Path -LiteralPath $tujuan)) { New-Item -ItemType Directory -Path $tujuan -Force | Out-Null }
        [IO.File]::WriteAllText((Join-Path $tujuan $berkas), $isi, (New-Object System.Text.UTF8Encoding($false)))
        Info ('  Disimpan di PC ini: ' + (Join-Path $tujuan $berkas)) 'Yellow'
        Info '  Jalankan menu 1 lagi setelah penerima di server aktif, atau salin file itu ke folder registrasi di server.' 'Yellow'
    }
    return $terkirim
}

# ---------------- unduh installer: progres, batas waktu, lanjutkan, coba ulang ----------------
function Ukuran-MB($b) { return ([math]::Round($b / 1MB, 1)).ToString([Globalization.CultureInfo]::InvariantCulture) }

# Satu percobaan. Melanjutkan dari file .part kalau server mendukung Range. Melempar galat kalau gagal / terputus / macet.
function Unduh-Sekali($url, $part, $langsung) {
    $mulai = [long]0
    if (Test-Path -LiteralPath $part) { $mulai = [long](Get-Item -LiteralPath $part).Length }
    $req = [Net.HttpWebRequest][Net.WebRequest]::Create($url)
    $req.Timeout = $UnduhBatasMs
    $req.ReadWriteTimeout = $UnduhBatasMs
    $req.UserAgent = 'K8Backup/' + $K8Versi
    if ($langsung) { $req.Proxy = $null }
    if ($mulai -gt 0) { $req.AddRange($mulai) }
    $res = $null
    try { $res = $req.GetResponse() }
    catch [Net.WebException] {
        $er = $_.Exception.Response
        if ($er -and [int]$er.StatusCode -eq 416) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
        throw
    }
    $st = $null
    $fs = $null
    try {
        $total = [long]$res.ContentLength
        $mode = [IO.FileMode]::Create
        if ([int]$res.StatusCode -eq 206 -and $mulai -gt 0) {
            $mode = [IO.FileMode]::Append
            if ($total -ge 0) { $total = $total + $mulai }
        } else {
            $mulai = [long]0
        }
        if ($mulai -gt 0) { Info ('  Melanjutkan dari ' + (Ukuran-MB $mulai) + ' MB') }
        $st = $res.GetResponseStream()
        $fs = New-Object IO.FileStream($part, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $buf = New-Object byte[] 65536
        $sudah = $mulai
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $tCetak = [long]0
        $bCetak = $sudah
        while (($n = $st.Read($buf, 0, $buf.Length)) -gt 0) {
            $fs.Write($buf, 0, $n)
            $sudah += $n
            $dt = $sw.ElapsedMilliseconds - $tCetak
            if ($dt -ge 3000) {
                $kec = [math]::Round((($sudah - $bCetak) / 1MB) / ($dt / 1000), 2)
                $teks = '  ' + (Ukuran-MB $sudah) + ' MB'
                if ($total -gt 0) { $teks += ' dari ' + (Ukuran-MB $total) + ' MB (' + [math]::Floor($sudah * 100 / $total) + '%)' }
                Info ($teks + '   ' + $kec.ToString([Globalization.CultureInfo]::InvariantCulture) + ' MB/detik')
                $tCetak = $sw.ElapsedMilliseconds
                $bCetak = $sudah
            }
        }
        $fs.Close()
        $fs = $null
        if ($total -ge 0 -and $sudah -ne $total) {
            throw ('Unduhan terputus di ' + (Ukuran-MB $sudah) + ' dari ' + (Ukuran-MB $total) + ' MB')
        }
    }
    finally {
        if ($fs) { $fs.Close() }
        if ($st) { $st.Close() }
        $res.Close()
    }
}

# Tiga percobaan (langsung, lewat proxy sistem, langsung; untuk LAN selalu langsung). Alamat file:// disalin saja.
function Unduh-Berkas($url, $tujuan, [switch]$HanyaLangsung) {
    $uri = $null
    try { $uri = New-Object Uri($url) } catch { }
    if ($uri -and $uri.IsFile) {
        if (-not (Test-Path -LiteralPath $uri.LocalPath -PathType Leaf)) { throw ('File installer tidak ada: ' + $uri.LocalPath) }
        Info ('  Memakai file lokal: ' + $uri.LocalPath)
        Copy-Item -LiteralPath $uri.LocalPath -Destination $tujuan -Force
        return
    }
    $part = $tujuan + '.part'
    $galat = ''
    Info ('  Mengunduh: ' + $url)
    for ($coba = 1; $coba -le 3; $coba++) {
        $langsung = ($coba -ne 2) -or $HanyaLangsung
        $cara = 'langsung'
        if (-not $langsung) { $cara = 'lewat proxy sistem' }
        Info ('  Percobaan ' + $coba + ' dari 3 (' + $cara + ') ...')
        try {
            Unduh-Sekali $url $part $langsung
            Move-Item -LiteralPath $part -Destination $tujuan -Force
            return
        } catch {
            $galat = $_.Exception.Message
            Info ('  Gagal: ' + $galat) 'Yellow'
            if ($coba -lt 3) { Start-Sleep -Seconds 3 }
        }
    }
    throw ('Unduhan gagal 3 kali (' + $galat + ')')
}

function Sha256-Berkas($berkas) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $f = [IO.File]::OpenRead($berkas)
    try { return (Hex ($sha.ComputeHash($f))) }
    finally { $f.Close(); $sha.Dispose() }
}

# Installer dari server kantor lewat LAN (jauh lebih cepat dari internet). Mengembalikan $true kalau $out sudah terisi
# dan terbukti sama dengan hash resmi. Gagal / tidak tersedia / tidak cocok -> $false (pemanggil lanjut ke internet).
function Ambil-Dari-Server($out) {
    $info = $null
    try { $info = Http 'GET' '/installer-info' $null }
    catch { Info '  Penerima di server tidak terjangkau, installer tidak diambil dari server. Pakai internet.' 'Yellow'; return $false }
    $teks = ('' + $info.Teks).Trim()
    $sah = (($info.Kode -eq 200) -and ($teks -match '^ok (\d{1,12}) ([0-9a-f]{64})$'))
    if (-not $sah) {
        Info '  Server belum menyediakan installer. Pakai internet.' 'Yellow'
        return $false
    }
    $panjang = [long]$Matches[1]
    $shaServer = $Matches[2]
    if ($UbSha256 -and ($shaServer -ine $UbSha256)) {
        Info ('  Installer di server BUKAN hash resmi UrBackup Client ' + $UbVersi + ', tidak dipakai. Pakai internet.') 'Yellow'
        return $false
    }
    $lan = $out + '.lan'
    Remove-Item -LiteralPath $lan, ($lan + '.part') -Force -ErrorAction SilentlyContinue
    try {
        Info ('  Installer tersedia di server (' + (Ukuran-MB $panjang) + ' MB). Mengunduh lewat LAN ...')
        Unduh-Berkas ('http://' + $ServerIP + ':' + $PortTerima + '/installer') $lan -HanyaLangsung
        if ((Get-Item -LiteralPath $lan).Length -ne $panjang) { throw 'ukuran tidak sama dengan yang diumumkan server' }
        $sha = Sha256-Berkas $lan
        if ($sha -ine $shaServer) { throw 'SHA256 tidak sama dengan yang diumumkan server' }
        Move-Item -LiteralPath $lan -Destination $out -Force
        Info '  Installer dari server terverifikasi (ukuran dan SHA256 cocok).' 'Green'
        return $true
    } catch {
        Info ('  Unduhan dari server gagal: ' + $_.Exception.Message + '. Pakai internet.') 'Yellow'
        Remove-Item -LiteralPath $lan, ($lan + '.part') -Force -ErrorAction SilentlyContinue
        return $false
    }
}

# Dapatkan installer di $out: server kantor (LAN) -> internet -> file yang diunduh sendiri lewat browser.
# K8_INSTALLER (alamat / file:// lokal) melewati server.
function Ambil-Installer($out) {
    if (-not $env:K8_INSTALLER) {
        if (Ambil-Dari-Server $out) { return }
    }
    try { Unduh-Berkas $UbInstaller $out; return }
    catch { Info ('  ' + $_.Exception.Message) 'Yellow' }
    Info '  Cara lain: unduh installernya lewat browser dari alamat di atas, lalu ketik lokasi filenya di sini.' 'Yellow'
    $lok = (Tanya '  Lokasi file installer (kosongkan untuk batal)') -replace '^"+|"+$', ''
    if (-not $lok) { throw 'Dibatalkan: installer belum ada.' }
    if (-not (Test-Path -LiteralPath $lok -PathType Leaf)) { throw ('File tidak ditemukan: ' + $lok) }
    Copy-Item -LiteralPath $lok -Destination $out -Force
}

function Cek-Exe($berkas) {
    $kb = [math]::Round((Get-Item -LiteralPath $berkas).Length / 1KB)
    if ($kb -lt 1024) { throw ('File terlalu kecil (' + $kb + ' KB), kemungkinan bukan installer. Cek koneksi internet / URL.') }
    $mz = New-Object byte[] 2
    $f = [IO.File]::OpenRead($berkas)
    try { [void]$f.Read($mz, 0, 2) } finally { $f.Close() }
    if ($mz[0] -ne 0x4D -or $mz[1] -ne 0x5A) { throw 'File bukan program Windows (.exe). Kemungkinan halaman galat yang terunduh.' }
    return $kb
}

# Hash dibandingkan dengan hash resmi; tanda tangan digital dilaporkan. Tidak cocok DAN tanda tangan bukan Valid = tanya dulu.
function Cek-Keaslian($berkas) {
    $sha = Sha256-Berkas $berkas
    $cocok = [bool]($UbSha256 -and ($sha -ieq $UbSha256))
    $sig = $null
    try { $sig = Get-AuthenticodeSignature -FilePath $berkas } catch { }
    $status = ''
    $penanda = ''
    if ($sig) {
        $status = '' + $sig.Status
        if ($sig.SignerCertificate) { $penanda = ' - ' + $sig.SignerCertificate.Subject }
    }
    if ($cocok) { Info ('  SHA256 cocok dengan hash resmi UrBackup Client ' + $UbVersi + '.') 'Green' }
    else { Info ('  SHA256 file ini ' + $sha + ' berbeda dari hash resmi yang tercatat.') 'Yellow' }
    if ($sig) { Info ('  Tanda tangan: ' + $status + $penanda) }
    if ($status -eq 'HashMismatch') { throw 'Tanda tangan rusak (HashMismatch). Install dibatalkan.' }
    if (-not $cocok -and $status -ne 'Valid') {
        Info '  File ini tidak bisa diverifikasi (hash tidak sama dan tanda tangan bukan Valid).' 'Yellow'
        if (-not (Ya-Tidak 'Tetap pasang file ini?')) { throw 'Dibatalkan: installer tidak terverifikasi.' }
    }
}

# ---------------- aksi 1: pasang / daftar ----------------
function Aksi-Pasang($divisi, $nama, [switch]$TanpaInstall) {
    $svc = @(Ub-Layanan)
    if ($svc.Count -gt 0) {
        Info ('  UrBackup Client sudah terpasang (' + $svc[0].DisplayName + ', status: ' + $svc[0].Status + '). Lewati unduh dan install.') 'Yellow'
    } else {
        $out = Join-Path $env:TEMP ('UrBackupClient-' + $UbVersi + '.exe')
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
        Ambil-Installer $out
        $kb = Cek-Exe $out
        Info ('  Installer siap: ' + $kb + ' KB')

        Cek-Keaslian $out

        if ($TanpaInstall) {
            Info '  SIMULASI: unduhan OK. Lewati install dan firewall.' 'Cyan'
        } else {
            Info '  Memasang (silent)...'
            $proses = Start-Process -FilePath $out -ArgumentList '/S' -Wait -PassThru
            if ($proses.ExitCode -ne 0) { throw ('Installer berhenti dengan kode ' + $proses.ExitCode) }
            $ok = $false
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Seconds 2
                $svc = @(Ub-Layanan)
                if ($svc.Count -gt 0 -and $svc[0].Status -eq 'Running') { $ok = $true; break }
            }
            if ($ok) { Info ('  Service berjalan: ' + $svc[0].DisplayName) 'Green' }
            else { Info '  PERINGATAN: service UrBackup belum terlihat berjalan. Cek di services.msc.' 'Yellow' }
            try { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    if (-not $TanpaInstall) { Buka-Firewall }

    Simpan-Identitas $divisi $nama
    [void](Daftar-Ke-Server $divisi $nama)

    Write-Host ''
    Info '  === SELESAI ===' 'Green'
    Info ('  Nama PC ini di UrBackup : ' + $env:COMPUTERNAME) 'Cyan'
    if (Cek-Tcp $ServerIP $PortUb 3000) { Info ('  Server ' + $ServerIP + ':' + $PortUb + ' terjangkau dari PC ini.') }
    else { Info ('  Server ' + $ServerIP + ':' + $PortUb + ' TIDAK terjangkau dari PC ini (cek jaringan/VLAN).') 'Yellow' }
    Info '  Penambahan PC ini di UrBackup dilakukan dari server (hari Minggu).'
}

# ---------------- aksi 2: sinkron IP ----------------
function Aksi-Sinkron($divisi, $nama) {
    $p = Pindai
    if (-not $p.IP) { throw 'IP PC ini tidak terbaca. Cek kabel / WiFi lalu coba lagi.' }
    Info ('  IP PC ini sekarang: ' + ($p.IP -replace '\|', ', ')) 'Cyan'
    $r = Kirim-Bertanda '/sinkron' (Bidang-PC $p $divisi $nama)
    Write-Host ''
    if ($r.Kode -eq 200) {
        foreach ($baris in @(('' + $r.Teks) -split "`n")) {
            $b = $baris.TrimEnd("`r")
            if (-not $b) { continue }
            $warna = $null
            if ($b -match 'GAGAL|PERINGATAN') { $warna = 'Yellow' } elseif ($b -match '^SINKRON OK') { $warna = 'Green' }
            Info ('  ' + $b) $warna
        }
        return $true
    }
    Info ('  Server menolak (HTTP ' + $r.Kode + '): ' + ('' + $r.Teks).Trim()) 'Yellow'
    return $false
}

# ---------------- aksi 3: muat ulang koneksi ----------------
function Aksi-Reset([switch]$Ya) {
    $svc = @(Ub-Layanan)
    if ($svc.Count -eq 0) { throw 'UrBackup Client belum terpasang di PC ini. Pilih menu 1 dulu.' }
    $folder = Cari-FolderClient
    if (-not $folder) { throw 'Folder UrBackup Client tidak ditemukan. Cek C:\Program Files\UrBackup.' }
    Info ('  Folder UrBackup Client: ' + $folder)
    $ada = @($BerkasPercaya | Where-Object { Test-Path -LiteralPath (Join-Path $folder $_) })
    if ($ada.Count -eq 0) {
        Info '  Tidak ada file kepercayaan server di PC ini: client belum pernah terhubung ke server mana pun.' 'Green'
        Info '  Berarti tidak ada yang perlu direset. Kalau tetap tidak tersambung, cek menu 4 (firewall / jangkauan server).' 'Green'
        return $false
    }
    Info '  File kepercayaan server yang akan direset (disimpan sebagai cadangan, tidak dihapus):'
    foreach ($b in $ada) { Info ('     ' + $b) }
    if (-not $Ya) {
        Info '  Layanan UrBackup dihentikan sebentar. Backup yang sedang berjalan akan terputus.' 'Yellow'
        if (-not (Ya-Tidak 'Lanjut reset?')) { Info '  Dibatalkan.' 'Yellow'; return $false }
    }
    $cap = (Get-Date).ToString('yyyyMMdd-HHmmss')
    try {
        foreach ($s in $svc) {
            if ($s.Status -ne 'Stopped') { Info ('  Menghentikan layanan ' + $s.DisplayName + ' ...'); Layanan-Henti $s }
        }
        foreach ($b in $ada) {
            $asal = Join-Path $folder $b
            $nm = $b + '.bak-' + $cap
            $n = 1
            while (Test-Path -LiteralPath (Join-Path $folder $nm)) { $nm = $b + '.bak-' + $cap + '-' + $n; $n++ }
            Rename-Item -LiteralPath $asal -NewName $nm -ErrorAction Stop
        }
        Info ('  File lama disimpan dengan akhiran .bak-' + $cap + ' (ganti nama kembali kalau perlu mengembalikan).') 'Green'
    }
    finally {
        # layanan SELALU dijalankan lagi, walau langkah di atas gagal
        foreach ($s in $svc) {
            try { Info ('  Menjalankan layanan ' + $s.DisplayName + ' ...'); Layanan-Mulai $s }
            catch { Info ('  GAGAL menjalankan layanan ' + $s.DisplayName + ': ' + $_.Exception.Message + ' (jalankan manual di services.msc)') 'Red' }
        }
    }
    Buka-Firewall
    Info '  Layanan berjalan lagi. Client kini menerima server pertama yang menghubunginya (server backup kantor).' 'Green'
    $baru = Join-Path $folder $BerkasPercaya[0]
    Info '  Menunggu server menghubungi PC ini (maks 45 detik) ...'
    $tersambung = $false
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 3
        if (Test-Path -LiteralPath $baru) { $tersambung = $true; break }
    }
    if ($tersambung) { Info '  Server sudah menghubungi PC ini dan dipercaya. Koneksi normal seperti baru terpasang.' 'Green' }
    else {
        Info '  Belum ada server yang menghubungi dalam 45 detik. Itu normal kalau PC ini belum ditambahkan di UrBackup' 'Yellow'
        Info '  atau IP-nya berubah. Jalankan menu 2 (Sinkron IP), lalu minta IT menambahkan PC ini (hari Minggu).' 'Yellow'
    }
    return $true
}

# ---------------- aksi 4: cek status ----------------
function Tandai($ok, $teks) {
    if ($ok) { Info ('  [ OK ] ' + $teks) 'Green' } else { Info ('  [ !! ] ' + $teks) 'Yellow' }
}

function Aksi-Status {
    $p = Pindai
    Info ('  PC            : ' + $env:COMPUTERNAME + '   Windows ' + [Environment]::OSVersion.Version + '   PowerShell ' + $PSVersionTable.PSVersion)
    Info ('  IP            : ' + ($p.IP -replace '\|', ', '))
    $id = Baca-Identitas
    if ($id) { Tandai $true ('Terdaftar sebagai: ' + (Label-Divisi $id.Divisi) + ' \ ' + $id.Nama) }
    else { Tandai $false 'Belum ada identitas tersimpan di PC ini (pilih menu 1).' }
    $svc = @(Ub-Layanan)
    if ($svc.Count -eq 0) { Tandai $false 'UrBackup Client BELUM terpasang (pilih menu 1).' }
    else { Tandai ($svc[0].Status -eq 'Running') ('Layanan ' + $svc[0].DisplayName + ': ' + $svc[0].Status) }
    $folder = Cari-FolderClient
    if ($folder) {
        $b = Join-Path $folder $BerkasPercaya[0]
        if (Test-Path -LiteralPath $b) { Tandai $true ('Client mempercayai sebuah server (' + $BerkasPercaya[0] + ' ada).') }
        else { Tandai $false 'Client belum mempercayai server mana pun (belum pernah dihubungi server).' }
    }
    $fwOk = $true
    foreach ($nm in @('UrBackup Client TCP (dari server)', 'UrBackup Client UDP (dari server)')) {
        & netsh advfirewall firewall show rule name="$nm" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $fwOk = $false }
    }
    Tandai $fwOk 'Aturan firewall UrBackup (dari server)'
    $ping = $null
    try { $ping = Http 'GET' '/ping' $null } catch { }
    if ($ping -and $ping.Kode -eq 200) { Tandai $true ('Penerima di server aktif (' + $ServerIP + ':' + $PortTerima + ', ' + $ping.Teks.Trim() + ').') }
    else { Tandai $false ('Penerima di server TIDAK aktif / tidak terjangkau (' + $ServerIP + ':' + $PortTerima + '). Perlu hanya untuk menu 1 dan 2; minta IT menjalankannya.') }
    Tandai (Cek-Tcp $ServerIP $PortUb 3000) ('Server UrBackup ' + $ServerIP + ':' + $PortUb + ' terjangkau')
}

# ---------------- menu ----------------
function Pilih-Divisi {
    Info '  Pilih divisi:'
    for ($i = 0; $i -lt $DivisiValid.Count; $i++) { Info ('     ' + ($i + 1).ToString().PadLeft(2) + '. ' + $DivisiValid[$i]) }
    Info ('     ' + ($DivisiValid.Count + 1).ToString().PadLeft(2) + '. Mandiri (bukan divisi)')
    $j = Tanya '  Nomor atau nama divisi'
    if ($j -match '^\d+$') {
        $n = [int]$j
        if ($n -ge 1 -and $n -le $DivisiValid.Count) { return $DivisiValid[$n - 1] }
        if ($n -eq ($DivisiValid.Count + 1)) { return 'Mandiri' }
        throw 'Nomor divisi tidak ada.'
    }
    return $j
}

function Minta-Identitas {
    $d = Pilih-Divisi
    $n = Tanya '  Nama orang (huruf/angka, tanpa spasi, contoh: Rendi)'
    return (Normalisasi-Identitas $d $n)
}

function Menu-Pasang {
    $id = Baca-Identitas
    if ($id) {
        Info ('  PC ini sudah tercatat sebagai: ' + (Label-Divisi $id.Divisi) + ' \ ' + $id.Nama)
        if (-not (Ya-Tidak 'Pakai identitas ini?')) { $id = $null }
    }
    if (-not $id) { $id = Minta-Identitas }
    Write-Host ''
    Info ('  PC ini (' + $env:COMPUTERNAME + ') akan didaftarkan sebagai:')
    Info ('      ' + (Label-Divisi $id.Divisi) + ' \ ' + $id.Nama) 'Cyan'
    if (-not (Ya-Tidak 'Lanjut?')) { Info '  Dibatalkan.' 'Yellow'; return }
    Aksi-Pasang $id.Divisi $id.Nama
}

function Menu-Sinkron {
    $id = Baca-Identitas
    if (-not $id) {
        Info '  Identitas PC ini belum tersimpan di sini. Isi sama persis seperti saat pemasangan:' 'Yellow'
        $id = Minta-Identitas
    } else {
        Info ('  Identitas: ' + (Label-Divisi $id.Divisi) + ' \ ' + $id.Nama)
    }
    if (Aksi-Sinkron $id.Divisi $id.Nama) { Simpan-Identitas $id.Divisi $id.Nama }
}

function Menu-Reset { [void](Aksi-Reset) }

function Jalankan($blok) {
    Write-Host ''
    try { & $blok }
    catch { Info ('  GAGAL: ' + $_.Exception.Message) 'Red' }
    Write-Host ''
    [void](Read-Host '  Tekan Enter untuk kembali ke menu')
}

function Tampil-Header {
    Clear-Host
    $id = Baca-Identitas
    $ket = 'belum terdaftar'
    if ($id) { $ket = (Label-Divisi $id.Divisi) + ' \ ' + $id.Nama }
    $p = Pindai
    Info ('  ' + ('=' * 66)) 'Cyan'
    Info '   KEDATON 8  -  UrBackup Client' 'Cyan'
    Info ('   PC: ' + $env:COMPUTERNAME + '    IP: ' + ($p.IP -replace '\|', ', ')) 'Cyan'
    Info ('   Terdaftar: ' + $ket + '    Server: ' + $ServerIP) 'Cyan'
    Info ('  ' + ('=' * 66)) 'Cyan'
    Write-Host ''
    Info '   [1]  Pasang / daftar PC ini'
    Info '   [2]  Sinkron IP            (kalau IP PC ini berubah)'
    Info '   [3]  Muat ulang koneksi    (reset ke server backup, seperti baru terpasang)'
    Info '   [4]  Cek status'
    Info '   [0]  Keluar'
    Write-Host ''
}

function Menu-Utama {
    while ($true) {
        Tampil-Header
        $pilih = Tanya '  Pilih [0-4]'
        switch ($pilih) {
            '1' { Jalankan { Menu-Pasang } }
            '2' { Jalankan { Menu-Sinkron } }
            '3' { Jalankan { Menu-Reset } }
            '4' { Jalankan { Write-Host ''; Aksi-Status } }
            '0' { return }
            default { Info '  Pilihan tidak dikenal.' 'Yellow'; Start-Sleep -Seconds 1 }
        }
    }
}

function Mulai-K8 {
    if (-not (Adalah-Admin)) {
        Info 'Menu ini perlu Administrator. Jawab Yes di jendela UAC; menu akan terbuka di jendela baru.' 'Yellow'
        try { Naik-Admin } catch { Info ('GAGAL meminta Administrator: ' + $_.Exception.Message) 'Red'; [void](Read-Host 'Tekan Enter untuk menutup') }
        return
    }
    Menu-Utama
}

if ($env:K8_TEST) { return }
Mulai-K8
