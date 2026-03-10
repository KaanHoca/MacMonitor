# MacMonitor

macOS masaüstü widget'ı — CPU, Bellek, Disk ve Sıcaklık bilgilerini gerçek zamanlı gösterir.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-destekleniyor-green)

## Kurulum

**`Kur ve Çalıştır`** dosyasına çift tıkla. Hepsi bu.

> İlk çalıştırmada Xcode Command Line Tools kurulu değilse otomatik olarak kurulmasını isteyecektir. Kurulum bittikten sonra tekrar çift tıkla.

## Özellikler

- **2x2 yuvarlak gösterge** — CPU, Bellek, Disk, Isı
- **macOS native widget görünümü** — sistem widget'larıyla aynı materyal
- **Detay ekranları** — CPU veya Bellek göstergesine tıkla, proses listesini gör
- **Bellek temizleme** — Bellek detayında temizle butonu ile pasif önbelleği boşalt
- **CPU sıcaklığı** — SMC üzerinden gerçek sensör verisi
- **Masaüstü seviyesi** — uygulama pencerelerinin arkasında, masaüstünde kalır
- **Menü çubuğu ikonu** — widget'ı göster/kapat

## Kullanım

- Widget masaüstünde sol üstte görünür, sürükleyerek taşıyabilirsin
- **CPU** veya **Bellek** göstergesine tıkla → detaylı proses listesi
- Detayda **<** ile geri dön
- Bellek detayında **temizle butonuna** bas → pasif bellek önbelleğini temizler (şifre sorar)
- Menü çubuğundaki gauge ikonundan → **Widget'ı Göster** veya **Kapat**

## Login'de Otomatik Başlatma

1. `MacMonitor.app` dosyasını `/Applications` klasörüne kopyala
2. **System Settings > General > Login Items** → MacMonitor'ü ekle

## Kapatma

Menü çubuğu ikonu → **Kapat**
