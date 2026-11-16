# Symphony of Nusantara — Sistem Asesmen Kokurikuler Kelas X

Aplikasi pendampingan formasi holistik siswa Kelas X (X-1 s/d X-6) SMA Pangudi Luhur Santo Yosef Surakarta untuk proyek kokurikuler **Symphony of Nusantara: Merajut Keberagaman Nusantara melalui Pertunjukan Seni**.

## Fitur utama

- Empat role: Admin/Koordinator, Guru Pendamping Divisi, Wali Kelas, dan Siswa.
- Penilaian formatif 6 tahap dan 15 indikator.
- Penilaian diri, refleksi siswa, apresiasi teman sedivisi, dan catatan wali kelas.
- Pengelolaan siswa, roster resmi, penugasan staf, konfigurasi divisi, laporan, dan ekspor Excel.
- Sinkronisasi data real-time melalui Supabase Realtime.

## Teknologi

- React 19, TypeScript, Vite, Tailwind CSS v4.
- Supabase Auth (Google OAuth), PostgreSQL, Row Level Security (RLS), dan Realtime.
- SheetJS (`xlsx`), Lucide React, Motion.

## Menjalankan secara lokal

1. Gunakan Node.js 20 atau lebih baru.
2. Install dependency:

   ```bash
   npm install
   ```
3. Salin `.env.example` menjadi `.env.local`, lalu isi URL dan publishable key dari Supabase Dashboard → Project Settings → API:

   ```env
   VITE_SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
   VITE_SUPABASE_ANON_KEY=YOUR_SUPABASE_PUBLISHABLE_KEY
   ```
4. Jalankan:

   ```bash
   npm run dev
   ```

   Buka `http://localhost:3000`.

Build dan pemeriksaan TypeScript:

```bash
npm run build
npm run lint
```

## Setup Supabase (penting)

1. Jalankan `supabase_schema.sql` di Supabase SQL Editor jika belum dilakukan.
2. Jalankan `supabase_migration_002_onboarding.sql` setelah skema dasar. Migrasi kedua menambahkan validasi role melalui RPC, self-claim siswa, dan kebijakan akses yang diperlukan aplikasi.
3. Di **Authentication → Providers → Google**, aktifkan Google dan masukkan OAuth Client ID/Secret dari Google Cloud.
4. Di **Authentication → URL Configuration**:
   - Set **Site URL** ke URL aplikasi yang dipakai.
   - Tambahkan URL callback/redirect aplikasi ke **Redirect URLs**. Untuk GitHub Pages, masukkan URL lengkap termasuk path repository, misalnya `https://USERNAME.github.io/NAMA-REPO/`.
   - Untuk lokal, tambahkan `http://localhost:3000/`.
5. Jangan pernah memasukkan `service_role` key atau secret key ke frontend. Gunakan publishable key; keamanan data dijalankan oleh RLS.

### Role dan keamanan

- Email bootstrap admin yang ditetapkan di `src/context/AuthContext.tsx` memperoleh role admin secara otomatis.
- Role admin lain harus diberikan melalui penugasan staf oleh admin yang sudah sah; role admin tidak dapat diperoleh hanya dengan kode undangan.
- Kode pendamping/wali kelas dibuat dan dikelola Admin, lalu diverifikasi di RPC `complete_user_onboarding` (bukan di browser). Jangan memakai kode contoh yang mudah ditebak.
- Jangan menonaktifkan RLS pada `profiles` atau `app_records`.

## Deploy ke GitHub Pages

1. Push source code ke branch `main` atau `master`.
2. Pada GitHub repository, buka **Settings → Secrets and variables → Actions → Variables**.
3. Tambahkan repository variables:
   - `VITE_SUPABASE_URL` = URL project Supabase.
   - `VITE_SUPABASE_ANON_KEY` = publishable key Supabase.
4. Buka **Settings → Pages → Build and deployment → Source**, pilih **GitHub Actions**.
5. Pastikan URL GitHub Pages yang aktif sudah ditambahkan ke Supabase **Authentication → URL Configuration → Redirect URLs**.

Workflow `.github/workflows/deploy.yml` akan menjalankan build Vite dan menerbitkan folder `dist/`.

## Catatan migrasi data

Migrasi source code ini tidak otomatis menyalin dokumen lama dari Firestore. Jika aplikasi Firebase sebelumnya sudah berisi data produksi, ekspor dan impor data Firestore ke tabel `public.app_records` perlu dilakukan sebelum aplikasi Supabase digunakan oleh seluruh pengguna. Jangan menghapus proyek Firebase sebelum data dan fitur Supabase diverifikasi.
