# MacMonitor Çalışma Günlüğü ve Kararlar

Bu dosya projede yapılan önemli işlemleri ve alınan kararları özetler. Yeni bir çalışmaya başlamadan önce bu dosyayı ve architecture.md dosyasını kontrol et, işlem sonrası güncelle.

## Sürüm 2.0 (Temmuz 2026)

### Düzeltilen Hatalar
- Fan boost, yönetici şifresi iptal edildiğinde bile "Boosting" gösterip 15 dakikalık cooldown başlatıyordu. Helper artık arka planda ayrık çalışıyor, osascript kimlik doğrulamadan hemen sonra dönüyor ve sayaçlar yalnızca doğrulama başarılıysa başlıyor.
- FanHelper yolu shell komutunda tırnaklanmıyordu (boşluklu yollarda kırılma ve yönetici yetkisinde güvenlik riski). Yol artık shell ve AppleScript katmanlarında ayrı ayrı kaçışlanıyor.
- "Install and Run.command" FanHelper'ı derlemiyordu; bu yolla kurulumda boost sessizce çalışmıyordu.
- CPU tick sayaçları UInt32 içinde toplanıyordu; uzun uptime'da taşma ve çökme riski vardı. UInt64 toplamlar ve sarmalama korumalı farklar kullanılıyor.
- Menü çubuğu istatistikleri menü açıkken hiç güncellenmiyordu (timer varsayılan run loop modunda, main queue dispatch menü takibinde bloke). Çözüm: tüm timer'lar .common modunda ve yayınlar publishOnMain ile RunLoop üzerinden.
- Sıcaklık anahtarları M1'e sabitti; Intel ve M2/M3/M4'te 0°C görünüyordu. Aday anahtar listesi açılışta bir kez taranıp geçerli olanlar önbellekleniyor. Sensör yoksa arayüz 0 yerine "--" gösteriyor.
- Disk temizlikte Reset butonları toggle'ları görsel olarak sıfırlamıyordu (satırlardaki yerel @State). Toggle'lar artık doğrudan DiskCleaner'a bağlı.
- RAM temizleme butonları ölçülen gerçek kazancı gösteriyor (örn. "1.2 GB"), koşulsuz başarı yok.
- SwiftUI Text içinde Int interpolasyonu Türkçe locale ile binlik ayracı basıyordu ("1.000 rpm"); sayılar String(format:) ile üretiliyor.

### Arayüz Yenilemesi
- Hero geçiş: tıklanan halka matchedGeometryEffect ile detay başlığına uçuyor ve orada canlı veri göstermeye devam ediyor (ring-cpu/ram/disk/temp id'leri).
- Dinamik pencere yüksekliği: ana ekran 340pt (bataryalı Mac'te 368pt), detaylar 440pt. Alt kenar sabit, ekran sınırına kelepçeli, animasyonlu.
- CPU ve RAM altında 5 dakikalık sparkline; disk altında tarama sonrası temizlenebilir boyut rozeti; sıcaklık altında fan RPM (fansız Mac'te sıcaklık sparkline'ı).
- Fan detayı "Thermals" oldu: sıcaklık geçmişi grafiği (min/max), fan kartları, RPM geçmişi, boost. Fansız Mac'lerde dürüst bir açıklama var.
- Components.swift eklendi: RingGauge, Sparkline, HistoryGraph, DetailHeader, HistoryStore, UILayout.
- HistoryStore ayrı ObservableObject: her tikteki geçmiş eklemeleri yalnızca grafikleri yeniden çiziyor, tüm grid'i değil.
- Erişilebilirlik: gauge'larda tooltip (.help), accessibilityLabel, Reduce Motion desteği.
- Süreç listeleri 10 kayıt gösteriyor (440pt yüksekliğe uygun).

### Yeni Özellikler
- Eşik bildirimleri (UserNotifications): CPU 100°C veya disk %90 dolu; koşul başına saatte en çok bir kez; menüden Alerts ile kapatılabilir (varsayılan açık).
- Keep Mac Awake: IOPM display sleep assertion; çıkışta bırakılıyor, yeniden başlatmada bilinçli olarak hatırlanmıyor.
- Batarya satırı (MacBook): şarj, şarj durumu, tasarım kapasitesine göre sağlık, döngü sayısı. Masaüstü Mac'lerde gizli.
- Menü çubuğu metin modu: ikon yerine "CPU% sıcaklık" canlı metni.
- Menüye GPU kullanımı (IOAccelerator), uptime ve load average eklendi; fansız Mac'te fan satırı gizleniyor.
- Çöp kutusuna taşıma: macOS kurulum dosyaları ve yarım indirmeler kalıcı silinmek yerine çöpe taşınıyor; tamamlanma ekranı geri alınabilir kısmı ayrıca raporluyor.

### Önemli Kararlar
- Bildirim eşiği bilinçli yüksek (100°C): Apple Silicon yük altında 90'ları normal görür, yanlış alarm istemiyoruz.
- Keep Awake kalıcı değil: kullanıcının haberi olmadan Mac'i sürekli uyanık tutmak güvenli değil.
- WidgetKit widget'ı yapılmadı: Xcode projesi ve extension gerektirir, swiftc akışını bozar.
- Wi-Fi SSID eklenmedi: modern macOS'ta konum izni gerektiriyor, imzasız uygulamada gereksiz sürtünme.
- Süreç sonlandırma butonu eklenmedi: kazara kritik süreç öldürme riski, güvenlik-öncelikli yaklaşıma aykırı.
- Cache kategorileri çöp kutusuna taşınmıyor (çöpü şişirir); yalnızca kullanıcı içeriği sayılabilecek kategoriler taşınıyor.

### Doğrulama Yöntemi
- Her aşama ./build.sh ile derlendi; arayüz, pencere ID'si üzerinden screencapture ile görsel olarak doğrulandı.
- Dev kancası: `open MacMonitor.app --args -debugDetail cpu|ram|disk|fan` doğrudan detay ekranı açar.

## Sürüm 1.x Mirası
- 19 kategorili disk temizleme, tema sistemi (6 tema), süreç listeleri, ağ istatistikleri, IP kopyalama, menü çubuğu istatistikleri, Launch at Login, RAM temizleme (Quick/Purge), fan izleme ve boost.
- Ayrıntılar için architecture.md ve README.md dosyalarına bak.
