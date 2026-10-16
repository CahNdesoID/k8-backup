@echo off
title Kedaton 8 - Pasang UrBackup Client
rem Pakai:  k8.cmd <Divisi> <Nama>      contoh:  k8.cmd Housekeeping Rendi
rem Satu file: bagian PowerShell ada di bawah penanda. File ini HARUS tetap berakhir baris CRLF.
if "%~2"=="" goto pakai
set "D=%~1"
set "D=%D: =-%"
if /i "%~3"=="naik" goto lanjut
fltmc >nul 2>&1
if %errorlevel% neq 0 goto minta_admin
:lanjut
set "K8_SELF=%~f0"
set "K8_DIV=%D%"
set "K8_NAMA=%~2"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:K8_SELF);$i=$t.IndexOf('#K8PS'+'#');& ([scriptblock]::Create($t.Substring($i+6))) -Divisi $env:K8_DIV -Nama $env:K8_NAMA"
echo.
pause
exit /b
:minta_admin
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%D% %~2 naik' -Verb RunAs"
exit /b
:pakai
echo.
echo  Cara pakai:  k8.cmd ^<Divisi^> ^<Nama^>
echo  Contoh     :  k8.cmd Housekeeping Rendi
echo  Divisi dengan spasi:  k8.cmd "Senior Manager" Tiar
echo.
pause
exit /b
#K8PS#
<#
  Bagian PowerShell dari k8.cmd (dipanggil oleh k8.cmd, bukan dijalankan sendiri).
  - Memasang UrBackup Client (unduh dari urbackup.org, install diam-diam).
  - Membuka firewall HANYA untuk server backup (192.168.1.88).
  - Mengirim data PC ini ke server lewat LAN (server\terima-registrasi.ps1): nama PC, divisi,
    nama orang, IP, daftar drive (huruf=label=total GB=terpakai GB) dan nama folder tingkat atas C:\.
    Tidak ada isi file yang dibaca. Token GitHub TIDAK pernah dikirim ke server.
  Kalau server tidak menerima, data disimpan di %ProgramData%\Kedaton8Backup\registrasi.
#>
param(
    [string]$Divisi     = '',
    [string]$Nama       = '',
    [string]$ServerIP   = '192.168.1.88',
    [int]$PortTerima    = 8088,
    [string]$Versi      = '2.5.32',
    [string]$Url        = '',
    [string]$AkarC      = '',
    [switch]$Ya,
    [switch]$TanpaInstall
)
$ErrorActionPreference = 'Stop'
if (-not $Url) { $Url = 'https://hndl.urbackup.org/Client/' + $Versi + '/UrBackup%20Client%20' + $Versi + '.exe' }

function Info($t, $warna) { if ($warna) { Write-Host $t -ForegroundColor $warna } else { Write-Host $t } }

$DivisiValid = @('Housekeeping', 'IT', 'Marketing', 'Purchasing', 'Finance', 'HRD', 'HR', 'Corsec', 'Legal', 'Senior Manager', 'Audit', 'Accounting', 'Kasir')

# Folder tingkat atas C:\ yang dianggap SISTEM (tidak perlu dibackup). Selain ini = kemungkinan data pengguna.
$SistemC = '(?i)^(Windows|Windows\.old|Program Files|Program Files \(x86\)|ProgramData|Users|Recovery|PerfLogs|\$Recycle\.Bin|System Volume Information|Documents and Settings|MSOCache|Config\.Msi|\$WINDOWS\.~BT|\$WINDOWS\.~WS|\$WinREAgent|\$SysReset|Intel|AMD|NVIDIA|inetpub|OneDriveTemp|SWSetup|SWTOOLS|HP|Dell)$'
# Label drive yang mencurigakan sebagai partisi pemulihan/OEM.
$CurigaPulih = '(?i)recover|restore|winre|reserved|diag|factory|oem|hp_tools|lenovo_part'

function Format-Disk($huruf, $label, $total, $bebas) {
    $lab = ('' + $label) -replace '[,;"|=:\r\n]', '_'
    $tg = [math]::Round($total / 1GB)
    $pg = [math]::Round(($total - $bebas) / 1GB)
    return ($huruf + '=' + $lab + '=' + $tg + '=' + $pg)
}

function Pindai {
    $ips = @()
    try {
        foreach ($n in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($n.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($n.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            foreach ($a in $n.GetIPProperties().UnicastAddresses) {
                if ($a.Address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { continue }
                $s = $a.Address.ToString()
                if ($s.StartsWith('169.254.') -or $s.StartsWith('127.')) { continue }
                $ips += $s
            }
        }
    } catch { }
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
    return (New-Object PSObject -Property @{ IP = ($ips -join '|'); Disk = ($disk -join '|'); FolderC = ($extra -join '|') })
}

function Kirim-Server($p) {
    $pasang = @(
        @('komputer', ('' + $env:COMPUTERNAME)),
        @('divisi',   $Divisi),
        @('nama',     $Nama),
        @('ip',       $p.IP),
        @('disk',     $p.Disk),
        @('folderc',  $p.FolderC)
    )
    $bagian = @()
    foreach ($kv in $pasang) { $bagian += ($kv[0] + '=' + [Uri]::EscapeDataString('' + $kv[1])) }
    $badan = [Text.Encoding]::UTF8.GetBytes($bagian -join '&')
    $req = [Net.WebRequest]::Create('http://' + $ServerIP + ':' + $PortTerima + '/daftar')
    $req.Method = 'POST'
    $req.ContentType = 'application/x-www-form-urlencoded'
    $req.Timeout = 8000
    $req.ReadWriteTimeout = 8000
    $req.Proxy = $null
    $req.ContentLength = $badan.Length
    $st = $req.GetRequestStream()
    $st.Write($badan, 0, $badan.Length)
    $st.Close()
    $res = $req.GetResponse()
    $rd = New-Object IO.StreamReader($res.GetResponseStream())
    $txt = $rd.ReadToEnd()
    $rd.Close()
    $res.Close()
    return $txt
}

function Daftarkan {
    $pc = $env:COMPUTERNAME
    $label = $Divisi
    if ($label -eq '-') { $label = 'Mandiri' }
    $p = Pindai
    Info ('Terdaftar: PC ' + $pc + '  ->  ' + $label + ' \ ' + $Nama) 'Cyan'
    if ($p.IP) { Info ('IP PC ini: ' + ($p.IP -replace '\|', ', ')) 'Cyan' } else { Info 'IP PC ini tidak terbaca (catat manual dari ipconfig).' 'Yellow' }
    Info 'Drive di PC ini:' 'Cyan'
    foreach ($e in @(($p.Disk -split '\|') | Where-Object { $_ })) {
        $a = $e -split '='
        $t = '   ' + $a[0] + ':  ' + $a[1] + '  ' + $a[2] + ' GB, terpakai ' + $a[3] + ' GB'
        if ($a[1] -match $CurigaPulih) { Info ($t + '   <-- CURIGA partisi pemulihan, jangan dibackup') 'Yellow' } else { Info $t }
    }
    if ($p.FolderC) {
        Info ('Folder di C:\ yang BUKAN folder sistem baku: ' + ($p.FolderC -replace '\|', ', ')) 'Yellow'
        Info '   (tidak ikut backup default yang hanya mengambil C:\Users; tambahkan per PC kalau isinya data)' 'Yellow'
    }

    $terkirim = $false
    try {
        $balasan = Kirim-Server $p
        $terkirim = $true
        $warnaBalas = 'Green'
        if (('' + $balasan) -match 'DIGANTI') { $warnaBalas = 'Yellow' }
        Info ('Data PC ini sudah diterima server: ' + ('' + $balasan).Trim()) $warnaBalas
        if ($warnaBalas -eq 'Yellow') { Info 'PERHATIAN: orang ini sebelumnya terdaftar di PC lain. Kalau bukan penggantian PC, kamu salah ketik Divisi/Nama.' 'Yellow' }
    } catch {
        Info ('Data PC ini BELUM terkirim ke server (' + $_.Exception.Message + ').') 'Yellow'
    }
    if (-not $terkirim) {
        $berkas = (($label + '_' + $Nama) -replace '[^A-Za-z0-9_-]', '-') + '.csv'
        $isi = 'Komputer,Divisi,Nama,IP,Disk,FolderC' + "`r`n" + $pc + ',' + $Divisi + ',' + $Nama + ',' + $p.IP + ',' + $p.Disk + ',' + $p.FolderC + "`r`n"
        $tujuan = Join-Path $env:ProgramData 'Kedaton8Backup\registrasi'
        if (-not (Test-Path $tujuan)) { New-Item -ItemType Directory -Path $tujuan -Force | Out-Null }
        [IO.File]::WriteAllText((Join-Path $tujuan $berkas), $isi, (New-Object System.Text.UTF8Encoding($false)))
        Info ('Disimpan di PC ini: ' + (Join-Path $tujuan $berkas)) 'Yellow'
        Info 'Jalankan ulang perintah yang sama setelah penerima di server aktif, atau salin file itu ke server (folder registrasi).' 'Yellow'
    }
}

try {
    # 0. Rapikan dan periksa input
    $d = ('' + $Divisi).Trim()
    if ($d -ieq 'Mandiri' -or $d -eq '-') {
        $Divisi = '-'
    } else {
        $d = ($d -replace '-', ' ').Trim()
        $kanon = $null
        foreach ($v in $DivisiValid) { if ($v -ieq $d) { $kanon = $v } }
        if (-not $kanon) { throw ('Divisi "' + $Divisi + '" tidak dikenal. Pilihan: ' + ($DivisiValid -join ', ') + ', Mandiri') }
        $Divisi = $kanon
    }
    $n = ('' + $Nama).Trim()
    if ($n -notmatch '^[A-Za-z0-9]{1,40}$') { throw ('Nama "' + $Nama + '" tidak valid. Pakai huruf dan angka saja, tanpa spasi (contoh: Rendi).') }
    if ($n -notmatch '(?i)Backup$') { $n = $n + 'Backup' }
    $Nama = $n
    $labelDivisi = $Divisi
    if ($labelDivisi -eq '-') { $labelDivisi = 'Mandiri' }

    Write-Host ''
    Info ('  PC ini (' + $env:COMPUTERNAME + ') akan didaftarkan sebagai:')
    Info ('      ' + $labelDivisi + ' \ ' + $Nama) 'Cyan'
    Write-Host ''
    if (-not $Ya) {
        $j = Read-Host '  Lanjut? [Y = ya, T = batal]'
        if ($j -notmatch '(?i)^y') { Info 'Dibatalkan.' 'Yellow'; exit 0 }
    }

    if (-not $TanpaInstall) {
        $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $adm = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $adm) { Info 'GAGAL: jalankan sebagai Administrator (klik kanan > Run as administrator).' 'Red'; exit 1 }
    }

    # 1. Sudah terpasang?
    $svc = @()
    try { $svc = @(Get-Service | Where-Object { $_.Name -like '*urbackup*' -or $_.DisplayName -like '*urbackup*' }) } catch { }
    $sudah = ($svc.Count -gt 0)

    if ($sudah) {
        Info ('UrBackup Client sudah terpasang (' + $svc[0].DisplayName + ', status: ' + $svc[0].Status + '). Lewati unduh dan install.') 'Yellow'
    } else {
        # 2. Unduh
        $out = Join-Path $env:TEMP ('UrBackupClient-' + $Versi + '.exe')
        if (Test-Path $out) { Remove-Item $out -Force }
        Info ('Mengunduh: ' + $Url)
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }
        $wc = New-Object Net.WebClient
        $wc.DownloadFile($Url, $out)
        $kb = [math]::Round((Get-Item $out).Length / 1KB)
        if ($kb -lt 1024) { throw ('File terunduh terlalu kecil (' + $kb + ' KB), kemungkinan bukan installer. Cek koneksi internet / URL.') }
        Info ('Terunduh: ' + $kb + ' KB')

        # 3. Cek tanda tangan digital (info; hanya HashMismatch yang menghentikan)
        $sig = $null
        try { $sig = Get-AuthenticodeSignature $out } catch { }
        if ($sig) {
            Info ('Tanda tangan: ' + $sig.Status)
            if ($sig.Status -eq 'HashMismatch') { throw 'Tanda tangan rusak (HashMismatch). Install dibatalkan.' }
        }

        if ($TanpaInstall) { Daftarkan; Info 'SIMULASI: unduhan OK. Lewati install dan firewall.' 'Cyan'; exit 0 }

        # 4. Install diam-diam
        Info 'Memasang (silent)...'
        $p = Start-Process -FilePath $out -ArgumentList '/S' -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw ('Installer berhenti dengan kode ' + $p.ExitCode) }

        $ok = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 2
            $svc = @(Get-Service | Where-Object { $_.Name -like '*urbackup*' -or $_.DisplayName -like '*urbackup*' })
            if ($svc.Count -gt 0 -and $svc[0].Status -eq 'Running') { $ok = $true; break }
        }
        if (-not $ok) { Info 'PERINGATAN: service UrBackup belum terlihat berjalan. Cek di services.msc.' 'Yellow' }
        else { Info ('Service berjalan: ' + $svc[0].DisplayName) 'Green' }
    }

    if ($TanpaInstall) { Daftarkan; Info 'SIMULASI: lewati firewall.' 'Cyan'; exit 0 }

    # 5. Firewall: izinkan HANYA server backup masuk ke port client
    function Buka-Port($nama, $proto, $port) {
        & netsh advfirewall firewall delete rule name="$nama" | Out-Null
        & netsh advfirewall firewall add rule name="$nama" dir=in action=allow protocol=$proto localport=$port remoteip=$ServerIP profile=any | Out-Null
    }
    Buka-Port 'UrBackup Client TCP (dari server)' 'TCP' '35621,35623'
    Buka-Port 'UrBackup Client UDP (dari server)' 'UDP' '35622'
    Info ('Firewall: port 35621/35623 TCP dan 35622 UDP dibuka khusus dari ' + $ServerIP) 'Green'

    # 6. Catat PC ini milik siapa
    Daftarkan

    # 7. Info akhir
    $tc = New-Object Net.Sockets.TcpClient
    $ar = $tc.BeginConnect($ServerIP, 55414, $null, $null)
    $jangkau = $ar.AsyncWaitHandle.WaitOne(3000, $false) -and $tc.Connected
    $tc.Close()
    Write-Host ''
    Info '=== SELESAI ===' 'Green'
    Info ('Nama PC ini di UrBackup : ' + $env:COMPUTERNAME) 'Cyan'
    if ($jangkau) { Info ('Server ' + $ServerIP + ':55414 terjangkau dari PC ini.') } else { Info ('Server ' + $ServerIP + ':55414 TIDAK terjangkau dari PC ini (cek jaringan/VLAN).') 'Yellow' }
    Info ('Tunggu sekitar 1 menit, lalu cek halaman Status di http://' + $ServerIP + ':55414')
}
catch {
    Info ('GAGAL: ' + $_.Exception.Message) 'Red'
    exit 1
}
