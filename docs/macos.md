# macOS: сборка, подпись и выпуск

Полка работает на Apple silicon и macOS 27+. Разработка и упаковка требуют полного Xcode 27 и Swift 6. Установленному приложению Xcode не нужен. [Установка](installation.md), [разработка](development.md), [архитектура](architecture.md).

## Системное поведение

Полка — AppKit panel, настройки — отдельное окно, индикатор — окно без перехвата фокуса и кликов. На экранах без выреза цель находится в центре верхнего края. Global shortcuts используют Carbon, запуск при входе — ServiceManagement, системные диалоги — AppKit.

`clipboard-probe` читает стандартные macOS UTI и исключает confidential/transient/generated snapshots. Автовставка требует Accessibility и фиксирует поле до открытия полки. Перед отправкой клавиш помощник проверяет владельца и цель; при небезопасной цели запись только копируется. Приложение не выдаёт разрешение автоматически. «Разрешить…» открывает системный путь по явному действию пользователя.

`media-probe` наблюдает Core Audio и доступные состояния устройств, не записывая звук или видео. `file-shelf-probe` наблюдает drag pasteboard и геометрию цели, не читая обычный буфер. Vision выполняет локальный OCR через `image-text`. Проверки моделей и конкретного оборудования описаны в [validation.md](validation.md).

## Установка через Терминал

```sh
curl -fsSL https://raw.githubusercontent.com/mishankov/polka/master/scripts/install.sh | /bin/bash
```

Установщик использует Bash и системные утилиты macOS. Он разрешает latest в конкретный тег, скачивает ZIP и `checksums.txt` этого выпуска, проверяет SHA-256, пути архива, версию, bundle ID и code signature. Подготовка идёт рядом с `/Applications/Polka.app`; quarantine снимается только с устанавливаемой копии. При неудачной замене предыдущая копия восстанавливается. Перед ручной заменой завершите работающую Полку.

SHA-256 из того же выпуска проверяет целостность загрузки и не заменяет независимое доверие издателю или Apple notarization. Можно сначала прочитать скрипт и выбрать свой каталог:

```sh
curl -fsSL https://raw.githubusercontent.com/mishankov/polka/master/scripts/install.sh -o install-polka.sh
less install-polka.sh
/bin/bash install-polka.sh --install-dir "$HOME/Applications" --no-launch
```

## Локальная упаковка

```sh
./polka setup
./polka build --release
./polka package --prebuilt --desktop
```

`BuildTool` из `tools/Sources/PolkaTools/Build.swift` собирает Swift-программу и помощники из `native/`, компилирует иконку из `build/Polka.icon/`, копирует ресурсы, лицензии и Sparkle. Framework symlinks и rpath относительны; `.app` не зависит от checkout или Swift `.build` после упаковки.

Локальный Release bundle — `release/native-build/Polka Native.app`; ZIP и DMG находятся в `release/native-dev/`. `package` проверяет code seal, DMG и извлечённый в новый каталог ZIP. `--desktop` запускает изолированный native smoke из извлечённой копии. `--dir` создаёт только bundle, `--debug` выбирает Debug вместо оптимизированного Release. Локальная упаковка не подключена к официальному feed и использует ad-hoc подпись. Development-сертификат и стабильный Keychain broker для `dev` описаны в [development.md](development.md).

## Официальная подпись

Официальная программа имеет bundle ID `app.polka.desktop`. Выпуски используют один постоянный self-signed сертификат RSA 3072/SHA-256. Fingerprint SHA-1 служит идентификатором сертификата для `codesign`, не алгоритмом подписи. Подписывается вложенный код, затем bundle; identifiers помощников закреплены. Сборка проверяет сертификат, срок действия и соответствие designated requirements, а не переподписывает Sparkle через `--deep`.

Приватный сертификат импортируется только во временный signing keychain; login/default keychain и системное доверие не изменяются. Секреты исключаются из окружения дочерних сборок, keychain удаляется после работы. Не меняйте сертификат и identifiers между выпусками.

Self-signed подпись не создаёт доверия Gatekeeper; выпуски не проходят Apple notarization. Первый скачанный запуск может потребовать «Всё равно открыть» или один из способов [установки](installation.md). Accessibility относится к идентичности подписанного кода; его сохранение нужно отдельно проверять на установленной программе.

Keychain дополнительно учитывает `cdhash` исполняемого файла, поэтому новый build может повторно запросить доступ даже при постоянном сертификате. Перед обращением к ключу **polka Safe Storage** установленное приложение объясняет системный запрос и действия при отказе. При отказе зашифрованные файлы сохраняются. Development broker избегает изменения своего бинарника при обычной пересборке; это отдельная development-идентичность.

## Ключи выпуска

В GitHub environment **release** нужны:

| Имя                       | Тип      | Назначение                            |
| ------------------------- | -------- | ------------------------------------- |
| `POLKA_SIGNING_P12`       | Secret   | Base64 сертификата и приватного ключа |
| `POLKA_SIGNING_PASSWORD`  | Secret   | Пароль PKCS#12                        |
| `POLKA_SIGNING_CERT_SHA1` | Variable | Закреплённый fingerprint сертификата  |
| `SPARKLE_PUBLIC_KEY`      | Variable | Base64 публичного Ed25519-ключа       |
| `SPARKLE_PRIVATE_KEY`     | Secret   | Приватный Ed25519-ключ архивов        |

Один раз создайте сертификат и сохраните резервную копию в защищённом месте:

```sh
./polka signing-certificate /absolute/secure/signing-backup
```

Команда выводит дальнейшие инструкции; не сохраняйте приватные материалы в репозиторий. Рутинный выпуск не создаёт новый сертификат. Sparkle инструменты приходят из SwiftPM artifact:

```sh
swift package --package-path native-app resolve
native-app/.build/artifacts/sparkle/Sparkle/bin/generate_keys
native-app/.build/artifacts/sparkle/Sparkle/bin/generate_keys -x /absolute/secure/sparkle-private-key
```

Публичный ключ встраивается в Info.plist. Ed25519-подпись update ZIP проверяется до распаковки (`SUVerifyUpdateBeforeExtraction`) и дополнительно инструментарием выпуска. Это отдельная проверка от code signing.

## Полный поток выпуска

Добавьте `release-notes/VERSION.json` с непустыми `ru` и `en` до 20 000 символов каждый в выпускаемый commit. Примечания показываются как обычный текст; GitHub-описание дополняет их установкой на двух языках. [Правила текста](release-notes.md).

```sh
./polka release-notes vVERSION /tmp/polka-release-notes.md
```

Workflow `release.yml` запускается при опубликованном GitHub Release или вручную с `tag` и `prerelease`. Новый ручной выпуск разрешает default branch и создаёт draft и tag; существующий tag задаёт точный commit. Подготовка на macOS читает notes через `git show` из этого commit до создания draft/tag. Отсутствующие переводы или изменение тега прерывают выпуск. `--ref` выбирает workflow, а не исходный commit нового выпуска.

Подготовка выпуска использует только Swift-инструментарий и его cache, без загрузки зависимостей приложения. Затем четыре независимых macOS jobs получают один неизменный SHA: source verification выполняет Swift XCTest, проверку покрытия и golden; tooling job проверяет инструментарий; updater job проверяет настоящее обновление и перезапуск; защищённая среда release запускает `./polka release --desktop`. SwiftPM intermediates повторно используются из тех же caches, что и в обычном CI, с отдельными профилями source, tooling и optimized. Команда сборки запускается каждый раз, создаёт новые метаданные и подписанный `release/native/Polka.app`, ZIP, DMG и подписанный appcast, проверяет подписи и извлечённый bundle. Готовые официальные пакеты и signing keychain в cache не сохраняются. Локальный вызов без `--publish` ничего не загружает; `--publish` создаёт draft после проверок. CI публикует отдельно, только после успеха всех четырёх jobs и повторной проверки SHA тега.

Публикуются `polka-VERSION-arm64.dmg`, `polka-VERSION-arm64.zip`, `checksums.txt` и `appcast.xml`. Сначала загружаются архивы и checksums, затем feed, затем описание; ручной draft становится публичным последним. Published-архивы не заменяются. Версия bundle и имена артефактов берутся из tag, менять `polka.json` ради выпуска не нужно.

Feed: `https://github.com/mishankov/polka/releases/latest/download/appcast.xml`. Item содержит immutable URL ZIP по тегу, версию, минимальную macOS, длину и Ed25519 signature. Stable latest должен указывать на новейший стабильный выпуск; prerelease не заменяет stable feed. DMG предназначен для ручной установки, ZIP — для Sparkle.

## Обновление в приложении

`NativeUpdates.swift` использует Sparkle user driver с состояниями проверки, загрузки и готовности. Готовый пакет ждёт «Обновить и перезапустить»; обычный выход не устанавливает его. Перед установкой история сохраняется, ошибка flush оставляет пакет готовым и возвращает доступ к интерфейсу. Пропуск версии и напоминание на сутки сохраняются атомарно; ручная проверка позволяет увидеть пропущенную версию. «Что нового» открывает полные русские и английские notes в настройках.

```sh
./polka build --release
./polka desktop updates --prebuilt --release
```

Smoke выполняет настоящее native-to-native Sparkle обновление с временной подписью, синтетическим профилем и localhost feed. Проверяет повреждённый архив, ready hold, обычный выход, явную установку и relaunch. Системные Keychain/TCC разрешения этот fixture не подтверждает. [Пределы проверки](validation.md).
