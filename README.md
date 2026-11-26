# PhotoBackup

One folder for the Photos library copy that was taken off this Mac.

- `Photos.sparsebundle` — photos and videos in year folders. Mount with `scripts/mount_backup.sh`.
- `Photos-library-other.tar` — Photos database, previews, and the rest of the library package.
- `manifest.jsonl` — map from each year-folder file back to `originals/<directory>/<filename>`.
- `scripts/restore_photos_library.py` — rebuild a `.photoslibrary` Photos.app can open.
- `Photo Backup.app` — scroll the mounted copy. Source is in `app/`. Rebuild with `bash scripts/build_app.sh`.
- `docs/index.html` — the same instructions as a local page. `docs/REPEAT.md` is the version to hand to another agent.

Do not delete `manifest.jsonl`. The restore script cannot rebuild the Apple library layout without it, because several photos share one original filename.

## Albums and trash / Альбомы и корзина

English. `scripts/migrate_albums.py` reads `Photos.sqlite` and `manifest.jsonl` and writes two tables into `library.sqlite`: `albums` and `album_files`. It does not copy media and it does not modify the Photos library. Quit Photo Backup before running it. User albums (`ZGENERICALBUM.ZKIND = 2`) keep their names and membership. Technical albums are Избранное, Скрытые, Видео, Скриншоты, Селфи, and Удалённые. The deleted album is the trash. The moment a file enters it is a row in the `trash` table (`path`, `trashed_at` as Unix time), so the thumbnail blob is not rewritten. Restore deletes that row. Permanent delete removes the archive file and the database row; unlinking the file happens off the main thread. Empty trash does that for every trashed row. On launch, and again every hour, rows whose `trashed_at` is older than 30 days are removed from disk. In the photo viewer a trackpad pinch zooms toward the pointer, a two-finger double-tap toggles a closer view, and two-finger scrolling pans while zoomed. Changing the photo fits it again. Video is not zoomed.

Years, groups, and albums in the sidebar fold open and shut. «Все годы» stays put. A slim `catalog.sqlite` (no thumbnail blobs) sits beside the archive so the list can appear before `library.sqlite` opens. The last Photos device node is remembered in `mount-device.txt`. Albums group the same files the year browser shows. Add a file to an album, move it from the open user album into another, or remove it from the album. The file stays in its year folder. Export writes a directory of the media plus `album.sqlite` (`archive_path`, `stored_name`, capture time, size, pixels, kind, `trashed_at`).

Русский. `scripts/migrate_albums.py` переносит альбомы Photos в `library.sqlite` таблицами `albums` и `album_files`. Байты фото и видео не копируются, библиотека Photos не меняется. Перед запуском закройте Photo Backup. Пользовательские альбомы сохраняют имена и состав. Технические альбомы: Избранное, Скрытые, Видео, Скриншоты, Селфи и Удалённые. Удалённые — это корзина. Время попадания в корзину лежит в таблице `trash` (`path`, `trashed_at` как Unix), поэтому миниатюра не переписывается. Восстановление удаляет эту строку. «Удалить навсегда» стирает строку базы сразу, а файл с диска — в фоне. «Очистить корзину» делает это со всеми строками корзины. При запуске и каждый час удаляются файлы, у которых с момента записи в корзину прошло больше 30 дней. При просмотре фото щипок на трекпаде увеличивает к курсору, двойное касание двумя пальцами переключает приближение, а прокрутка двумя пальцами сдвигает увеличенное фото. Смена снимка возвращает кадр целиком. Видео не увеличивается.

Годы, группы и альбомы в боковой панели сворачиваются и раскрываются. «Все годы» остаётся на месте. Рядом с архивом лежит тонкий `catalog.sqlite` без миниатюр: список появляется до чтения `library.sqlite`. Последний узел тома Photos записан в `mount-device.txt`. Альбом группирует те же файлы, что и годы. Файл можно добавить в альбом, перенести в другой пользовательский альбом или убрать из альбома. В папке года он остаётся. Экспорт альбома создаёт каталог с файлами и `album.sqlite`: путь в архиве, имя в каталоге, дата съёмки, размер, пиксели, тип и `trashed_at`.
