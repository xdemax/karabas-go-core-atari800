# Сборка, заливка и команды

## 1. Сборка

ISE 14.7, `PART = xc6slx25-ftg256-2`.

```sh
cd src
make go               # Karabas Go: karabas_go.bin
make mini             # Karabas Mini rev A-F: karabas_mini.bin
make minig            # Karabas Mini G: karabas_minig.bin
make all              # все три + atari800.kg
make go-report        # LUT / slices / RAMB / timing для Go
make mini-report      # то же для Mini
make minig-report     # то же для MiniG
make minig-xst        # только синтез
make minig-impl       # ngdbuild + map + par + bitgen
make clean            # промежуточные файлы (bin/kg остаются)
```

`FAST=1` — быстрая тестовая сборка (без `trce`, ниже effort):

```sh
make minig FAST=1
```

`atari800.kg` собирается `tools/make_core.py` из `src/core.json` и
битстримов; в нём три образа (`go`, `mini`, `minig`), firmware выбирает
нужный по `HW_ID`.

## 2. Заливка `.kg` на SD

Плата отваливается от USB после `msc`; нужен power-cycle.

```sh
cd <repo>
python3 tools/karabas.py 'AT+KARABAS=version'   # проверить связь
python3 tools/karabas.py 'AT+KARABAS=msc'
sleep 6
udisksctl mount -b /dev/sdb1 -o rw
lsblk                                            # убедиться, что это kgo
md5sum /run/media/$USER/kgo/atari800.kg
cp -f src/atari800.kg /run/media/$USER/kgo/atari800.kg
sync
md5sum /run/media/$USER/kgo/atari800.kg src/atari800.kg
udisksctl unmount -b /dev/sdb1
udisksctl power-off -b /dev/sdb
# power-cycle MiniG
```

## 3. Загрузка ядра и образов

```sh
python3 tools/karabas.py 'AT+KARABAS=load:atari800'
python3 tools/karabas.py 'AT+KARABAS=mount:disk:/atari800/xex/Pong.xex'
# или ATR:
python3 tools/karabas.py 'AT+KARABAS=mount:disk:/atari800/atr/GAMES002.ATR'
python3 tools/karabas.py 'AT+KARABAS=osd:cold_reset=1'
```

Eject диска:

```sh
python3 tools/karabas.py 'AT+KARABAS=eject:disk'
python3 tools/karabas.py 'AT+KARABAS=osd:cold_reset=1'
```

Полезные команды:

```sh
python3 tools/karabas.py 'AT+KARABAS=version'
python3 tools/karabas.py 'AT+KARABAS=osd'
python3 tools/karabas.py 'AT+KARABAS=osd:reset=1'          # тёплый reset
python3 tools/karabas.py 'AT+KARABAS=osd:cold_reset=1'     # cold reset
python3 tools/karabas.py 'AT+KARABAS=debug:1' --wait 20
python3 tools/karabas.py 'AT+KARABAS=debug:0'
```

`AT+KARABAS=help`/`?` — список команд текущей прошивки (см. также
`karabas-go-firmware/docs/link_v2.md`).

## 4. Debug-слова

`debug:1` циклически выдаёт 32 слова (`Debug Address: 00xx, Data: 00yy`):

| Адрес | Что |
|---|---|
| 0 | {последняя команда SIO, число команд} |
| 1 | {ответов, ACK} |
| 2 | {6'b0, atr_ready, loading, rx-байт} |
| 3 | atr_scount |
| 4 | atr_ssize |
| 5 | {defer, flags} |
| 6..8 | последний 5-байтный кадр команды |
| 9..10 | SRAM-байт-адрес последнего ответа |
| 11..12 | последний dsk_addr |
| 13 | последний dsk_data |
| 14 | последний сектор R |
| 15 | последняя команда |
| 16..17 | atr_nsec (512-байтные файловые сектора) |
| 18..19 | atr_waddr |
| 20..21 | sdc_sector |
| 22 | mcu byte (clk_host) |
| 23 | ld_data @ 0x316A90 |
| 24 | xex_state |
| 25 | {xex_mode, xex_done, xex_busy, xex_rd_req} |
| 26 | xex sdc capture count |
| 27..30 | первые 8 байт последнего ответа 1050 |
| 31 | checksum последнего ответа |

Быстрый признак ATR-пути: `word22/word23 = 0xC8` на GAMES002.
XEX-путь: `word25` = `0x8` (mode=1, done=0, busy=0) для synthetic-загрузчика;
последний сектор = `4 + ceil(size/128) - 1`.

## 5. OSD и клавиши

- **F1** — открыть/закрыть OSD.
- **F8** — Help, **F9** — Start, **F10** — Select, **F11** — Option,
  **F12** — Reset, **Alt+F12** — Cold reset.
- Disk: `.atr`, `.xex`; Cartridge: `.car`, `.rom`, `.bin`.
- Eject: `Del`/`Backspace` на пункте `F` или `[ Eject ]` в браузере.
- RAM: 64K … 1088K (OSD `System`), Video PAL/NTSC, Joystick swap,
  Cartridge type.

## 6. Симуляция (ISim)

```sh
sim/run_isim.sh sio      # atari_sio_disk
sim/run_isim.sh atr      # atari_atr_loader
```

Ручные тестбенчи (см. `doc/SIMULATION.md`):

```sh
# видео: один кадр 720x576 с реальной геометрией ANTIC
#   atari_video.v + sim/tb_video_frame.v -> frame.ppm
# сравнение двух окон:
#   atari_video.v + sim/tb_video_compare.v -> frame_a.ppm, frame_b.ppm
# система XEX (ATR loader + synthetic 6502 loader):
#   atr_loader + xex_prefix_rom + kg_async_fifo + sim/tb_xex_system.v
```

`sim/pong.hex` — Pong XEX для системного теста. `sim/tb_ps2fifo`-подобная
проверка FIFO клавиатуры делалась отдельно (пачка `12 E0 F0 34 56 78` через
40 нс — PASS).

## 7. `xex2atr.py`

`tools/xex2atr.py` — старый offline-путь: собрать synthetic ATR из `.xex`
на PC. Сейчас не нужен для платы (FPGA делает это сама), оставлен для
отладки/сравнения.
