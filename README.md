# k8-backup

Pemasangan UrBackup Client di PC Kedaton 8 Hotel dengan **satu baris perintah per PC**, tanpa flashdisk.
Repo ini **private**. Isinya hanya skrip; tidak ada password atau token di dalamnya.

```
k8.cmd                        satu file: minta Administrator, pasang UrBackup Client, buka firewall
                              khusus server backup, kirim data PC ke server lewat LAN
server/terima-registrasi.ps1  penerima di server (192.168.1.88), dijalankan selama rollout saja
```

## 1. Sekali saja: token baca-saja untuk PC

Dibuat sendiri lewat web GitHub (bukan lewat CLI, dan jangan ditempel ke chat):

1. GitHub -> Settings -> Developer settings -> Personal access tokens -> **Fine-grained tokens** -> Generate new token
2. Repository access: **Only select repositories** -> pilih repo ini saja
3. Permissions -> Repository permissions -> **Contents: Read-only** (Metadata read otomatis ikut)
4. Expiration: **14 hari** (cukup untuk rollout)
5. Setelah semua PC selesai: **Revoke** token itu.

Token ini hanya bisa membaca repo ini. Tetap perlakukan seperti password: jangan dicetak, jangan difoto, jangan disimpan di PC.

## 2. Di server (sebelum PC pertama)

PowerShell sebagai Administrator, di folder tempat file ini berada:

```powershell
powershell -ExecutionPolicy Bypass -File .\server\terima-registrasi.ps1 -BukaFirewall
```

- Mendengarkan TCP 8088, hanya dari `192.168.6.*`. Aturan firewall dibuat dan dihapus otomatis.
- Menulis `E:\Repo\Divisi\_setup\registrasi\<Divisi>_<Nama>.csv` (ganti dengan `-Tujuan` kalau folder divisi pindah).
- Berhenti sendiri setelah 240 menit (`-MenitMaks`) atau dengan Ctrl+C.
- Biarkan jendelanya terbuka selama PC dipasang.

## 3. Di tiap PC (cmd biasa, bukan PowerShell)

Ganti `TOKEN`, `USER`, `REPO`, lalu Divisi dan Nama:

```
curl -fsSL -H "Authorization: Bearer TOKEN" -H "Accept: application/vnd.github.raw+json" "https://api.github.com/repos/USER/REPO/contents/k8.cmd" -o "%TEMP%\k8.cmd" && "%TEMP%\k8.cmd" Housekeeping Rendi
```

- Jawab **Yes** di jendela UAC. Cek nama di layar, tekan **Y**. Selesai kalau muncul `=== SELESAI ===`.
- `Rendi` otomatis menjadi `RendiBackup` (akhiran Backup ditambahkan kalau belum ada).
- Divisi: Housekeeping, IT, Marketing, Purchasing, Finance, HRD, HR, Corsec, Legal, Senior Manager, Audit, Accounting, Kasir, atau `Mandiri`.
  Divisi dengan spasi: `"Senior Manager"` atau `Senior-Manager`.
- `-f` membuat curl gagal kalau token salah, dan `&&` mencegah file error dijalankan.
- `curl.exe` ada di Windows 10 1803 ke atas. Cadangan untuk PC yang tidak punya curl (belum diuji):

```
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Headers @{Authorization='Bearer TOKEN';Accept='application/vnd.github.raw+json'} -Uri 'https://api.github.com/repos/USER/REPO/contents/k8.cmd' -OutFile \"$env:TEMP\k8.cmd\"" && "%TEMP%\k8.cmd" Housekeeping Rendi
```

Pasang versi tertentu (tidak ikut berubah kalau repo diedit): tambahkan `?ref=v1` setelah `k8.cmd` di URL.

## 4. Setelah PC terpasang

Di server: jalankan `siapkan-divisi.ps1` (membaca folder registrasi), lalu tambahkan PC ke UrBackup lewat IP
(hari **Minggu**, supaya backup pertamanya, yang otomatis full, tidak jatuh di jam kerja).

## Catatan keamanan

- Server hanya menerima: nama PC, divisi, nama orang, IP, label dan ukuran drive, nama folder tingkat atas `C:\`.
  Isi file tidak dibaca. Token tidak pernah dikirim ke server.
- Penerima memakai HTTP biasa di LAN dan menolak alamat di luar `192.168.6.*`. Jangan dibuka ke internet.
- Firewall PC dibuka hanya untuk `192.168.1.88` (TCP 35621, 35623, UDP 35622).
- Jangan commit file registrasi (`*.csv`), cadangan pengaturan, atau apa pun berisi password. Lihat `.gitignore`.

## Mengubah k8.cmd

Bagian PowerShell ada di bawah baris `#K8PS#` di dalam `k8.cmd`. File harus tetap berakhir baris **CRLF**
(`.gitattributes` sudah mengunci ini). Periksa sebelum push: `git ls-files --eol k8.cmd` harus menampilkan `i/crlf`.
