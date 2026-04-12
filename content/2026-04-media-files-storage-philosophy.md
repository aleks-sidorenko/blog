+++
title = "A Philosophy for Personal Media File Storage"
date = 2026-04-12
description = "Separating storage from organization: a date-based approach to personal media files"
path = "blog/2026/04/media-files-storage-philosophy"
[taxonomies]
tags = ["nix", "media", "tooling", "automation"]
categories = ["tooling"]
+++

If you've been taking photos and videos for more than a few years, you've probably accumulated a mess. Files from phones named `IMG_20230415_143022.jpg`, Pixel cameras producing `PXL_20230415_143022.mp4`, screenshots labeled `Screenshot_2023-04-15`, and whatever your old point-and-shoot decided to call things. They're scattered across devices, cloud services, and backup drives — some with correct dates in their metadata, some without, some with dates that are just wrong.

At some point you try to organize them. You create folders: "Vacation 2023", "Family", "Work Events". It feels productive for a week. Then a photo belongs in two folders, or you can't remember whether that dinner was "Family" or "Friends", or you find a folder called "Misc" with 400 unsorted files from three years ago.

I went through this cycle a few times before stepping back and rethinking the problem.

<!-- more -->

## Separate Storage from Organization

The root issue is mixing two different concerns: *where files live on disk* and *how you browse and find them*. These have different requirements, and trying to solve both with a folder hierarchy satisfies neither.

**Storage** should be boring. It needs to be consistent, predictable, and optimized for durability. You want to back it up with `rsync` and know that nothing got lost. You want to look at any file and immediately know when it was taken. You don't want to think about it.

**Organization** — albums, tags, facial recognition, search, sharing — is subjective and fluid. The same photo might belong to "Trip to Berlin", "Photos with Anna", and "2023 Highlights". It changes over time as you create new albums or rethink old ones. This is a problem that tools like Google Photos, Apple Photos, or self-hosted alternatives like Immich are purpose-built to solve. They index metadata, run AI tagging, and let you organize however you want — without moving a single file.

The insight is that these tools work *best* when your underlying files have reliable, consistent metadata. If every file has a correct EXIF date and a predictable name, the organization layer can do its job without fighting your storage layer.

So the philosophy is simple: **make storage predictable and leave organization to tools designed for it**.

### Why Date Is the Right Primary Key

Every media file has exactly one creation timestamp. It's objective — there's no decision to make about what "category" a photo belongs to. It's immutable — a photo taken on April 15th, 2023 was taken on April 15th, 2023, forever. And it's universal — phones, cameras, and screenshots all produce timestamps, even if they store them differently.

Date also makes practical operations easy. Backups are incremental by month. A canonical name makes spotting duplicates easy — two files with the same timestamp and size are almost certainly the same photo. And when you sort by name, you get chronological order for free.

## The Target File Structure

Here's what every media file ends up looking like in my system:

```
$MEDIA_HOME/All/
  2023/
    01/
      20230115_083022.jpg
      20230115_143022.mp4
      20230115_143022-1.jpg
    04/
      20230415_091500.heic
  2024/
    03/
      20240301_120000.png
```

The rules are intentionally strict:

- **Canonical filename:** `YYYYMMDD_HHMMSS.ext` — derived from the file's EXIF `CreateDate`
- **Lowercase extensions only:** `.jpg`, not `.JPG`
- **Duplicate handling:** if two files share the same second, they get a `-1`, `-2` suffix
- **Minimum 30KB file size:** filters out thumbnails and metadata artifacts
- **Supported types:** jpg, jpeg, png, heic, mp4, mov

No albums, no categories, no nested project folders. Just year, month, and a timestamp. The structure is so predictable that you could write a one-liner to verify its integrity.

Here's a typical before-and-after. A messy directory like this:

```
Downloads/phone-backup/
  IMG_20230115_083022.JPG
  PXL_20230415_091500.jpg
  Screenshot_2023-04-15-14-30-22.png
  VID_20240301_120000.mp4
  random_photo.jpg          (no date in name, but has EXIF data)
  old_scan.jpg              (no date anywhere, taken from mtime)
```

Becomes:

```
$MEDIA_HOME/All/
  2023/
    01/
      20230115_083022.jpg
    04/
      20230415_091500.jpg
      20230415_143022.png
  2024/
    03/
      20240301_120000.mp4
  ...
```

Every file normalized, every date preserved, every name predictable.

## The Workflow: Normalize, Then Import

To get from mess to order, I built two CLI tools: `media-normalize` and `media-import`. The workflow is always the same — normalize first, then import into the library.

### Step 1: Normalize

`media-normalize` takes a directory of media files and standardizes them in place. It does three things in sequence:

**Lowercase extensions.** Files like `IMG_1234.JPG` or `video.MOV` get their extensions lowercased. Simple, but necessary — mixed-case extensions cause subtle issues with tools that do case-sensitive matching.

**Fill missing EXIF dates.** This is where most of the complexity lives. Not every file has valid EXIF metadata, so the tool tries several sources in order:

1. If the file already has a valid `CreateDate` in its EXIF data, leave it alone
2. If not, try to parse the date from the filename — it recognizes common prefixes like `IMG_`, `PXL_`, `VID_`, `Screenshot_` followed by a timestamp, as well as dashed date formats like `2023-04-15_14-30-22`
3. If that fails too, fall back to the file's modification time

Whichever source provides the date, the tool writes it into all the standard EXIF timestamp fields (`DateTimeOriginal`, `CreateDate`, `ModifyDate`) along with timezone offsets. This means downstream tools always have complete date and time metadata to work with.

**Rename to canonical format.** Once every file has a valid date, it gets renamed to `YYYYMMDD_HHMMSS.ext`. Files that already match this pattern are skipped.

A typical normalization looks like this:

```bash
# Always preview first
media-normalize --dry-run --recursive ~/Downloads/phone-backup

# If the preview looks right, run it for real
media-normalize --recursive ~/Downloads/phone-backup
```

There's also a `--date` rescue flag for harder situations — say you have a batch of scanned photos where the dates are completely wrong. You can force-set a date on the entire batch:

```bash
media-normalize --date "2019-06-15 10:00:00" ~/Downloads/old-scans
```

This sets the oldest file (by modification time) to the given date and shifts all other files relative to it, keeping the order in which they were originally created. It's a lifesaver for photo rescue operations.

### Step 2: Import

Once files are normalized, `media-import` moves or copies them into the date-based directory tree:

```bash
# Preview the import
media-import --dry-run ~/Downloads/phone-backup

# Move files into the library (deletes originals after successful copy)
media-import --move ~/Downloads/phone-backup

# Or copy if you want to keep the originals
media-import ~/Downloads/phone-backup
```

The tool reads each file's `CreateDate` and places it into `$MEDIA_HOME/All/YYYY/MM/`. If any files still lack dates at this point (unlikely after normalization, but possible), it fills them from modification time before importing.

The `--move` flag is what I use most — once files are in the library, I don't need the originals in my Downloads folder. The default copy mode is there for when you want to be extra careful.

## Fitting It Into Nix

I manage my system configuration with [Nix](https://nixos.org/), and these tools fit well into that setup. The scripts are packaged as a Nix derivation that bundles them with their runtime dependencies — `exiftool`, `coreutils`, and `findutils` — so there's nothing to install separately.

On top of the package, there's a small home-manager module:

```nix
{
  media.tools = {
    enable = true;
    mediaHome = "${config.home.homeDirectory}/Pictures/Photo";
  };
}
```

When enabled, it adds `media-normalize` and `media-import` to the system PATH and sets the `MEDIA_HOME` environment variable. No manual setup, no forgetting to export a variable in your shell config.

This module is part of a wider `media` role that also pulls in VLC, Shotwell, and other media-related software. Enabling the role on any machine gives you the complete media toolkit — declarative and reproducible.

The practical benefit is consistency. Whether I'm on my laptop or a desktop, the tools are identical, the paths are the same, and the workflow doesn't change. When I set up a new machine, media management is one `enable = true` away.

## The Payoff

This setup has been running for a while now, and the daily experience is remarkably low-friction:

- **Backups are trivial.** `rsync` the `$MEDIA_HOME/All/` tree to an external drive or remote server. The date-based structure means incremental backups are fast — only new months have new files.
- **Google Photos handles the fun part.** Albums, sharing, search, AI-powered "remember this day" features — all working on top of files with clean, reliable metadata.
- **No more lost dates.** Every file has complete EXIF timestamps, including timezone offsets. Nothing gets filed under January 1, 1970.
- **Finding files is predictable.** If you know roughly when a photo was taken, you know exactly where to look in the filesystem.

The specific tools don't matter as much as the philosophy. You could implement the same approach with a shell script and `exiftool`, or with any number of existing media management tools. The key idea is just this: let the filesystem be a simple, reliable, date-sorted archive, and let dedicated software handle everything else.
