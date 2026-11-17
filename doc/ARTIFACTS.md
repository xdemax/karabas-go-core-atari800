# Сохранённые сборки и релизы

## Текущая ветка (build 26111740)

| Файл | md5 | Что |
|---|---|---|
| `src/atari800.kg` | `4f0c1f7d784dba10ce73d5abd8b41bb6` | Go + Mini rev A-F + MiniG, build 26111740 |
| `src/karabas_go.bin` | `5357f67753b654d4a9c916509056e5cc` | Go, LUT 53%, slices 76%, timing 0 |
| `src/karabas_mini.bin` | `861fc40c6ca3b6a2c9153c92528be3ee` | Mini rev A-F, LUT 59%, slices 81%, timing 0 |
| `src/karabas_minig.bin` | `680c4a367d96eeb16b52b2eecaa2acba` | MiniG (rev G), LUT 63%, slices 84%, timing 0 |

В `.kg` три битстрима:

| Board | id | size |
|---|---:|---:|
| `go` | 2 | `0x0B4C56` |
| `mini` (rev A-F) | 4 | `0x0B4070` |
| `minig` (rev G) | 8 | `0x0B402A` |

Firmware выбирает нужный по `HW_ID`; нужна прошивка 26111315+ (link v2).

## Проверено на железе

| Файл | md5 | Что |
|---|---|---|
| `atari800.kg` (проверенная сборка, build 26111730) | `e54381401477436eaf085b7d6c666210` | MiniG `680c4a36`: HDMI-звук, джек, ATR, eject+reset, видео |
| `src/karabas_minig.bin` | `680c4a367d96eeb16b52b2eecaa2acba` | тот же MiniG, что в релизном `.kg` |

Релизный `atari800.kg` `4f0c1f7d` содержит **тот же** MiniG `680c4a36`;
изменены только Go и Mini rev A-F (собраны, на железе не проверялись).

## Релизы

### v26111740 (Latest)

https://github.com/xdemax/karabas-go-core-atari800/releases/tag/v26111740

Ассет: `atari800.kg` (2,216,710 байт, md5
`4f0c1f7d784dba10ce73d5abd8b41bb6`).

- HDMI-звук: front porch 24 px (data islands), `kg_hdmi_ft`, отдельный
  48-кГц сэмпл; джек на 55.8 кГц без шума.
- Eject + reset: cold-start ОС без диска (`force_cold`), синий экран.
- Джойстики: прямой Karabas → FRLDU.
- Проверено на MiniG rev G. Go / Mini rev A-F собраны, не проверялись.

### v26111730 (historical)

https://github.com/xdemax/karabas-go-core-atari800/releases/tag/v26111730

Ассет: `atari800.kg` (md5 `08ee3e45f1c13fab181bbc3cf61c3187`).
В этой сборке были известные баги: молчал HDMI-звук на MiniG и были
перепутаны right/down у джойстиков. Заменён на v26111740.

## Артефакты

- Старые `.kg`/`.bin`/ROM'ы в репозиторий не кладутся (`.gitignore`),
  только в GitHub Release.
- Геометрию кадра можно получить симуляцией:
  `sim/run_isim.sh video_compare` → `frame_a.ppm`, `frame_b.ppm`.
