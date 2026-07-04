# MacMonitor Çalışma Günlüğü ve Kararlar

Bu dosya projede yapılan önemli işlemleri ve alınan kararları özetler. Yeni bir çalışmaya başlamadan önce bu dosyayı ve architecture.md dosyasını kontrol et, işlem sonrası güncelle.

## Sürüm 2.1 (Temmuz 2026): Güç metrikleri ve satır gizleme

- **SMC güç anahtarları eklendi:** sistem toplam gücü PSTR, CPU paket gücü PHPC, DC giriş gücü PDTR (bulunamazsa PD0R yedeği) anahtarlarından okunuyor. Sıcaklık anahtarları gibi aday listesinden açılışta bir kez probe ediliyor, sonuç powerKeyAvailable ile UserDefaults'a önbellekleniyor. M4 Mac mini üzerinde probe ile doğrulandı.
- **Widget güç satırı** eklendi: ana ızgaranın altına watt cinsinden anlık sistem gücü satırı geldi. Okunabilir anahtar yoksa (systemPowerW 0 veya altındaysa) satır tamamen gizleniyor, sahte değer gösterilmiyor.
- **Menüye Power satırı** eklendi: menü açıkken canlı güncelleniyor, okunabilir anahtar yoksa menü öğesi de gizleniyor.
- **Widget Rows alt menüsü** eklendi: Power, Network Speed ve IP Addresses satırları artık menüden birbirinden bağımsız açılıp kapanabiliyor (widgetRow_power/network/ip, hepsi varsayılan açık, UserDefaults.register ile kayıtlı, güncellemelerde de açık kalıyor).
- **Dinamik pencere yüksekliği artık formülle hesaplanıyor:** UILayout.mainHeight(hasBattery:showPower:showNetwork:showIP:) sabit ızgara yüksekliğine yalnızca o an görünen satırların (güç, ağ, IP, batarya) yüksekliklerini ekliyor. Bir satır gizlense veya batarya olmasa bile pencere her zaman doğru boyutta açılıyor, önceki sabit yükseklik varsayımı kalktı.
- **Thermals'a Güç bölümü** eklendi: sistem, CPU ve DC giriş güç değerleri (watt) ile HistoryStore.power'dan beslenen bir geçmiş grafiği (min/max) gösteriliyor.
- **RAM detayına swap ve bellek basıncı** eklendi: vm.swapusage ile kullanılan/toplam swap, kern.memorystatus_vm_pressure_level ile basınç seviyesi (Normal/Warning/Critical) gösteriliyor. Swap sysctl'i okunamazsa satır tamamen gizleniyor.
- **Disk detayına anlık okuma/yazma hızı** eklendi: IOBlockStorageDriver'ın Statistics sözlüğünden alınan bayt sayaçlarının tikler arası farkından hesaplanıyor. Önemli düzeltme: gerçek yazma anahtarı "Bytes (Write)"; planda "Bytes (Written)" olarak geçiyordu ama bu anahtar IOBlockStorageDriver Statistics sözlüğünde yok, gerçek anahtar probe ile doğrulanıp koda öyle yazıldı. İlk delta örneği alınana kadar satır gizli kalıyor.
- **Genel kural:** güç, swap ve disk I/O satırlarının hepsi veri kaynağı okunamadığında sıfır veya sahte değer göstermek yerine tamamen gizleniyor; bu, projenin dürüst arayüz ilkesiyle tutarlı.
- Sürüm kullanıcı tarafından canlı menü kontrolüyle doğrulandı (Widget Rows aç/kapa, canlı boyutlanma, konum sabit), /Applications'a kuruldu ve GitHub'a yayınlandı.

## Sürüm 2.0.1 Düzeltmeleri (Temmuz 2026, kullanıcı geri bildirimi)

- **Fan boost M4'te çalışmıyordu.** Kök neden: modern Apple Silicon'da (M4 dahil) "FS! " force-bits anahtarı yok; SMC probe ile doğrulandı (F0Md ui8 mevcut, FS! missing). FanHelper artık mimariden tahmin etmek yerine anahtar introspeksiyonu yapıyor: manuel mod F*Md üzerinden (yoksa FS! fallback), hedef RPM anahtarın bildirdiği kodlamayla (flt veya fpe2) yazılıyor. SMC yazmayı reddederse helper hata koduyla çıkıyor.
- **Boost dürüstlüğü:** boost süresince tepe RPM izleniyor; fanlar hızlanmadıysa buton "No effect" gösteriyor ve 15 dakikalık cooldown BAŞLAMIYOR. Etkisiz boost'un bıraktığı eski cooldown kaydı da temizlendi.
- **Dinamik yükseklik kayması:** pencere artık ekranın hangi kenarına yakınsa o kenar sabitlenerek büyüyor; detaydan dönüşte detaya girmeden önceki kare aynen geri yükleniyor (kullanıcı detaydayken pencereyi taşımadıysa); programatik boyutlandırmalar kayıtlı konumu artık ezmiyor. Eski hatanın UserDefaults'a yazdığı kaymış konum düzeltildi (windowX 16, windowY 1075).
- **Quick RAM temizliği kendi listesinin tepesine çıkıyordu:** basınç tahsisi malloc yerine mmap/munmap ile yapılıyor (sayfalar OS'e anında dönüyor) ve işlem sırasında süreç listesi yenilemesi duraklatılıyor.
- Test kancası eklendi: `-debugReturnAfter <saniye>` detaydan otomatik dönüş (konum doğrulaması için).
- **Boost yumuşatıldı ve hedef düşürüldü (kullanıcı isteği):** helper protokolü mutlak RPM yerine yüzdeye geçti (`boost <percent> <duration>`). Hedef her fanın kendi min-max bandının yüzdesi, mutlak maksimumun %90'ı sert tavan. Döngü: 6 sn'ye kadar smoothstep rampa yukarı, sabit tutma, 10 sn'ye kadar rampa aşağı, sonra otomatik moda devir. SIGINT/SIGTERM/SIGHUP yakalanıyor, süreç kesilirse fanlar manuel modda kalmıyor.
- **Grid sadeleşti, kadranlar büyüdü (kullanıcı isteği):** CPU ve RAM altındaki sparkline'lar kaldırıldı (Sparkline bileşeni silindi; HistoryStore duruyor, Thermals grafiği kullanıyor). Kadranlar 80'den 100 piksele çıktı, pencere boyutu değişmedi (içerik 336, pencere 340). Disk ve fan rozetleri kadran altından kadran içine, değerin altına minik caption olarak taşındı; iki satır tamamen simetrik. Merkez yazı sınırı 64 piksele çıktı, değer fontu 15, ikon 12.
- **Gauge'lar tik kadranı olarak yeniden tasarlandı (kullanıcı isteği):** kullanıcı halkaların eşitsiz göründüğünden şikayet etti. Kök neden görseldi: faz kaymalı nefes alan glow animasyonları, arc gölgesinin dolgun halkalarda daha büyük hale çizmesi ve hover'daki 1.06 büyüme. Yeni tasarım TickGauge: tek Canvas'ta çizilen 44 ayrık radyal tik, değere kadar yanıyor, uca doğru parlaklık rampası. Blur, gölge ve hover büyümesi tamamen kaldırıldı (hover sadece sönük tikleri aydınlatıyor), dört kadran yapısal olarak piksel özdeş. İşlevsel katman: uyarı eşiğinde tikler turuncu, kritik eşikte kırmızı (CPU/RAM 85/95, disk 90/97, sıcaklık 85/95). İkincil slotlar 76x14 sabit çerçeveye alındı, disk tarama öncesi boş alan gösteriyor, RPM yuvarlama düzeltildi (999 yerine 1000). RingGauge silindi, DetailHeader mini kadranı da TickGauge (28 tik).
- **Boost seviyesi %75'e çıkarıldı ve süre kullanıcıya bırakıldı (kullanıcı isteği):** Thermals'ta süre seçici (15/30/45/60/120 sn, UserDefaults boostDuration ile kalıcı). Kullanıcının fanında %75 bant = 3925 RPM. 15 dakikalık cooldown tamamen kaldırıldı: donanımsal bir gereklilik değildi, her boost'un yönetici şifresi istemesi doğal fren; fanlar sürekli yüksek devire dayanıklı tasarlanır.

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
