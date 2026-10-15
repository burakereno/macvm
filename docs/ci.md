# GitHub Actions tüketimi

Normal push ve pull request'ler Actions çalıştırmaz. `Release MacVM` yalnızca elle başlatılır; Windows yardımcılarını hazırlar, ardından tek macOS release derlemesi yapar. İmzalı doğrulama paketi için `publish=false`, yeni sürümü yayımlamak için `publish=true` seçilir.

`Build Windows guest helpers` yayın akışından çağrılır; yardımcıları ayrı hazırlamak gerektiğinde elle de başlatılabilir. Push tetikleyicisi kaldırıldı. Derleme tarifi, doğrulayıcı ve lisans değişmemişse başarılı çıktılar tam anahtar eşleşmesiyle önbellekten alınır; eşleşme yoksa kaynaklardan derlenir. Yardımcıların SHA-256, ARM64, lisans ve eşleşen kaynak doğrulamaları Mac paketlenirken her durumda çalışır. İki iş akışının eşzamanlılık grupları ayrıdır; elle başlatılan yardımcı derlemesi sürüm derlemesini iptal etmez.

CI üzerinde `swift test`, ikinci Windows test çağrısı ve test amaçlı ayrı Swift derlemeleri çalışmaz. Test kaynakları ve yerel komutlar korunur:

```sh
swift test
./scripts/verify-downloads.sh
./scripts/verify-update-installer.sh
```

Yayın paketlerinin exact Team ID, hardened runtime, strict codesign, notarizasyon, staple, Gatekeeper, Windows engine, Guest Tools ve güncelleme manifesti kontrolleri zorunlu kalır. İşler en fazla 45 dakika çalışır; geçici Actions çıktıları 7 gün tutulur. GitHub Release dosyaları bu saklama süresinden etkilenmez.

MacVM açık bir depodur; standart GitHub hosted runner kullanımı ücretsizdir. Gerçek süre kazanımı yeni yayın çalıştırılınca ölçülür; bu ayarlar değiştirilirken yeni bir yayın başlatılmaz.
