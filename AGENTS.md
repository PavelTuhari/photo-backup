# Photo Backup

Эти правила относятся только к этому проекту: каталог `/Volumes/Transcend/PhotoBackup` и публичные исходники https://github.com/PavelTuhari/photo-backup. На другие проекты они не распространяются.

## Версия и журнал разработок

Каждая успешная сборка получает новый номер.

- `CFBundleVersion` в `app/Info.plist` увеличивается на 1 после каждой успешной сборки.
- `CFBundleShortVersionString` увеличивается, когда меняется поведение программы.
- Та же пара номеров дописывается в начало `CHANGELOG.md` на русском и английском.
- В журнал, README и этот файл не попадают личные названия альбомов, содержимое библиотеки и пути к отдельным медиафайлам.
- Номер версии виден внизу боковой панели.

## После каждой успешной сборки — коммит и пуш

Коммит делается из `/tmp/photo-backup-src`, не с тома exFAT. `git init` на `/Volumes/Transcend` не выполнять.

Сборка:

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
bash scripts/build_app.sh
```

Перед заменой бинарника завершить процесс `Photo Backup.app/Contents/MacOS/PhotoBackup`. Запуск — прямой вызов этого бинарника. Команда `open` на томе Transcend зависает внутри `open()`. Переменные `PB_TABLE`, `PB_ALL` и `PB_SORT_TEST` не задавать.

Синхронизация только исходников, затем пуш:

```
COPYFILE_DISABLE=1 rsync -a --delete \
  --exclude '.git/' \
  --exclude 'Photo Backup.app/' \
  --exclude 'Photos.sparsebundle/' \
  --exclude 'Photos-library-other.tar' \
  --exclude 'library.sqlite' \
  --exclude 'library.sqlite-journal' \
  --exclude 'library.sqlite-wal' \
  --exclude 'library.sqlite-shm' \
  --exclude 'catalog.sqlite' \
  --exclude 'catalog.sqlite-journal' \
  --exclude 'catalog.sqlite-wal' \
  --exclude 'catalog.sqlite-shm' \
  --exclude 'catalog.sqlite.building' \
  --exclude 'mount-device.txt' \
  --exclude 'manifest.jsonl' \
  --exclude 'missing.txt' \
  --exclude '._*' \
  --exclude '.DS_Store' \
  --exclude '__pycache__/' \
  /Volumes/Transcend/PhotoBackup/ /tmp/photo-backup-src/
```

В `/tmp/photo-backup-src`: `git add -A`, коммит, `git push origin`. Не публиковать медиа, `library.sqlite`, `catalog.sqlite`, `mount-device.txt`, `manifest.jsonl`, собранное приложение и `Photos.sparsebundle`.

## Диск и база

Не размонтировать `/Volumes/Photos`, пока это приложение или Просмотр держат том. Не копировать архив на внутренний диск. Не удалять `library.sqlite` и его журнал, пока приложение открыто. `catalog.sqlite` и `mount-device.txt` лежат рядом с приложением и в git не входят.
