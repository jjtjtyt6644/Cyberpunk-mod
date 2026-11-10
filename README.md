# Night City Trainer

A single-player trainer menu for Cyberpunk 2077: money, god mode, infinite ammo, vehicles,
teleport, progression and more, in one in-game menu.

## Install

1. Download `NightCityTrainer.exe` from the [latest release](../../releases/latest).
2. Run it. Windows may show "Windows protected your PC" because the file is not code-signed:
   click **More info**, then **Run anyway**.
3. Press **INSTALL**. The launcher finds your game (Steam, GOG or Epic), downloads
   [Cyber Engine Tweaks](https://github.com/maximegmd/CyberEngineTweaks) if you don't have it,
   and installs the trainer.
4. Press **PLAY**. On the first launch Cyber Engine Tweaks asks you to pick a key. That key
   opens the trainer menu in game.

Open the launcher again any time to get the newest trainer version.

## Notes

- For single-player saves only. Back up your saves before using permanent cheats
  (levels, attributes, unlock all vehicles, achievements).
- Game patches can break individual cheats until the trainer is updated.

## Building from source

`Launcher\build.ps1` builds the launcher with the C# compiler that ships with Windows.
The trainer itself is `NightCityTrainer\init.lua`.

To release a new trainer version: bump `version` at the top of `init.lua`, run `build.ps1`,
then commit and push `dist\init.lua` and `dist\version.json`.
