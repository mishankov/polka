# Разработка

Нужны Apple silicon, macOS 27+, полный Xcode 27 и Swift 6. Выберите установленный Xcode через `xcode-select`; при необходимости выполните `xcodebuild -runFirstLaunch`. Swift-зависимости закреплены в `native-app/Package.resolved`; инструментарий — отдельный пакет `tools/Package.swift`.

```sh
./polka setup
./polka dev
```

`./polka` собирает Swift CLI при первом вызове. `setup` разрешает зависимости обоих пакетов и собирает помощники. `dev` собирает `release/native-dev/Polka Native.app` и запускает его. Оптимизированный `build` использует отдельный каталог `release/native-build/`, поэтому упаковка не заменяет работающую development-сборку. Приложение и инструментарий написаны на Swift и используют системные утилиты macOS.

## Команды

| Команда | Действие |
| --- | --- |
| `./polka setup` | Зависимости Swift-пакетов и сборка помощников |
| `./polka dev` | Debug-сборка и запуск с постоянной development-подписью |
| `./polka build` | Оптимизированный Swift bundle и помощники |
| `./polka build --debug` | Debug-сборка |
| `./polka test` | XCTest приложения и Swift-инструментария |
| `./polka test tools` | XCTest Swift-инструментария |
| `./polka coverage` | LLVM-покрытие Swift и проверка порогов |
| `./polka search-test` | 2 164 эталонных случая поиска и вычислений |
| `./polka verify` | Форматирование, покрытие, тесты, эталоны, desktop и updater |
| `./polka verify --no-desktop` | Проверка без окон и настоящего updater |
| `./polka vm setup` | Однократная подготовка отдельной macOS VM для desktop-тестов |
| `./polka vm doctor` | Запуск VM, проверка macOS/Xcode и GUI-сессии, завершение VM |
| `./polka package` | Оптимизированный локальный `.app`, ZIP и DMG |
| `./polka release` | Официальный пакет и подписанный appcast |
| `./polka format --check` | Проверка форматирования Swift |

`./polka test app` запускает XCTest приложения, `./polka test tools` — XCTest инструментария; `all` выбран по умолчанию. Для передачи Swift-фильтров используйте `swift test --package-path native-app --filter ...`. `./polka coverage` измеряет покрытие Swift; сравнивайте долю покрытого кода по отчётам, а не число тестов.

`--prebuilt` у verify/package/desktop пропускает подготовку готовых Swift-продуктов; используйте его только после свежей сборки соответствующей конфигурации. `--release` выбирает оптимизированные продукты. `verify --no-updates` пропускает настоящий Sparkle smoke, сохраняя Swift-тесты обновлений. `package --desktop` проверяет приложение после извлечения ZIP; `--dir` создаёт только `.app`. Справка команд доступна через `--help`.

```sh
./polka build --release
./polka verify --prebuilt --release
./polka package --prebuilt --desktop
```

Ресурсы находятся в `native-app/Resources/`, иконка — в `build/Polka.icon/`, emoji JSON — в `native-app/Sources/PolkaCore/Resources/`. Помощники из `native/` собирает `BuildTool.buildHelpers` в `tools/Sources/PolkaTools/Build.swift`. Swift XCTest можно запустить напрямую: `swift test --package-path native-app`. Набор эталонных запросов содержит 2 164 случая в `tests/fixtures/search-cases.json.gz` и выполняется `./polka search-test`.

## Профиль и development-подпись

Профиль checkout: `~/Library/Application Support/polka-development/native-ИМЯ-CHECKOUT-ХЕШ`. Разные checkout имеют разные профили; один checkout сохраняет профиль между запусками. `POLKA_PROFILE=/absolute/path` выбирает явный каталог. Установленная программа использует `~/Library/Application Support/Polka/`. [Что хранится](data.md).

`dev` создаёт один сертификат **Polka Native Development Signing** в `~/Library/Application Support/polka-development/signing`. Каталог закрыт правами 0700, файлы — 0600. Сертификат используется через временный signing keychain, не импортируется в login Keychain и не меняет системное доверие. Повреждённый или неполный cache вызывает ошибку и не заменяется автоматически.

Помощник доступа к Keychain хранится в `~/Library/Application Support/polka-development/keychain-broker`. Его готовый подписанный бинарник повторно используется без изменения `cdhash` при обычной пересборке приложения. Он проверяет идентификатор и сертификат клиента и возвращает ключ через анонимный pipe. Первое обращение может потребовать «Разрешать всегда» и пароль связки «Вход». Изменение самого помощника или сертификата требует нового системного разрешения. Не удаляйте signing/broker cache между обычными запусками.

## Desktop-проверки

Локальные desktop-проверки по умолчанию выполняются в отдельной macOS VM через [Tart](https://tart.run/). Сочетания клавиш, мышь и окна остаются внутри гостевой системы: можно продолжать работать за компьютером. XCTest и source-проверки выполняются как раньше; CI запускает все обязательные desktop-сценарии непосредственно на своём runner.

Подготовьте VM один раз:

```sh
brew install openai/tools/tart
./polka vm setup
./polka vm doctor
```

Для установки Tart из официального архива задайте `POLKA_TART=/absolute/tart.app/Contents/MacOS/tart`; runner также находит установку в `~/Library/Application Support/polka-development/tart/tart.app`. `setup` загружает `ghcr.io/cirruslabs/macos-golden-gate-xcode:27`, создаёт `polka-desktop-tests`, выделяет 4 CPU и 12 ГБ RAM, задаёт экран 1920×1080 и проверяет macOS 27+, Xcode 27+ и активную GUI-сессию Tart Guest Agent. Первая загрузка образа большая; повторная установка не заменяет существующую VM. Для другого совместимого образа и отдельной VM используйте `POLKA_VM_IMAGE` и `POLKA_VM_NAME=polka-ДРУГОЕ-ИМЯ`.

```sh
./polka desktop core
./polka desktop updates --release
./polka desktop files
./polka verify --external-drops
```

Runner сначала компилирует CLI, приложение, native helpers, подготовку экрана и внешний drag-source на хосте. Обычный SwiftPM build проверяет актуальность исходников и повторно использует совместимые хостовые caches. Затем runner запускает VM без окна, audio/USB passthrough и общего clipboard, переносит read-only snapshot и готовые исполняемые файлы, запускает скомпилированный CLI напрямую и завершает VM при успехе, ошибке, таймауте или отмене. SwiftPM, swiftc и actool внутри guest не запускаются. Хостовые профили, `.env`, Git-конфигурация, signing credentials и build databases не передаются; гостевой системе доступны только подготовленные входы и отдельный каталог результатов. Общая блокировка сериализует проверки разных worktrees; уже работающая вне runner VM не перехватывается. Ошибка VM не переключает тесты на рабочий стол пользователя.

При загрузке VM runner повторяет readiness-проверки в течение трёх минут, включая временную недоступность Guest Agent. Зависимости разрешаются на хосте; гостевой системе не нужен сетевой доступ к SwiftPM или Apple Metal signing service. Это исключает минутное ожидание `xcrun --find metal` при первом запуске SwiftPM после загрузки guest. Настоящий updater по-прежнему работает внутри VM с локальным HTTP server: готовый bundle получает fixture metadata, подписывается одноразовым сертификатом гостевой системы, архивируется и проходит все проверки Sparkle. Хостовые signing keys в VM не передаются.

Перед проверками runner фиксирует экран гостевой системы 1920×1080 и отключает Dock, Notification Center и WindowManager в текущей гостевой GUI-сессии: их полноэкранные overlay-окна перекрывают безопасный путь настоящего drag-and-drop. При следующей загрузке macOS эти службы запускаются снова. Во время проверок `caffeinate` удерживает гостевой экран активным. Все изменения выполняются только после проверки VM и владельца гостевой console; рабочий стол хоста не затрагивается.

`desktop core/settings/files/all --prebuilt` переносит готовый bundle хоста, выбранный через `POLKA_NATIVE_APP` или обычный каталог сборки. Updater в `desktop all/updates --prebuilt` требует подготовленных Swift-продуктов **на хосте**; первый запуск выполняйте без `--prebuilt`. CLI и служебные тестовые executables всё равно компилируются на хосте из текущих исходников. `package --desktop` передаёт в VM именно извлечённый ZIP bundle, сохраняя проверку relocated-приложения. `verify` выполняет source-проверки и compilation на хосте, а desktop/updater — внутри VM.

Результаты гостевых проверок копируются в прежние `artifacts/desktop/native-*`; отдельный запуск сохраняет лог и статус в `artifacts/desktop/vm/UUID/`. `result.json` также содержит время подготовки на хосте, полный VM lifecycle и время выполнения гостевых сценариев. Журнал загрузки VM: `~/Library/Application Support/polka-development/desktop-vm/last-boot.log`. Если guest не готов, проверьте auto-login, Tart Guest Agent, версии macOS/Xcode и Accessibility внутри VM для настоящих CGEvent-проверок. Runner не запрашивает эти разрешения на хосте и не считает отсутствие доступа успешным пропуском.

`desktop` принимает `all`, `core`, `updates` или `files`. Основные AppKit-сценарии и updater работают с отдельными временными профилями и синтетическими данными. Файловые сценарии отправляют настоящие CGEvent мыши и требуют уже выданного Accessibility; отсутствие разрешения — ошибка проверки, а не успешный пропуск. `verify --external-drops` явно включает эти локальные сценарии. Hosted CI не выдаёт такие разрешения и не запускает их. Для независимого внешнего AppKit drag-source используйте `./polka desktop files --prebuilt --external`.

GUI-драйверы используют общую блокировку из `tools/Sources/PolkaTools/Desktop.swift` внутри VM. Для явной foreground-диагностики на свободном рабочем столе используйте `desktop/verify --host-desktop`; `POLKA_DESKTOP_BACKEND=host` задаёт тот же режим для прямых вызовов и `package --desktop`. В этом режиме другая копия Полки или движения мышью могут забрать фокус; не вмешивайтесь в тест. Fixture не читает пользовательскую историю и Keychain, не использует пользовательский буфер или глобальные сочетания. После завершения драйвер ждёт выхода своих процессов и очищает временный профиль.

Для проверки извлечённого или другого bundle задайте `POLKA_NATIVE_APP=/absolute/Polka.app`. Отчёты, журналы и изображения сохраняются в `artifacts/desktop/native-smoke/`, `native-file-drop/` и каталоге updater. Смотрите первую причину отказа и сохранённый JSON; успешный повтор без исправления не подтверждает устранение проблемы.

CI запускает source checks, тесты инструментария и оптимизированную сборку на трёх независимых macOS runners. Source job использует native engine SwiftPM с отдельным `source-native` cache и выполняет `./polka verify --no-desktop --no-tools`, tooling job — `swift test --package-path tools`. Package job выполняет `./polka package --desktop`: один раз собирает оптимизированное приложение и bundle, затем одновременно создаёт и проверяет DMG и запускает desktop checks распакованного ZIP. Оба результата обязательны; ошибки дожидаются завершения уже запущенной работы перед cleanup. Независимые помощники компилируются параллельно в пределах числа CPU runner. После упаковки job проверяет настоящий updater с `--prebuilt --release`; desktop lock и диагностика обоих сценариев сохраняются. Общий обязательный check требует успеха всех трёх. Обычный локальный `verify` по-прежнему запускает оба набора тестов.

Цель обязательных build checks — пять минут исполнения CI; жёсткий лимит — десять минут. Три независимых macOS jobs выполняются параллельно, поэтому бюджет измеряется по самой долгой проверке от старта runner до завершения job, включая подготовку, caches, проверки, загрузку артефактов и cleanup. Очередь каждого runner исключена, в том числе при разном времени старта; очереди и общий интервал от первого старта до последнего завершения выводятся отдельно. Каждый macOS job имеет `timeout-minutes: 10`, а итоговый check дополнительно проверяет бюджет через `scripts/check-ci-budget.sh` и GitHub Jobs API именно текущей попытки запуска. Превышение пяти минут выводит warning, а превышение десяти минут блокирует зелёный check, даже если проверки успешны. Нельзя повышать жёсткий лимит без явного указания пользователя или убирать coverage, desktop и updater gates ради зелёного CI. Холодные сборки тоже должны укладываться в жёсткий лимит. В отчёте нужно различать достижение пятиминутной цели и прохождение десятиминутного лимита. Release workflow с подготовкой и публикацией выпуска имеет отдельные лимиты.

Общая action `.github/actions/prepare-macos` сохраняет SwiftPM intermediates приложения в независимых caches: профили source, optimized и optimized-native. Ключ включает major/minor-версию macOS, архитектуру, точные версии Xcode/Swift и build SDK, пути SDK и checkout, манифесты и версии зависимостей. Patch-версии host macOS могут использовать общий cache только при совпадении остальных параметров. `scripts/prepare-swift-cache.swift` сравнивает SHA-256 входных файлов и восстанавливает прежние timestamps только для одинакового содержимого; новые и изменённые файлы сохраняют timestamps текущего checkout. Это предотвращает ненужную перекомпиляцию после checkout. Golden probe в `verify` использует тот же coverage-профиль, что и XCTest; его результаты не добавляются в coverage, экспортированный до запуска probe.

Все три build jobs используют общий debug cache инструментария и `POLKA_TOOLS_CONFIGURATION=debug`: CLI собирается стандартным Swift Build engine, а конфигурация приложения по-прежнему определяется командой `build`. Локальный bootstrap и release workflow по умолчанию используют release CLI. Action задаёт `POLKA_SWIFT_BUILD_JOBS` по числу CPU runner; bootstrap, сборка, тесты и probe передают это число SwiftPM вместо стандартных десяти параллельных jobs. Число CPU и объём памяти выводятся в лог.

Source job и оптимизированный build job используют отдельные профили `source-native` и `optimized-native` с `POLKA_SWIFT_BUILD_SYSTEM=native`: сборка приложения и определение путей готовых продуктов выбирают один SwiftPM native engine. При первом переходе сохраняются скачанные зависимости, `workspace-state.json` с результатами resolution и manifest timestamps; удаляются только несовместимые build outputs. Это временный обход повторной компиляции зависимостей при восстановлении Swift Build caches на hosted runners; source verification в release workflow использует тот же `source-native` cache, а официальная оптимизированная release-сборка сохраняет стандартный engine и свой cache. Native engine пока доступен в Xcode 27, но помечен deprecated; после исправления Swift Build этот обход нужно удалить.

Команды сборки, все тесты и coverage gates выполняются при каждом запуске; `.app`, подписи, ZIP и DMG создаются заново. Release workflow использует те же caches и запускает четыре проверки параллельно после фиксации SHA. Подготовка выпуска восстанавливает только tooling cache и не разрешает зависимости приложения. Первый запуск после изменения toolchain или зависимостей остаётся холодным. [Пределы проверок](validation.md), [подпись и выпуск](macos.md).
