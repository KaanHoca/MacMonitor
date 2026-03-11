# MacMonitor — Kurulum

## 1. Xcode Projesi Oluştur
1. Xcode aç → **File > New > Project**
2. **macOS > App** seç → Next
3. Product Name: `MacMonitor`
4. Interface: **SwiftUI**
5. Language: **Swift**
6. Kaydet

## 2. Dosyaları Ekle
1. `ContentView.swift` → mevcut olanı sil, bu dosyayı koy
2. `MacMonitorApp.swift` → mevcut olanı sil, bu dosyayı koy
3. `SystemMonitor.swift` → projeye yeni dosya olarak ekle
4. `Info.plist` → proje ayarlarında `LSUIElement` = YES olduğunu kontrol et (otomatik ekli)

## 3. Build Settings
- Target > General > **Deployment Target**: macOS 13.0+
- Signing & Capabilities: kendi Developer hesabın veya "Sign to Run Locally"

## 4. Çalıştır
Cmd+R ile build et ve çalıştır.
Panel sağ üst köşede görünür, sürükleyerek taşıyabilirsin.

## 5. Login'de Otomatik Başlat (opsiyonel)
System Settings > General > Login Items → uygulamayı ekle
