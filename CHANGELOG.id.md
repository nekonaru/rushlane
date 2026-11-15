# Changelog

## v0.1.0

Rilis publik pertama. Rushlane mensimulasikan antrean kantin kampus dan merekomendasikan jumlah kasir terkecil yang memenuhi target layananmu.

## Fitur baru

- **Mesin kejadian diskrit.** Event loop min-heap tulis tangan dengan event kedatangan, mulai layanan, selesai, dan renege; tanpa library simulasi.
- **Kedatangan tidak seragam.** Proses Poisson non-homogen dengan laju per bin dan faktor skala hari ramai global.
- **Dua mode antrean.** Satu baris FIFO bersama atau satu baris per kasir dengan pemilihan baris terpendek.
- **Balking dan reneging.** Pelanggan tidak jadi mengantre di baris panjang dan keluar setelah kesabarannya habis.
- **Replikasi dengan interval kepercayaan.** Replikasi yang bisa diatur dengan CI 95% berbasis t dan common random numbers lintas skenario.
- **Validasi Erlang C.** Output simulasi cocok dengan teori M/M/c pada kondisi stasioner (dalam 3%).
- **Optimizer.** Mencari jumlah kasir terkecil yang memenuhi SLA dan membandingkan gaji kasir harian dengan perkiraan penjualan hilang.
- **Laporan satu perintah.** `julia --project=. scripts/rushlane.jl` menghasilkan laporan Markdown, grafik, dan ekspor CSV.
- **Shift kasir.** Jumlah kasir berbeda per jendela waktu, misal lebih banyak kasir saat makan siang.

## Peningkatan

- **Rentang dependensi terkunci.** Batas compat di `Project.toml` membuat instalasi reproducible di Julia 1.10 dan 1.x.
- **Validasi input.** Setiap nilai TOML diperiksa tipe dan rentangnya di boundary, dengan pesan error yang jelas.
