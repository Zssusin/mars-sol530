# Mars sol 530 (mars-realtime-drive)

Drive the Perseverance rover in real time at its actual parking spot on sol 530, at the front of the Jezero crater delta. The terrain, ground materials, rocks and sky are rebuilt from public NASA data. Built with a custom build of Godot 4.7.2 and a C++ extension.

Not an official NASA / JPL product, and not endorsed by either. Data and imagery: NASA/JPL-Caltech/ASU/MSSS/University of Arizona/USGS.

[中文说明](README.md) · The source code, comments and design documents in this repository are written in Chinese. The game itself has an English interface.

## What is in it

- **The real place.** Orbital terrain from HiRISE (1 m elevation, 25 cm imagery) and CTX, refined around the rover with meshes from Perseverance's own Navcam.
- **Free roaming and photography.** A photo mode, an album, and 11 real science targets with guide cards and the photos NASA took of them.
- **Recreate NASA photos.** Pick a real Navcam photo, drive to where it was taken, match the framing, and get a score.
- **Sol planning.** Receive the morning downlink, place waypoints on the planning map, rehearse the drive, then run it and read the end-of-sol report.
- **Time of day.** Sunrise to sunset (05:21–17:26 local time), with sky and lighting computed for the Martian atmosphere.
- **Full-screen map** with the rover's actual route from sol 0 to sol 530.

## Requirements

- Linux x86_64, Windows 10 / 11 x86_64, or macOS 14+ on Apple silicon.
- On Linux and Windows: a discrete GPU with Vulkan support.
- 8 GB of video memory. The default settings are tuned for a mid-range discrete GPU at 2560×1440. On smaller cards, pick a lower quality preset in Settings.
- About 5 GB of disk space.

Only the Linux build is run-tested for each release. The Windows and macOS packages are built from the same code but are not run before release. Please report what you find.

## Download

Get two things from the [Releases page](https://github.com/Zssusin/mars-sol530/releases):

1. **One program package** for your system:
   - Linux: `…-linux-compat-x86_64.tar.zst` or `….AppImage` (either one)
   - Windows: `…-windows-x86_64.zip`
   - macOS: `…-macos-arm64.zip`
2. **All parts of the data package**: `mars-realtime-drive-data-<data version>-1of3.zip`, `-2of3.zip` and `-3of3.zip`. All three systems use the same data.

Each data part unpacks into a folder named `data`. Unpack them all into the same place and they merge. The `data` folder must sit next to the program. If it is missing or incomplete, the game shows a page that says what is missing and where to put it.

When the program is updated, the data often stays the same. If the data version in the file name has not changed, you do not need to download it again.

## Install

Run these commands in the folder that holds the downloaded files.

**Linux, tar.zst**

```sh
tar --zstd -xf mars-realtime-drive-<version>-linux-compat-x86_64.tar.zst
cd mars-realtime-drive-<version>-linux-compat
for f in ../mars-realtime-drive-data-*.zip; do unzip -oq "$f"; done
./mars-realtime-drive.x86_64
```

**Linux, AppImage**

```sh
chmod +x mars-realtime-drive-<version>-linux-compat-x86_64.AppImage
for f in mars-realtime-drive-data-*.zip; do unzip -oq "$f"; done
./mars-realtime-drive-<version>-linux-compat-x86_64.AppImage
```

The `data` folder goes next to the AppImage file, not inside it.

**Windows (PowerShell)**

```powershell
Expand-Archive mars-realtime-drive-<version>-windows-x86_64.zip -DestinationPath .
cd mars-realtime-drive-<version>-windows
Get-ChildItem ..\mars-realtime-drive-data-*.zip | ForEach-Object { Expand-Archive -LiteralPath $_.FullName -DestinationPath . -Force }
.\mars-realtime-drive.exe
```

The program is not code-signed. SmartScreen will warn you: choose "More info", then "Run anyway".

**macOS (Terminal)**

```sh
ditto -xk mars-realtime-drive-<version>-macos-arm64.zip .
cd mars-realtime-drive-<version>-macos
for f in ../mars-realtime-drive-data-*.zip; do ditto -xk "$f" .; done
xattr -dr com.apple.quarantine mars-realtime-drive.app
open mars-realtime-drive.app
```

Do not double-click the data parts in Finder: it unpacks them into `data`, `data 2`, `data 3`. The app is not notarized, so the `xattr` line is required. Without it, macOS runs the app from a temporary location where it cannot see the `data` folder.

**Data somewhere else.** Set the environment variable `MARS_DATA=<path to the data folder>`.

The first launch loads a lot of data and takes ten seconds or more.

## Language

On first launch the game follows your system language: Chinese on a Chinese system, English otherwise. You can change it under Settings → Language. To force English from the command line:

```sh
./mars-realtime-drive.x86_64 -- --语言=en
```

Command-line options and log output are in Chinese.

## Controls

| Key | Action |
|---|---|
| F1 | Show all controls |
| H | Cycle the interface: minimal, full, off |
| C | Enter or leave photo mode |
| Tab | Album and challenges |
| M | Full-screen map |
| F2 | Sol planning |
| Esc | Release the mouse; press again for the pause menu |
| F3 | Performance readout and version number |
| F12 | Screenshot |

## Known issues

- From high up, distant ground textures still show some repetition.
- Near the rover, the ground can show stretched streaks from some angles, because the source photos were all taken from the rover's mast.
- On exit, the terminal may print "resources still in use". It is harmless.
- The page shown when data is missing is in Chinese only.

When you report a problem, include the version number shown by F3 and the terminal output.

## Building from source

Building needs the custom engine (see `engine/README.md`), the C++ extension, and scene data produced by the data pipeline from raw NASA products that are not in this repository. The steps are described in Chinese in [README.md](README.md) and `scripts/Blender/实景地形系统.md`. For playing, use the release packages.

Design and research documents are not published. Where code comments mention other `docs/…` files, those files are not in this repository.

## License

- Code (GDScript, shaders, C++, Python, shell): MIT, see `LICENSE`.
- Documentation and images made by this project: CC BY 4.0, see `docs/LICENSE.md`.
- Engine, fonts, sounds, NASA data and the rover model: sources and rights are listed in `THIRD_PARTY.md`.
- The NASA insignia, logotype and JPL logo on the rover model's textures are not covered by the licenses above. See `THIRD_PARTY.md`, section 5.
