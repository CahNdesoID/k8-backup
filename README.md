# k8-backup

Pasang, daftarkan, dan rawat **UrBackup Client** di PC Kedaton 8 Hotel lewat satu baris perintah per PC,
tanpa flashdisk dan tanpa token. Cocok untuk Windows 8.1, 10, dan 11.

```
k8.cmd                       pembuka menu (klik dua kali) - isinya satu baris yang sama dengan di bawah
k8.ps1                       menu di PC: pasang/daftar, sinkron IP, muat ulang koneksi, cek status
server/k8-server.ps1         penerima di server (192.168.1.88): daftar PC + sinkron IP, dijaga password
server/jalankan-server.cmd   pembuka penerima (minta Administrator, buka firewall sementara)
```

## Satu baris untuk tiap PC

Tempel di **cmd atau PowerShell** (keduanya bisa), lalu jawab **Yes** di jendela UAC:

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=3072; irm https://raw.githubusercontent.com/CahNdesoID/k8-backup/main/k8.ps1 | iex"
```

Menu yang muncul:

| Menu | Fungsi |
|---|---|
| 1 Pasang / daftar | Unduh dan pasang UrBackup Client, buka firewall khusus server backup, kirim data PC ke server |
| 2 Sinkron IP | PC berganti IP: kirim IP terbaru, server memperbarui catatan dan alamat di UrBackup |
| 3 Muat ulang koneksi | PC pernah tersambung ke server lain/percobaan: lupakan server lama, siap dipercaya server kantor |
| 4 Cek status | Layanan, firewall, jangkauan server, identitas yang tersimpan |
| 5 Ganti nama / divisi | Salah ketik nama, atau PC ini dipakai orang lain: kirim identitas baru, server mengarsipkan entri lama |

Password pemasangan ditanya saat menu 1, 2, atau 5 dipakai (tersembunyi, tidak disimpan). Minta ke IT.

Setelah UAC dijawab Yes, jendela baru menampilkan "Mengambil menu Kedaton 8 ..." beberapa detik lalu menunya muncul.
Kalau gagal mengambil, pesan galat ditahan di layar sampai Enter ditekan.

**Installer UrBackup Client (menu 1)** diambil dengan urutan: (1) dari **server kantor lewat LAN** kalau server
menyimpan installer (cepat, tidak membebani internet), (2) dari internet (hndl.urbackup.org), (3) file yang kamu
unduh sendiri lewat browser (menu meminta lokasinya). Unduhan menampilkan progres (MB, persen, kecepatan), berhenti
kalau 20 detik tanpa data, mencoba tiga kali dan melanjutkan dari bagian yang sudah terunduh.
Dari server, installer hanya dipakai kalau SHA256-nya sama dengan hash resmi UrBackup Client 2.5.32 (tercatat di
`k8.ps1`, sama dengan manifest winget) dan ukuran serta SHA256 file yang diterima cocok; kalau tidak, PC beralih ke
internet. Untuk memakai file lokal sejak awal (melewati server), jalankan ini di PowerShell sebelum satu baris di atas:

```
$env:K8_INSTALLER = ([Uri]"C:\Users\Nama\Downloads\UrBackup Client 2.5.32.exe").AbsoluteUri
```

Kalau GitHub tidak terjangkau dari PC itu, ambil dari server (penerima harus sedang aktif):

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm http://192.168.1.88:8088/k8.ps1 | iex"
```

## Di server (192.168.1.88)

1. Salin folder ini ke server (RDP, copy-paste folder), mis. `E:\Divisi\_setup\k8-backup\`.
   `k8.ps1` harus tetap berada satu tingkat di atas folder `server` (untuk jalur cadangan LAN).
2. Klik dua kali `server\jalankan-server.cmd` (atau `powershell -ExecutionPolicy Bypass -File server\k8-server.ps1 -BukaFirewall`).
   Bawaan menerima dari `192.168.1.*` dan `192.168.6.*`; ubah dengan `-Izinkan` dan `-AlamatFirewall`.
3. Ketik password pemasangan dua kali. Pakai yang panjang (10 karakter atau lebih), huruf/angka/simbol ASCII tanpa spasi.
4. Biarkan jendelanya terbuka. Berhenti sendiri setelah 240 menit (`-MenitMaks`, `0` = tanpa batas) atau Ctrl+C.
   Aturan firewall yang dibuat ikut dihapus saat berhenti.

**Installer di server (sekali saja).** Taruh installer resmi di folder `installer` di samping folder `server`
(mis. `C:\k8-backup\installer\UrBackupClient.exe`; nama lain yang diawali `UrBackup` juga dikenali). Penerima
menampilkan ukuran, SHA256, dan apakah cocok dengan hash resmi. File boleh ditaruh atau diganti saat penerima berjalan.
Unduh di server (BITS bisa dilanjutkan kalau putus):

```
New-Item -ItemType Directory -Force C:\k8-backup\installer | Out-Null
Start-BitsTransfer -Source "https://hndl.urbackup.org/Client/2.5.32/UrBackup%20Client%202.5.32.exe" -Destination C:\k8-backup\installer\UrBackupClient.exe
```

Kalau unduhan di atas sangat lambat (host urbackup.org kadang membatasi kecepatan **per koneksi**), pakai
`server\ambil-installer.ps1`: file diambil dengan beberapa koneksi sekaligus (bawaan 8), bisa dilanjutkan kalau
putus (jalankan lagi perintah yang sama), lalu SHA256-nya dibandingkan dengan hash resmi. Hanya kalau cocok, file
disimpan sebagai `installer\UrBackupClient.exe`; kalau beda, disimpan sebagai `.tidak-cocok` dan tidak dipakai.

```
powershell -ExecutionPolicy Bypass -File C:\k8-backup\server\ambil-installer.ps1
powershell -ExecutionPolicy Bypass -File C:\k8-backup\server\ambil-installer.ps1 -Bagian 4      # kalau host menolak banyak koneksi
powershell -ExecutionPolicy Bypass -File C:\k8-backup\server\ambil-installer.ps1 -PakaiProxy    # kalau internet server lewat proxy
```

Hingga 6 PC bisa mengambil installer bersamaan tanpa menahan pendaftaran PC lain; yang ke-7 mendapat "sibuk" lalu
otomatis memakai internet. Folder `installer` tidak masuk repo (`.gitignore`).

Hasilnya: `E:\Divisi\_setup\registrasi\<Divisi>_<Nama>.csv` (ubah dengan `-Tujuan`), dibaca oleh
`siapkan-divisi.ps1` dan `cek-koneksi.ps1`.

Penerima ini **hanya perlu menyala** saat memasang PC dan saat ada PC yang berganti IP. Password tidak disimpan
di disk, jadi dimasukkan lagi tiap dijalankan.

## Kasus yang sering

**PC/laptop pernah tersambung ke UrBackup saat uji coba.** Menu 3. Layanan UrBackup dihentikan sebentar, tiga file
kepercayaan server (`server_idents.txt`, `session_idents.txt`, `new_server_idents.txt`) diganti nama menjadi
`.bak-<waktu>` (tidak dihapus), layanan dijalankan lagi, lalu menunggu server kantor menghubungi dan dipercaya.
Client UrBackup hanya mempercayai server pertama yang menghubunginya, jadi setelah reset ia menerima server kantor.
Untuk mengembalikan, hentikan layanan dan ganti nama file `.bak-...` kembali.

**IP PC berubah.** Menu 2. Server memperbarui CSV. Kalau PC itu **sudah** ditambahkan di UrBackup lewat alamat IP,
alamat lama diganti alamat baru (alamat yang dipakai adalah alamat sumber permintaan, bukan yang diklaim PC).
PC yang belum ada di UrBackup **tidak pernah ditambahkan otomatis**. Alamat lama yang tercatat milik PC lain
dipertahankan. Kalau PC ditambahkan lewat nama, tidak ada yang perlu diubah.
Solusi akar: pasang **DHCP reservation** di router untuk tiap PC, supaya IP tidak berubah lagi.

**Ganti PC untuk orang yang sama.** Menu 1 di PC baru dengan Divisi/Nama yang sama. Server menandai `DIGANTI`.

**Salah ketik nama / PC ganti orang.** Menu 5 (atau `G` di menu 1). Isi identitas yang benar; PC mengirim identitas baru
dan identitas lama. Server menulis CSV baru lalu **memindahkan** CSV lama ke `<Tujuan>\_diganti\` (tidak dihapus), hanya
kalau CSV lama itu memang milik PC yang sama. Nama baru yang sudah dipakai PC lain **ditolak** (tidak ditimpa).
Data backup tidak berpindah (folder di UrBackup memakai nama PC). Setelah itu jalankan `siapkan-divisi.ps1` di server supaya
folder nama baru tersambung. Kalau tautan nama lama sempat dibuat, lepas dengan `rmdir` (jangan `Remove-Item -Recurse`).
Penerima versi lama mengabaikan identitas lama: entri lama harus dipindahkan manual (PC menampilkan peringatan).

## Keamanan

- Repo ini **public** agar linknya tanpa token. Isinya hanya skrip: tidak ada password/token. Yang terlihat publik:
  IP LAN server (`192.168.1.88`) dan nama divisi.
- Password tidak pernah dikirim lewat jaringan. PC mengambil kode sekali pakai dari server (`/nonce`, 60 detik) lalu
  mengirim HMAC-SHA256 dari `jalur + isi permintaan`. Sadapan tidak bisa dipakai ulang, isi tidak bisa diubah.
- 5 kali salah dari satu alamat dalam 10 menit = alamat itu dikunci 10 menit.
- Server hanya menerima dari `192.168.1.*` dan `192.168.6.*` (`-Izinkan`), badan maks 8 KB, semua isian divalidasi
  (divisi dari daftar baku, nama huruf/angka, IP IPv4 yang sah). Nama file CSV dibentuk dari nilai yang sudah lolos.
- Data yang dikirim: nama PC, divisi, nama orang, IP, label dan ukuran drive, nama folder tingkat atas `C:\`.
  Isi file tidak dibaca. IP hotspot Windows (`192.168.137.*`) dan adaptor virtual (VMware, VirtualBox, Hyper-V,
  Bluetooth, dll.) tidak ikut dilaporkan.
- `/installer` dan `/installer-info` tidak memakai password (isinya perangkat lunak publik) tetapi tunduk pada daftar
  alamat yang diizinkan. Karena HTTP biasa, PC tidak percaya begitu saja: installer dari server dipakai hanya bila
  SHA256-nya sama dengan hash resmi yang ada di `k8.ps1` (diambil lewat HTTPS dari GitHub). Penyerang di LAN yang
  menyamar sebagai server tidak bisa menyuntikkan installer lain. Hash resmi harus diganti bersamaan dengan versi
  UrBackup Client (`$UbVersi`, `$UbSha256` di `k8.ps1`).
- Firewall PC dibuka hanya untuk `192.168.1.88` (TCP 35621, 35623; UDP 35622).
- **Siapa pun yang bisa push ke repo ini bisa menjalankan kode di PC kantor.** Aktifkan 2FA di akun GitHub pemilik repo,
  dan jangan beri akses tulis ke orang lain.
- Jangan commit `*.csv`, `registrasi/`, cadangan pengaturan, atau apa pun berisi password (lihat `.gitignore`).

## Kompatibilitas dan batas pengujian

- Windows 8.1 (PowerShell 4.0, .NET 4.5.1), Windows 10 dan 11 (PowerShell 5.1). Tanpa `curl`, tanpa fitur PowerShell 5+.
  TLS 1.2 dipaksa untuk unduhan HTTPS.
- Server: Windows Server 2016 (PowerShell 5.1), memakai `HttpListener`.
- Diuji pada PowerShell 7 (Linux) dengan server UrBackup tiruan: validasi input, password benar/salah/replay/kunci,
  sinkron IP ke API UrBackup (tambah/hapus alamat, sesi habis, UrBackup mati), reset koneksi, menu terprogram,
  jalur `irm | iex`, unduhan (putus di tengah, macet, server tanpa Range, 404, halaman HTML, file lokal), penyajian
  installer oleh server (Range, 403/404, pengiriman paralel) dan pengambilan installer dari server oleh PC (hash
  salah, isi terpotong, putus lalu lanjut, server mati).
  **Belum diuji** di Windows sungguhan: tampilan menu, UAC, `netsh`, layanan UrBackup asli, lokasi
  file kepercayaan di `Program Files\UrBackup`, Windows 8.1, antivirus. Coba dulu di satu PC sebelum rollout.

## Mengubah skrip

Berkas `.ps1` dan `.cmd` harus tetap berakhir baris **CRLF** dan hanya berisi karakter ASCII
(`.gitattributes` mengunci ini). Periksa sebelum push: `git ls-files --eol` harus menampilkan `i/crlf` untuk
`k8.cmd`, `k8.ps1`, dan semua berkas di `server/`. Setelah push ke `main`, perubahan langsung dipakai PC
(cache GitHub sekitar 5 menit). Untuk membekukan versi, ganti `main` di link dengan nama tag, mis. `v3`.
