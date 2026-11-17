# Видео и HDMI

## 1. Тракт

`atari_video.v` — scandoubler ядра. Вход — 8-bit RGB от GTIA на
`VIDEO_PIXCE` (2× colour clock), 456 hi-res пикселей в строке, 312 строк
PAL. Выход — 720×576 @ ~50 Гц в кадре 912×624 на том же клоке 28.571 МГц.

- строка source = 456 px = 1824 клока;
- выходная строка = 912 px = 912 клоков (source-строка = 2 выходные);
- каждый source-пиксель пишется дважды; каждая source-строка читается
  дважды (чересстрочный кадр);
- два line buffer'а ping-pong на hsync (подход UnoXT).

## 2. Окно source (вариант B)

ANTIC/GTIA (PAL):

| Область | hi-res px | colour clocks |
|---|---|---|
| hblank-free (visible) | 68..443 | 34..221 |
| wide playfield | 88..443 | 44..221 |
| normal playfield (40 col) | 96..415 | 48..207 |
| narrow playfield | 128..383 | 64..191 |

Окно выбрано по **normal/active**, чтобы 40-колоночные игры (Pong, Miner)
были по центру, как на реальном TV:

```verilog
parameter [9:0] SRC_X0   = 10'd78;   // cc 39
parameter [9:0] SRC_W    = 10'd356;  // 712 output px
parameter [9:0] PIC_LEFT = 10'd4;    // 4 px поля
```

`PIC_START=100`, `PIC_END=812`; DE-окно 96..815. Wide-поле (`44..221`)
уходит на ~5 cc вправо, его правый край (~10 px) — в overscan, как на TV.

Старый вариант A (`SRC_X0=88`) центрировал wide, но normal-игры были на
~21 px левее центра.

Сравнение кадров: `sim/tb_video_compare.v` (frame_a/b.ppm).

## 3. Вертикаль

240-строчная картинка Atari удваивается в 480 строк. Положение относительно
vsync задаётся ANTIC/GTIA:

- PAL: vsync на `vcount=275`, vblank кончается на `vcount=8` следующего
  поля → картинка начинается на **44-й** source-строке (44..283);
- NTSC: vsync на `vcount=255`, vcount wrap на 262, vblank с 8 →
  картинка с 15-й строки (15..254).

```verilog
wire [10:0] vc_raw = {oline,1'b0} + {9'd0,phase} + (pal ? 11'd584 : 11'd594);
```

- PAL `K=584` → `vc 48..527` (48 px сверху и снизу);
- NTSC `K=594` (= −30 mod 624) → `vc 0..479`.

Старое `K=600` давало 66..545 (сверху 66, снизу 30) — картинка была
опущена вниз.

## 4. Симуляция

`sim/tb_video_frame.v` — один кадр 720×576 с реальной геометрией строки и
маркерами (красный — wide, зелёный — normal, синий — центр active).
Пишет `frame.ppm`.

`sim/tb_video_compare.v` — два окна одновременно (A: 88, B: 78), пишет
`frame_a.ppm`/`frame_b.ppm` и печатает колонки маркеров.

Результат B (симуляция): non-black `rows 48..527`, картинка `cols 4..715`,
normal-края `38..677` (центр 357 при центре кадра 360; с учётом задержки
захвата ~−2 px реальный центр ~358..359).

## 5. OSD

`kg_l2_osd_overlay` рисует bitmap OSD поверх `vid_rgb` в том же 720×576;
позиция OSD не зависит от `SRC_X0`. При смене окна OSD не трогали.

## 6. HDMI

`atari_hdmi` (MiniG) / `kg_hdmi_ft` (Go) — Karabas modules; pixel clock
28.571 МГц, аудио 48 кГц. PLL: VCO 800 МГц, CLKOUT1 = 28.571 МГц,
CLKOUT3 = 25 МГц MCU (CLKOUT4_DIVIDE=28 у MiniG, 14 у Go).
