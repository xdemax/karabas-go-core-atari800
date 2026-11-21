# Статус 2026-11-21: fix timing / Numen

Это актуальный итог релиза **v26112100 — fix timing** (2026-11-21). Более ранние документы
`TZ_ATARI_VIDEO.md`, `TZ_ATARI_VIDEO_NEXT.md`, `TZ_ATARI_VIDEO_NEXT2.md` и
`TZ_ATARI_VIDEO_PHASE_RESULT.md` описывают промежуточные состояния и могут
содержать уже неверные результаты (например, старый `tb_video_glitch` с 1
failure).

## 1. Главная причина «рваного» Numen

В `atari800_machine.v` было:

```verilog
.THROTTLE_COUNT_6502 (6'd15),
```

`THROTTLE_COUNT_6502` — это **маска множителя CPU**, как в MiSTer
(`CPU_SPEEDS = {1, 2, 4, 8, 16}`), а не «cycle_length-1». Проверка
`shared_enable` в GHDL:

```text
THROTTLE=1   -> 1x
THROTTLE=15  -> 8x
```

То есть Numen работал на **8x turbo**. Duke-движок делал page flip несколько
раз за кадр, отсюда разрывы. Исправлено на:

```verilog
.THROTTLE_COUNT_6502 (6'd1),
```

MiSTer для 1x использует именно `1` (`Atari800.sv`,
`CPU_SPEEDS[8] = '{6'd1,6'd2,6'd4,6'd8,6'd16,...}`,
`atari800top.vhd`, `.THROTTLE_COUNT_6502 => CPU_SPEED`).

После этого картинка Numen на железе нормальная, без глитчей.

## 2. Видеомодуль

Принят `src/rtl/atari_video.v` из `atari_video (2).v`:

- phase-фикс `H_LAG=256`, новый расчёт `perr`, ресинхронизация во вторую
  строку пары;
- ограниченный slew `STEP_MAX=12`;
- `pic_blank`: DE остаётся 576 строк, RGB чёрный вне строк 48..527;
- `H_START=0`, DE 0..719;
- `DBG_OVERLAY` для диагностики;
- line buffer не перезаписывает читаемую строку.

Это дало:

- `tb_video_standard_timing`: **0 failures**, `DE 720..720`, `HS 64..64`,
  `DE-rise->HS 732..732`, `line 912..912`, `VS 4560`, `frame 569088`,
  `DE lines 576`, `pair check 1440 compared, 0 mismatched`;
- `tb_video_glitch`: **0 failures**, сценарий 4 `hs_o 912..924`, все
  сценарии 480 строк, `first=91`;
- старый модуль на pair check давал 12 несовпадений.

То есть новый модуль **лучше**: убран шов/рассинхрон пары строк и повышена
устойчивость к пропаже/лишней синхре. Но он не был причиной «рваного» Numen —
её убирал CPU 1x.

## 3. Геометрия кадра (симуляция)

`tb_video_frame` на текущем `atari_video.v`, PAL 720x576:

```text
DE 720x576
vertical picture in DE: 48..527, centre 287.5 (screen centre 288)
horizontal visible area: 4..715, centre 359.5 (screen centre 360)
normal playfield: 38..677, centre 357.5  -> ~2.5 px left of centre
centre marker (blue): 356..357
```

Вертикально картинка стоит ровно по центру. Normal playfield смещён примерно
на 2.5 пикселя влево; для 720 px это ~0.3%. Правый красный маркер wide-поля
не виден, потому что окно источника `SRC_X0=78`, `SRC_W=356` (78..433), а
wide-поле идёт до 443. Это кадрирование, а не сдвиг DE.

## 4. Остаточный тайминг относительно PAL

После 1x:

| Параметр | Наше ядро | PAL Atari | Разница |
|---|---:|---:|---:|
| CPU | 1.7857 МГц | 1.7734 МГц | +0.69% |
| кадр | 50.206 Гц | 50.080 Гц | +0.25% |
| циклов CPU на кадр | 35568 | 35412.2 | +155.8 (+0.44%) |
| циклов CPU на строку | 114.0 | 113.5 | +0.5 (+0.44%) |

Это уже не 8x, а доли процента. Точная подгонка под PAL требует отдельного
клокового домена/дробного enable и вынесена в отдельную задачу; текущий
рабочий релиз её не требует.

## 5. Сборка

Релиз: **v26112100 — fix timing**.

```text
karabas_go.bin     ee03e4557f2e39994451637866947eee   Timing Score 0
karabas_mini.bin   798284ba6872c8ec04b5e5de236683d8   Timing Score 0
karabas_minig.bin  e557069f8325dc6d7c8bcd8741fe2dcc   Timing Score 0
atari800.kg        48195111150df8ff5a896cfddf3853f9   build 26112100
```

Проверено на **Go и Mini G**: Numen на деревьях без глитчей, видео/ATR/XEX/OSD работают. Mini rev A-F собран, на железе не проверялся.

## 6. Что дальше

1. Релиз **v26112100 — fix timing** опубликован.
2. Side B у Numen пока не реализован как hot-swap; для него нужен ping-pong
   двух банков ATR (см. обсуждение) или runtime-загрузка без reset.
3. Точную подгонку PAL-тайминга (дробный клок/второй домен) делать только
   отдельной веткой, чтобы не рисковать рабочей сборкой.
