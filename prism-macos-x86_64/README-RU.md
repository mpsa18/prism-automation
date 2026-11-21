# Prism 0.1.1 — как начать

Это готовый комплект. Устанавливать ничего не нужно: все программы уже
собраны и лежат рядом. Внутри три точки входа — от самой простой к самой
сложной.

## Что где лежит

```text
prism-macos-x86_64/
├── README-RU.md — эта инструкция (русский)
├── README-EN.md — эта инструкция (английский)
├── LICENSE — лицензия Prism (Community edition)
├── THIRD_PARTY_NOTICES.md — лицензии сторонних библиотек
├── SHA256SUMS — контрольные суммы всех файлов
├── docs/ — главы документации (на английском)
├── examples/tour/ — готовый пример, работает без железа
└── prism/ — рабочая папка платформы (инстанс)
    ├── prism — главная программа
    ├── config/ — настройки: устройства, теги, MQTT, OPC UA
    ├── scripts/ — скрипты Rhai
    └── devtools/ — сканер, сниффер, конфигуратор, симулятор, дебаггер
```

`prism/` — это инстанс. Его можно переименовать или скопировать целиком;
все пути в конфигурации считаются от этой папки.

Целостность архива проверяется по `SHA256SUMS`: на Linux/macOS —
`sha256sum -c SHA256SUMS` (на macOS `shasum -a 256 -c SHA256SUMS`), в Git Bash
на Windows — той же `sha256sum -c SHA256SUMS`.

## 1. Инструменты для анализа сетей и адресов

Самый простой вход. Настраивать проект не нужно, оборудование опрашивается
только на чтение.

### Сканер адресов — `prism-scan`

`prism-scan` (лежит в `prism/devtools/scanner/`) проходит по адресам и портам,
показывает, какие устройства отвечают, какие регистры читаются и какие типы
данных там лежат. По результату он может собрать заготовку конфигурации Prism.

```text
cd prism
./devtools/scanner/prism-scan --init      # создать scan.toml рядом с программой
./devtools/scanner/prism-scan             # выполнить план сканирования
```

`scan.toml` — обычный текстовый файл: диапазоны адресов, порты, unit id и что
именно читать. Все поля описаны комментариями.

### Сниффер — `prism-sniff`

`prism-sniff` (лежит в `prism/devtools/sniffer/`) пассивно слушает шину или
порт и показывает кадры Modbus, S7comm, OPC UA и MQTT. Он ничего не пишет в
оборудование; умеет писать лог и ставить маркеры.

```text
cd prism
./devtools/sniffer/prism-sniff --init     # создать sniff.toml
./devtools/sniffer/prism-sniff            # запустить сниффер
```

Подробно: `docs/03_tooling/01_BENCH_TOOLS.md`, `docs/03_tooling/04_SCANNER.md` и
`docs/03_tooling/05_SNIFFER.md`. Конфигуратор: `docs/03_tooling/06_DEVTOOLS.md`.

## 2. Конфигуратор оборудования — `prism-devtools`

`prism-devtools` (лежит в `prism/devtools/tooling/`) — конфигуратор
оборудования. Он убирает ручную копипасту:

- `init` — создать проект целиком (`empty`, `minimal`, `standard`, `full`);
- `scaffold` — добавить одно устройство, тег, виртуальный тег, аларм,
  историю, скрипт или poll;
- `generate tags` — сгенерировать пачку тегов по шаблону: адреса, типы,
  масштабы, режимы `full`/`delta`/`annotated`, черновик `--draft`;
- `generate mqtt` — собрать `tags.toml`, каналы и шаблоны payload'ов;
- `generate opc-server` / `generate opc-client` — узлы OPC UA и endpoints;
- `import inventory` и `inventory export` — обмен перечнем тегов в TOML/CSV:
  из сканера, из чужого проекта, в отчёт для разработчиков;
- `validate rhai` — проверить скрипты до запуска;
- `trim mqtt` — убрать правила для тегов, которых больше нет.

Главное: сгенерированные TOML-файлы содержат комментарии со всеми доступными
опциями, а не только с теми, что вы выбрали. Поэтому их можно править руками,
не держа в голове синтаксис.

```text
cd prism
./devtools/tooling/prism-devtools --help
./devtools/tooling/prism-devtools scaffold --help
./devtools/tooling/prism-devtools generate tags --help
```

Подробно: `docs/03_tooling/06_DEVTOOLS.md`.

## 3. Платформа — `prism`

### Сначала задайте имя инстанса

Откройте `prism/config/00_core/00_app.toml` и задайте:

```toml
[system]
instance_name = "stand-01"
```

Сделайте это **до первого запуска**. Имя попадает в логи, MQTT-статусы,
блокировку инстанса, отладочный API и лицензию. Позже его можно поменять, но
придётся искать все места, где оно уже используется. Если оставить `prism`,
все инстансы будут выглядеть одинаково.

### Проверка и запуск

```text
cd prism
./prism --check-config
./prism
```

`--check-config` проверяет синтаксис, обязательные поля, адреса и ссылки между
тегами и ничего не запускает. Хороший конфиг заканчивается строкой
`Configuration OK`.

### Дебаггер — главный инструмент отладки

`prism-dbg` (лежит в `prism/devtools/debugger/`) показывает живые теги с
качеством и временем, позволяет писать и читать значения, принудительно
фиксировать (`force`/`freeze`), смотреть логи, диагностику, журнал алармов и
подтверждать перезагрузку конфигурации.

**Если что-то не работает — откройте дебаггер первым.** Он показывает, доходит
ли значение от устройства, в каком оно качестве и что видит платформа, вместо
чтения логов наугад.

```text
cd prism
./devtools/debugger/prism-dbg
```

### Без железа

`prism-sim` (лежит в `prism/devtools/simulator/`) заменяет реальные
устройства: читает адреса и карту регистров из `config/` и поднимает
Modbus/OPC UA серверы там, где их ждёт платформа. В терминале команда
открывает панель; без терминала (служба, CI) сразу обслуживает устройства.

```text
cd prism
./devtools/simulator/prism-sim
```

## Быстрый старт на готовом примере

В `examples/tour/` лежит полный проект: Modbus, виртуальные теги,
алармы, история, MQTT, OPC UA и Rhai. Он не требует железа и ничего не
сломает.

```text
cd examples/tour

# терминал 1: simulated field
./devtools/simulator/prism-sim

# терминал 2
./prism --check-config
./prism

# терминал 3: живое дерево тегов
./devtools/debugger/prism-dbg
```

Что попробовать: поднять `setpoint`, увидеть нагрев, поймать аларм,
посмотреть MQTT и OPC UA. Подробности — в
`examples/tour/README.md`.

## Лицензирование

Это Prism Community edition: до **128 активных тегов** на инстанс без
лицензионного файла. Выше лимита включается 60-минутный демо-режим;
коммерческие ключи пока не продаются. Подробности:
`docs/06_operations/01_LICENSING.md`.

## Документация

Начните с `docs/01_getting_started/01_OVERVIEW.md`. Дальше — по задачам:

- `docs/02_communication/01_DEVICES.md` — протоколы и теги;
- `docs/04_logic/02_ALARMS.md` — алармы;
- `docs/04_logic/01_RHAI.md` — скрипты и виртуальные теги;
- `docs/02_communication/02_MQTT.md` и `docs/02_communication/03_OPC_UA.md` — northbound;
- `docs/03_tooling/01_BENCH_TOOLS.md` — весь тулинг и отладка без железа;
- `docs/03_tooling/06_DEVTOOLS.md` — конфигуратор: генераторы, scaffold, импорт.

Главы в `docs/` на английском языке.
