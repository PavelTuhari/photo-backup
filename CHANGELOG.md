# Photo Backup

Номер сборки (`CFBundleVersion`) растёт после каждой успешной сборки. Короткий номер (`CFBundleShortVersionString`) растёт, когда меняется поведение. Личные названия альбомов в этот журнал не входят.

The build number (`CFBundleVersion`) increases after every successful build. The short version (`CFBundleShortVersionString`) increases when behavior changes. Personal album titles are not recorded here.

## 1.2 (16) — 2026-11-26

Русский.

- Годы, группы и альбомы в боковой панели сворачиваются и раскрываются. «Все годы» остаётся видимым. Если свёрнут открытый раздел, выбор возвращается на «Все годы».
- Тонкий `catalog.sqlite` без миниатюр лежит рядом с архивом. Список появляется до чтения `library.sqlite`. После сверки каталог переписывается.
- Последний узел тома Photos записывается в `mount-device.txt` и при следующем запуске монтируется напрямую.
- Внизу боковой панели видна версия и номер сборки.

English.

- Years, groups, and albums in the sidebar collapse and expand. «Все годы» stays visible. Collapsing the section that is open returns the selection to «Все годы».
- A slim `catalog.sqlite` without thumbnail blobs sits beside the archive. The list appears before `library.sqlite` is read. The catalog is rewritten after that check.
- The last Photos device node is stored in `mount-device.txt` and mounted directly on the next launch.
- The sidebar footer shows the version and the build number.

## 1.1 (15) — 2026-11-26

- Программа сама монтирует `Photos.sparsebundle`. Если образ остался подключён, а том пропал, она монтирует том APFS, а если это не выходит — отключает образ и подключает его снова.
- The app mounts `Photos.sparsebundle` itself. If the image stays attached after the volume disappears, it mounts the APFS volume, and if that fails it ejects the image and attaches it again.

## 1.1 (14) — 2026-11-26

- Shift-клик выделяет диапазон фото в сетке года, ленте галереи, группах, мозаике и таблице. Command-клик по-прежнему переключает один файл.
- Shift-click selects a range in the year grid, the gallery filmstrip, groups, the mosaic, and the table. Command-click still toggles one file.

## 1.1 (13) — 2026-11-26

- Корзина — отдельная таблица `trash`. Удаление не переписывает миниатюры. Файлы старше 30 дней снимаются при запуске и каждый час.
- В просмотре фото щипок на трекпаде увеличивает к курсору, двойное касание двумя пальцами переключает приближение, прокрутка двумя пальцами сдвигает увеличенный кадр. Видео не увеличивается.
- Trash is the `trash` table. Deleting does not rewrite thumbnail blobs. Rows older than 30 days are removed at launch and every hour.
- In the still viewer, a trackpad pinch zooms toward the pointer, a two-finger double-tap toggles a closer view, and two-finger scrolling pans while zoomed. Video is not zoomed.

## 1.1 (12) — 2026-11-26

- Альбомы, корзина, перенос между альбомами и экспорт альбома каталогом с `album.sqlite`. Исходники опубликованы без медиа и без базы.
- Albums, trash, moving files between albums, and album export as a folder plus `album.sqlite`. Sources are published without the media and without the database.
