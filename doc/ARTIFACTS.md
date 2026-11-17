# Сохранённые сборки и релизы

## Текущая ветка (build 26111730)

| Файл | md5 | Что |
|---|---|---|
| `src/atari800.kg` | `68d4f3a912e052b951f9b11cda620607` | Go + MiniG, один `.kg` |
| `src/karabas_go.bin` | `200fbea4af857158491986e363eab880` | Go, LUT 53%, timing 0 |
| `src/karabas_minig.bin` | `6ceb9961c3dd2e2a3be19fb61722cb12` | MiniG, LUT 63%, timing 0 |

В `.kg` два битстрима: `go` (id 2, size `0x0B4A72`) и `minig`
(id 8, size `0x0B418E`). Firmware выбирает нужный по `HW_ID`; нужна
прошивка 26111315+ (link v2).

## Последняя подтверждённая на железе

| Файл | md5 | Что |
|---|---|---|
| `atari800.kg` (MiniG, video B + `$BF`) | `71e95c5cb688911dea89eb688944d812` | Pong, Miner 2049er, GAMES002.ATR |
| `karabas_minig.bin` | `de230d8f64131af45ed6e2dfe91c0110` | то же |

`6ceb9961` (текущий MiniG) добавляет вертикаль `K=584` и keyboard FIFO;
на железе ещё не подтверждён.

## Релизы

GitHub Releases: https://github.com/xdemax/karabas-go-core-atari800/releases

Релиз публикуется одним файлом `atari800.kg` + md5 и short notes
(Fix / Other / Build). Пока не опубликован: сначала проверить MiniG
`6ceb9961` на вертикаль/клавиатуру.

## Артефакты

- Старые `.kg`/`.bin`/ROM'ы в репозиторий не кладутся (`.gitignore`),
  только в GitHub Release.
- Геометрию кадра можно получить симуляцией:
  `sim/run_isim.sh video_compare` → `frame_a.ppm`, `frame_b.ppm`.
