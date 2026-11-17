# Atari 800XL для Karabas Go / Mini G

Порт ядра Atari 800XL с MiSTer (`a8core` Марка Уотсона) на Karabas Go и Mini G
(XC6SLX25-2 FTG256, 4 МБ SRAM). Машина одна; отличаются верхние обёртки, PLL,
видео/аудио-обвязка и UCF. Один `atari800.kg` содержит битстримы `go` и
`minig`; firmware выбирает нужный по `HW_ID`.

## Статус (2026-11-17, build 26111730)

- **Mini G** — основной целевой стенд. Работают: ATR в Disk-слоте, прямой
  `.xex` в Disk-слоте, видео 720×576 PAL, клавиатура, джойстики, OSD,
  Altirra OS/BASIC, картриджи, SIO 1050.
  Проверено на железе: `Pong.xex`, `Miner 2049er.xex`, `GAMES002.ATR`
  (сборка до вертикали/FIFO; новая сборка проверяется).
- **Go** — собирается из того же RTL; битстрим включён в `.kg`, на железе
  не проверялся (платы нет).
- **Mini rev A-F** — исходники/конфиги в дереве, в этом релизе не
  собираются и не проверялись.
- **XEX** — synthetic-ATR + 6502-загрузчик, запускается после coldstart,
  BASIC выключается через `PORTB=$BF`. FPGA-DMA до boot не используется:
  Altirra OS coldstart стирает RAM (`$EF1F`) — см. `doc/XEX_ATR.md`.
- **ATR** — штатный 1050-сервер, 128/256-байтные сектора, 360/360 чтений
  на GAMES002 (spurious second read закрыт).
- **Видео** — окно source `78..433` (356 px), normal/active по центру;
  вертикаль 48/48. Подробно: `doc/VIDEO_HDMI_TIMING.md`.
- **Клавиатура** — PS/2 set 2 от MCU через FIFO (burst E0/F0-байтов).
- **Не сделано:** FPGA-DMA после coldstart (для скорости загрузки XEX),
  NTSC на железе, VBXE, PBI/HDD, запись диска.

Точные хэши и что проверять — в `doc/STATUS_2026-11-17.md`.

## Что внутри

| Блок | Реализация |
|---|---|
| Машина | MiSTer `a8core`: 6502, ANTIC, GTIA, PIA, POKEY/PokeyMAX (моно) |
| Память | 4 МБ SRAM вместо SDRAM: `low_memory=4`, RAM до 1088K, картридж 1 МБ |
| OS/BASIC | Altirra OS и Altirra BASIC, встроены в BRAM (`internal_rom=1`) |
| Видео | `atari_video.v`: 456 source px → 720×576 @ ~50 Гц, 28.571 МГц |
| HDMI | `kg_hdmi_ft` (link v2), 48 кГц audio |
| Звук | POKEY/GTIA → DC-blocker → 48 кГц → PCM5102 I2S + HDMI |
| Клавиатура | MCU PS/2 set 2 → async FIFO → `ps2_to_atari800` (direct mode) |
| Джойстики | Karabas `up/down/left/right/A/B/C` → MiSTer `FRLDU` |
| Диск | `atari_atr_loader` + `atari_sio_disk` (ATR); `xex_prefix_rom` (XEX) |
| OSD | Reset, RAM, PAL/NTSC, Joystick swap, Cartridge type, Disk, Cartridge |

## Управление

- **F8** — Help, **F9** — Start, **F10** — Select, **F11** — Option,
  **F12** — Reset, **Alt+F12** — Cold reset.
- OSD: **F1** (или кнопка OSD на корпусе); в OSD — стрелки/Enter/Esc.
- Disk-слот: `.atr`, `.xex`; Cartridge-слот: `.car`, `.rom`, `.bin`.
- Eject: `Del`/`Backspace` на пункте `F` в OSD или `[ Eject ]` в браузере.

## Сборка

Клонировать с сабмодулем:

```sh
git clone --recursive https://github.com/xdemax/karabas-go-core-atari800.git
```

ISE 14.7:

```sh
cd src
make go               # Karabas Go
make minig            # Karabas Mini G
make all              # оба битстрима + один atari800.kg
make minig-report     # LUT / slices / RAMB / timing
make minig FAST=1     # быстрая тестовая: без trce, ниже effort
```

`PART = xc6slx25-ftg256-2`. Общие модули Karabas — git submodule `modules/`
(`https://github.com/andykarpov/karabas-go-modules.git`, закреплён коммит).

## Установка на плату

Прошивка **26111315 или новее** (MCU link v2).

```sh
# 1. записать .kg на SD
python3 tools/karabas.py 'AT+KARABAS=msc'
udisksctl mount -b /dev/sdb1 -o rw
cp -f src/atari800.kg /run/media/$USER/kgo/atari800.kg
sync
udisksctl unmount -b /dev/sdb1
udisksctl power-off -b /dev/sdb

# 2. после power-cycle загрузить ядро и образ
python3 tools/karabas.py 'AT+KARABAS=load:atari800'
python3 tools/karabas.py 'AT+KARABAS=mount:disk:/atari800/xex/Pong.xex'
python3 tools/karabas.py 'AT+KARABAS=osd:cold_reset=1'
```

Подробнее (AT-команды, OSD, debug, ISim) — `doc/TOOLS_AND_COMMANDS.md`.

## Память

| Байтовый адрес | Что |
|---|---|
| `0x000000–0x1FFFFF` | RAM (фактически до 1088K) |
| `0x200000–0x2FFFFF` | образ картриджа (1 МБ) |
| `0x300000–0x3FFFFF` | ATR/XEX-образ для SIO, читается на лету |

Карта и тайминги SRAM — `doc/KARABAS_MEMORY.md`.

## Документация

- `doc/STATUS_2026-11-17.md` — **главный актуальный статус**, что проверено.
- `doc/TOOLS_AND_COMMANDS.md` — сборка, заливка `.kg`, AT-команды, OSD, debug.
- `doc/XEX_ATR.md` — ATR и прямой `.xex`, synthetic-загрузчик, `$BF`,
  почему FPGA-DMA до coldstart не работает.
- `doc/VIDEO_HDMI_TIMING.md` — 720×576, окно source, центровка по X/Y.
- `doc/KARABAS_MEMORY.md` — карта SRAM и контроллер.
- `doc/SIMULATION.md` — ISim, тестбенчи, как гонять без платы.
- `doc/ARTIFACTS.md` — сохранённые сборки и md5.
- `doc/FAILURES.md` — уроки (что и почему ломалось).
- `TODO.md` — что осталось.

## Лицензия и третьи стороны

Основная лицензия Karabas-порта — **GPL-3.0** (`LICENSE`), но оригинальное
ядро `a8core` Марка Уотсона **не GPL**: оно распространяется для
некоммерческого использования (см. заголовки файлов и `NOTICE`). Altirra
OS/BASIC — all-permissive (Avery Lee), текст в `NOTICE`. Общие модули
Karabas — отдельный submodule со своими уведомлениями. Подробности —
`NOTICE`.
