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

```sh
./polka desktop core --prebuilt
./polka desktop updates --prebuilt --release
./polka desktop files --prebuilt
./polka verify --prebuilt --external-drops
```

`desktop` принимает `all`, `core`, `updates` или `files`. Основные AppKit-сценарии и updater работают с отдельными временными профилями и синтетическими данными. Файловые сценарии отправляют настоящие CGEvent мыши и требуют уже выданного Accessibility; отсутствие разрешения — ошибка проверки, а не успешный пропуск. `verify --external-drops` явно включает эти локальные сценарии. Hosted CI не выдаёт такие разрешения и не запускает их. Для независимого внешнего AppKit drag-source используйте `./polka desktop files --prebuilt --external`.

GUI-драйверы используют общую блокировку из `tools/Sources/PolkaTools/Desktop.swift`. Запускайте их последовательно на свободном рабочем столе. Другая копия Полки или движения мышью могут забрать фокус; не вмешивайтесь в тест. Fixture не читает пользовательскую историю и Keychain, не использует пользовательский буфер или глобальные сочетания. После завершения драйвер ждёт выхода своих процессов и очищает временный профиль.

Для проверки извлечённого или другого bundle задайте `POLKA_NATIVE_APP=/absolute/Polka.app`. Отчёты, журналы и изображения сохраняются в `artifacts/desktop/native-smoke/`, `native-file-drop/` и каталоге updater. Смотрите первую причину отказа и сохранённый JSON; успешный повтор без исправления не подтверждает устранение проблемы.

CI запускает source checks, тесты инструментария и оптимизированную сборку на трёх независимых macOS runners. Source job выполняет `./polka verify --no-desktop --no-tools`, tooling job — `swift test --package-path tools`. Package job выполняет `./polka package --desktop`: один раз собирает оптимизированное приложение и bundle, затем одновременно создаёт и проверяет DMG и запускает desktop checks распакованного ZIP. Оба результата обязательны; ошибки дожидаются завершения уже запущенной работы перед cleanup. Независимые помощники компилируются параллельно в пределах числа CPU runner. После упаковки job проверяет настоящий updater с `--prebuilt --release`; desktop lock и диагностика обоих сценариев сохраняются. Общий обязательный check требует успеха всех трёх. Обычный локальный `verify` по-прежнему запускает оба набора тестов.

Цель обязательных build checks — пять минут исполнения CI; жёсткий лимит — десять минут. Три независимых macOS jobs выполняются параллельно, поэтому бюджет измеряется по самой долгой проверке от старта runner до завершения job, включая подготовку, caches, проверки, загрузку артефактов и cleanup. Очередь каждого runner исключена, в том числе при разном времени старта; очереди и общий интервал от первого старта до последнего завершения выводятся отдельно. Каждый macOS job имеет `timeout-minutes: 10`, а итоговый check дополнительно проверяет бюджет через `scripts/check-ci-budget.sh` и GitHub Jobs API именно текущей попытки запуска. Превышение пяти минут выводит warning, а превышение десяти минут блокирует зелёный check, даже если проверки успешны. Нельзя повышать жёсткий лимит без явного указания пользователя или убирать coverage, desktop и updater gates ради зелёного CI. Холодные сборки тоже должны укладываться в жёсткий лимит. В отчёте нужно различать достижение пятиминутной цели и прохождение десятиминутного лимита. Release workflow с подготовкой и публикацией выпуска имеет отдельные лимиты.

Общая action `.github/actions/prepare-macos` сохраняет SwiftPM intermediates приложения в независимых caches: профили source, optimized и optimized-native. Ключ включает major/minor-версию macOS, архитектуру, точные версии Xcode/Swift и build SDK, пути SDK и checkout, манифесты и версии зависимостей. Patch-версии host macOS могут использовать общий cache только при совпадении остальных параметров. `scripts/prepare-swift-cache.swift` сравнивает SHA-256 входных файлов и восстанавливает прежние timestamps только для одинакового содержимого; новые и изменённые файлы сохраняют timestamps текущего checkout. Это предотвращает ненужную перекомпиляцию после checkout. Golden probe в `verify` использует тот же coverage-профиль, что и XCTest; его результаты не добавляются в coverage, экспортированный до запуска probe.

Все три build jobs используют общий debug cache инструментария и `POLKA_TOOLS_CONFIGURATION=debug`: CLI собирается стандартным Swift Build engine, а конфигурация приложения по-прежнему определяется командой `build`. Локальный bootstrap и release workflow по умолчанию используют release CLI. Action задаёт `POLKA_SWIFT_BUILD_JOBS` по числу CPU runner; bootstrap, сборка, тесты и probe передают это число SwiftPM вместо стандартных десяти параллельных jobs. Число CPU и объём памяти выводятся в лог.

Оптимизированный build job использует отдельный профиль `optimized-native` и `POLKA_SWIFT_BUILD_SYSTEM=native`: сборка приложения и определение путей готовых продуктов выбирают один SwiftPM native engine. При первом переходе сохраняются скачанные зависимости, `workspace-state.json` с результатами resolution и manifest timestamps; удаляются только несовместимые build outputs. Это временный обход повторной компиляции зависимостей при восстановлении Swift Build caches на hosted runners; source checks и release workflow сохраняют стандартный engine и свои caches. Native engine пока доступен в Xcode 27, но помечен deprecated; после исправления Swift Build этот обход нужно удалить.

Команды сборки, все тесты и coverage gates выполняются при каждом запуске; `.app`, подписи, ZIP и DMG создаются заново. Release workflow использует те же caches и запускает четыре проверки параллельно после фиксации SHA. Подготовка выпуска восстанавливает только tooling cache и не разрешает зависимости приложения. Первый запуск после изменения toolchain или зависимостей остаётся холодным. [Пределы проверок](validation.md), [подпись и выпуск](macos.md).
