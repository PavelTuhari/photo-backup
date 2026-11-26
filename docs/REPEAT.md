# Repeat this Photos backup

This folder is a backup of one Mac Photos library. An agent that can run shell commands can repeat the export, mount the result, or rebuild a `.photoslibrary`.

## What is here

| Path | Role |
| --- | --- |
| `Photos.sparsebundle` | APFS disk image. Mounts as a volume of year folders. |
| `Photos-library-other.tar` | Everything in the library except `originals`: `database`, `resources`, `private`, `scopes`, `internal`, `external`. |
| `manifest.jsonl` | One JSON object per copied file. This is the restore map. |
| `missing.txt` | Five library originals that were not on disk and were not copied. |
| `scripts/` | Export, mount, unmount, restore, album migration, and `build_app.sh`. |
| `app/` | Source of the browser. `PhotoBackup.swift` and `Info.plist`. |
| `Photo Backup.app` | Built browser for the mounted year folders. |
| `docs/` | This site. |

The year folders are inside the sparse bundle, not beside it. Mount first.

## Source library

The export read `~/Pictures/Photos Library.photoslibrary` and did not modify it.

Copied: assets with `ZTRASHEDSTATE = 0`, a filename, a directory, and a file that exists under `originals/`.

Not copied: trashed assets, and these five missing originals (see `missing.txt`):

- `originals/D/D859113A-6FEF-41BE-BBAD-751FA1A542D9.heic`
- `originals/4/465085E9-BAAE-4D28-86D7-EA24BF904B02.heic`
- `originals/9/97037C9D-E1A0-4056-A867-2E726CA075C1.heic`
- `originals/5/588A5E6C-1AFB-45DC-BE58-1BE4E608B02D.heic`
- `originals/0/068CEC58-621A-4C08-B524-9F5B59722E1E.mp4`

Count at export time: 30854 database rows, 30849 files on disk.

## Albums

`python3 scripts/migrate_albums.py` copies album membership into `library.sqlite` (`albums`, `album_files`). Quit the browser first. The Photos library is opened read-only. Trash in the browser is `files.trashed_at`: restore clears it, permanent delete removes the archive file, and a launch-time pass deletes rows older than 30 days. Details are in `README.md` in English and Russian.

## Date rule

`ZDATECREATED` is a Core Data timestamp: seconds since 2001-01-01 UTC.

```text
local_unix = ZDATECREATED + 978307200 + ZTIMEZONEOFFSET
year       = strftime("%Y", gmtime(local_unix))
```

`ZTIMEZONEOFFSET` is seconds east of UTC from `ZADDITIONALASSETATTRIBUTES`. If it is NULL, use 0. Use `gmtime` on the shifted value, not the Mac's current timezone. That is the clock time where the photo was taken.

## Name rule

Prefer `ZORIGINALFILENAME`. If it is empty, use `ZFILENAME`, then `ZUUID`, then `untitled`.

Replace `\ / : * ? " < > |` and characters below ASCII 32 with `_`. Strip ends. Drop trailing dots. If the name is longer than 240 characters, keep a 200-character stem and a 20-character suffix.

The first file for a `(year, name)` pair, compared case-insensitively, keeps that name. The next ones become `stem_2.ext`, `stem_3.ext`, and so on.

SQL row order matters. The query has no `ORDER BY`. `scripts/photos_lib.py` uses the same query. Do not add a sort.

## SQL

```sql
SELECT z.ZDIRECTORY, z.ZFILENAME, z.ZKIND, z.ZUUID, z.ZDATECREATED,
       a.ZORIGINALFILENAME, a.ZTIMEZONEOFFSET
FROM ZASSET z
LEFT JOIN ZADDITIONALASSETATTRIBUTES a
  ON a.Z_PK = z.ZADDITIONALATTRIBUTES
WHERE z.ZTRASHEDSTATE = 0
  AND z.ZFILENAME IS NOT NULL
  AND z.ZDIRECTORY IS NOT NULL
```

`ZKIND = 1` is video. Anything else copied from `originals/` is treated as a photo.

The library file for that row is `originals/ZDIRECTORY/ZFILENAME`. The backup file is `<year>/<cleaned name>`.

## Why the media is in a sparse bundle

The external disk is exFAT with 1 MB clusters. Tens of thousands of individual files write at a few MB/s. A single large file writes at about 50 MB/s. The year folders therefore live on an APFS sparse bundle stored on the exFAT disk. Create and mount it with:

```bash
hdiutil create -size 160g -fs APFS -volname Photos -type SPARSEBUNDLE \
  "/Volumes/Transcend/PhotoBackup/Photos.sparsebundle"
bash scripts/mount_backup.sh
```

160 GB is the maximum size. The bundle only occupies the space it uses.

## Export again

```bash
python3 scripts/export_photos.py \
  --library "$HOME/Pictures/Photos Library.photoslibrary" \
  --media /Volumes/Photos \
  --archive "/Volumes/Transcend/PhotoBackup/Photos-library-other.tar"
```

The archive command inside that script is:

```bash
tar -cf Photos-library-other.tar -C "$LIBRARY" \
  database resources private scopes internal external
```

`COPYFILE_DISABLE=1` is set so exFAT does not grow a `._` sidecar for every file.

## Mount

```bash
bash scripts/mount_backup.sh
```

Prints the mount point, usually `/Volumes/Photos`. Running it twice does not attach a second copy.

```bash
bash scripts/unmount_backup.sh
```

## Restore a Photos library

`manifest.jsonl` maps each year-folder file back to `originals/ZDIRECTORY/ZFILENAME`.

```bash
python3 scripts/restore_photos_library.py --dry-run
python3 scripts/restore_photos_library.py
```

The default destination is `/Volumes/Photos/Restored Photos Library.photoslibrary`. Files are cloned with `cp -c` when the destination is on that same APFS volume, so this does not duplicate 114 GB. Do not restore onto the internal disk unless it has more than 120 GB free.

Then:

```bash
open -a Photos "/Volumes/Photos/Restored Photos Library.photoslibrary"
```

Hold Option while launching Photos if you want the system library chooser instead.

## Browse

Open `Photo Backup.app` in this folder. It mounts the bundle and shows the year folders. Thumbnails come from QuickLook (`QLThumbnailGenerator`). Still images are decoded with ImageIO through `NSImage`. Video uses AVKit (`AVPlayerView`). Those are the system frameworks the Photos app uses to display a file. The grid itself is not PhotoKit: PhotoKit only reads the system library, not an arbitrary folder.

Rebuild the app with:

```bash
bash scripts/build_app.sh
```

## manifest.jsonl fields

`year`, `name`, `directory`, `filename`, `uuid`, `kind`, `size`, `created`.

`created` is the local Unix time from the date rule, or null.
