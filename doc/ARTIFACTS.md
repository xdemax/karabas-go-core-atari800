# Сохранённые сборки и релизы

## Текущая ветка (build 26111730)

| Файл | md5 | Что |
|---|---|---|
| `src/atari800.kg` | `08ee3e45f1c13fab181bbc3cf61c3187` | Go + Mini rev A-F + MiniG |
| `src/karabas_go.bin` | `200fbea4af857158491986e363eab880` | Go, LUT 53%, timing 0 |
| `src/karabas_mini.bin` | `8c15fb331fa3831c19177d9e97c6ccad` | Mini rev A-F, LUT 61%, timing 0 |
| `src/karabas_minig.bin` | `6ceb9961c3dd2e2a3be19fb61722cb12` | MiniG (rev G), LUT 63%, timing 0 |

В `.kg` три битстрима:

| Board | id | size |
|---|---:|---:|
| `go` | 2 | `0x0B4A72` |
| `mini` (rev A-F) | 4 | `0x0B423E` |
| `minig` (rev G) | 8 | `0x0B418E` |

Firmware выбирает нужный по `HW_ID`; нужна прошивка 26111315+ (link v2).

## Последняя подтверждённая на железе

| Файл | md5 | Что |
|---|---|---|
| `atari800.kg` (MiniG, video B + `$BF`) | `71e95c5cb688911dea89eb688944d812` | Pong, Miner 2049er, GAMES002.ATR |
| `karabas_minig.bin` | `de230d8f64131af45ed6e2dfe91c0110` | то же |

`6ceb9961` (текущий MiniG) добавляет вертикаль `K=584` и keyboard FIFO;
на железе ещё не подтверждён.

## Релизы

**v26111730** — https://github.com/xdemax/karabas-go-core-atari800/releases/tag/v26111730

Ассет: `atari800.kg` (2,217,046 байт, md5 `08ee3e45f1c13fab181bbc3cf61c3187`).
Проверено на Mini rev G: Pong, Miner 2049er, GAMES002.ATR, вертикаль и
клавиатура. Mini rev A-F и Go собраны, но на железе не проверялись.

## Артефакты

- Старые `.kg`/`.bin`/ROM'ы в репозиторий не кладутся (`.gitignore`),
  только в GitHub Release.
- Геометрию кадра можно получить симуляцией:
  `sim/run_isim.sh video_compare` → `frame_a.ppm`, `frame_b.ppm`.
