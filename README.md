# palworld-server

Palworld dedicated server image. Built on the shared
`ghcr.io/rake-pro/steamcmd-base` image and runs entirely as the nonroot
`steam` user. Runs the **Windows** server build under Wine so the mainstream
Windows UE4SS mod loader works, with declarative pak-mod and UE4SS-mod
install. Published to GitHub Container Registry:

```
ghcr.io/rake-pro/palworld-server
```

## Tags / releases

CI (`.github/workflows/build.yml`) versions the image as semver:

- Every push to `main` mints a patch-bumped `vX.Y.Z` git tag (`#major` /
  `#minor` in the commit message bump those segments) and pushes
  `vX.Y.Z` + `latest` to GHCR. No `sha-` tags on main builds.
- The version tag and the image push happen only after the Trivy scan gate
  passes (blocking on fixable CRITICALs; a HIGH+CRITICAL report also runs,
  non-blocking).
- PR builds are build+scan only (short-sha tag, never pushed).
- Pin `vX.Y.Z` in deployments; `latest` is a convenience pointer.

## Run

```
docker run -d --name palworld \
  -p 8211:8211/udp -p 27015:27015/udp -p 8212:8212/tcp \
  -e SERVER_NAME="My Palworld Server" \
  -e ADMIN_PASSWORD=<set-your-own-password> \
  -e MAX_PLAYERS=32 \
  -v /path/to/data:/palworld \
  ghcr.io/rake-pro/palworld-server:latest
```

On boot the container initializes a Wine prefix at `/palworld/.wine` if
missing (one-time `wineboot` + `vcrun2022`), installs/updates the Palworld
**Windows** build via SteamCMD (app id `2394010`, forced Windows platform)
unless `SKIPUPDATE=true`, seeds and patches `PalWorldSettings.ini` from the
environment, installs UE4SS and any declared mods, then launches
`PalServer-Win64-Shipping-Cmd.exe` under Wine (a minimal Xvfb display is
started for Wine; the server itself is headless).

`ADMIN_PASSWORD` is required and has no default - it is the in-game admin
password and the HTTP basic-auth secret for the REST API. The container
exits with an error at boot if it is unset.

Config values you set by hand in `PalWorldSettings.ini` are preserved: the
init script only rewrites the keys it manages (see below) inside the
`OptionSettings=(...)` line and leaves every other key untouched.

## Configuration

| Variable | Default | Required | Purpose |
| --- | --- | --- | --- |
| `SKIPUPDATE` | `false` | | Skip the SteamCMD update on boot (still installs if the server binary is missing). |
| `SERVER_NAME` | `Palworld Server` | | Public server name (`ServerName`). |
| `SERVER_DESCRIPTION` | (empty) | | Server description (`ServerDescription`). |
| `ADMIN_PASSWORD` | (none) | **yes** | Admin + REST API password (`AdminPassword`). No default. |
| `SERVER_PASSWORD` | (empty) | | Join password (`ServerPassword`); empty = no password. |
| `MAX_PLAYERS` | `32` | | Player cap (`ServerPlayerMaxNum`, also `-players`). |
| `GAME_PORT` | `8211` | | Game port (`-port`, also seeds `PublicPort` when `PUBLIC_PORT` is empty). |
| `QUERY_PORT` | `27015` | | Steam query port (`-queryport`). |
| `PUBLIC_LOBBY` | `false` | | Register on the community server list (`-publiclobby`). |
| `PUBLIC_IP` | (empty) | | Advertised public IP (`PublicIP` + `-publicip`). |
| `PUBLIC_PORT` | (empty) | | Advertised public port (`PublicPort` + `-publicport`); empty = `GAME_PORT`. |
| `RESTAPI_ENABLED` | `true` | | Enable the REST admin API (`RESTAPIEnabled`). HTTP basic auth with `ADMIN_PASSWORD`; plain HTTP, LAN-only by design - do not expose it to the internet. |
| `RESTAPI_PORT` | `8212` | | REST API port (`RESTAPIPort`). |
| `ENABLE_INVADER_ENEMY` | `true` | | `bEnableInvaderEnemy` passthrough. Community reports disabling it roughly halves the server's memory-leak growth. |
| `UE4SS_ENABLED` | `true` | | Install/upgrade UE4SS at boot. |
| `UE4SS_VERSION` | `experimental-palworld` | | Okaetsu/RE-UE4SS release tag to install. This fork publishes a single rolling tag; see UE4SS below. |
| `UE4SS_FORCE_REINSTALL` | `false` | | When `true`, re-download and re-extract UE4SS on boot regardless of the install marker (use for one boot to refresh the rolling tag), then revert to `false`. |
| `MODS` | (empty) | | Declarative pak mod list, see Mods. |
| `UE4SS_MODS` | (empty) | | Declarative UE4SS mod list, see Mods. |
| `PALSCHEMA_MODS` | (empty) | | Declarative PalSchema sub-mod list, see Mods. |
| `WINEPREFIX` | `/palworld/.wine` | | Wine prefix location (on the persistent volume). |

RCON is deprecated upstream in favor of the REST API; this image does not
configure or manage it.

## Ports

| Port | Use |
| --- | --- |
| `8211/udp` | Game server. |
| `27015/udp` | Steam query. |
| `8212/tcp` | REST admin API (HTTP basic auth, keep LAN-only). |

## Volumes

| Path | Use |
| --- | --- |
| `/palworld` | PVC mount root: game install, world saves (`Pal/Saved`), config, Wine prefix (`.wine`), and mod install manifests. Persist this whole path. |

## Mods

### Pak mods (`MODS`)

Space-separated `name@url` entries where `url` is a direct `.pak` or `.zip`
download. Each entry installs into `Pal/Content/Paks/~mods/<name>/` (the
community convention). Prefix an entry with `logicmods:` to target
`Pal/Content/Paks/LogicMods/<name>/` (the official location) instead:

```
-e MODS="somemod@https://example.com/somemod.pak logicmods:othermod@https://example.com/othermod.zip"
```

Reconciliation is declarative: entries removed from `MODS` are uninstalled
on the next boot. The script tracks what it installed in
`/palworld/.mods-manifest` and only ever deletes directories listed there -
mods you install by hand are never touched.

### UE4SS

When `UE4SS_ENABLED=true` (default) the init script downloads the
`UE4SS-Palworld.zip` asset from the `UE4SS_VERSION` release of
[Okaetsu/RE-UE4SS](https://github.com/Okaetsu/RE-UE4SS) (the maintained
Palworld fork) and extracts it into `Pal/Binaries/Win64/` (the `dwmapi.dll`
proxy plus the `ue4ss/` folder).

The fork publishes exactly one release tag, `experimental-palworld` (the
`UE4SS_VERSION` default). It is a **rolling** tag: the maintainer rebuilds the
`UE4SS-Palworld.zip` asset in place as Palworld updates, so the tag string
never changes while the bytes do. Because of that the image installs UE4SS
**once** onto the persistent volume (recorded by a marker file) and then never
auto-updates it - not even across image releases. Bumping `UE4SS_VERSION`
alone does **not** refresh UE4SS (there is no newer tag to move to).

**Game updates can break UE4SS** until the maintainer rebuilds that asset.
When a Palworld patch lands and modded startup crashes, refresh UE4SS one of
two ways:

- Set `UE4SS_FORCE_REINSTALL=true` for a single boot (in the chart: set the
  env, sync, let it boot, then revert to `false`). This re-downloads and
  re-extracts the rolling asset regardless of the marker.
- Or delete `Pal/Binaries/Win64/.ue4ss-version` on the volume and restart; the
  missing marker triggers a fresh install.

If you would rather ride out the break unmodded, set `UE4SS_ENABLED=false`
(and/or `SKIPUPDATE=true` to hold the game version) until the asset is
rebuilt.

### UE4SS mods (`UE4SS_MODS`)

Space-separated `name@url` entries where `url` is a zip, extracted into
`Pal/Binaries/Win64/ue4ss/Mods/<name>/`. Same manifest-based declarative
reconcile as `MODS` (manifest: `/palworld/.ue4ss-mods-manifest`). Example,
installing PalSchema:

```
-e UE4SS_MODS="PalSchema@https://github.com/PalSchema/PalSchema/releases/download/<version>/PalSchema.zip"
```

Requires `UE4SS_ENABLED=true`; if UE4SS is disabled, `UE4SS_MODS` is
ignored with a warning.

### PalSchema sub-mods (`PALSCHEMA_MODS`)

[PalSchema](https://github.com/PalSchema/PalSchema) is itself a UE4SS mod
(install it via `UE4SS_MODS`, see above); it in turn loads its own sub-mods
from `Pal/Binaries/Win64/ue4ss/Mods/PalSchema/mods/`. `PALSCHEMA_MODS` is a
third, independent declarative list for those sub-mods, same `name@url`
zip format and same manifest-based reconcile as `MODS`/`UE4SS_MODS`
(manifest: `/palworld/.palschema-mods-manifest`). The sub-mod zip must
contain the mod folder's contents directly (they are extracted into
`<name>/`, not `<name>/<name>/`).

Example, installing PalSchema itself plus one of its sub-mods:

```
-e UE4SS_MODS="PalSchema@https://example.invalid/PalSchema.zip" \
-e PALSCHEMA_MODS="SomeSchemaMod@https://example.invalid/SomeSchemaMod.zip"
```

Reconciled after `UE4SS_MODS` on every boot. If `PALSCHEMA_MODS` is set but
PalSchema itself is not installed (missing from `UE4SS_MODS` or not yet
downloaded), the init script logs a warning and still installs the sub-mod
files - they are inert until PalSchema is present, so this is safe to leave
declared ahead of adding PalSchema.

Like `UE4SS_MODS`, this requires `UE4SS_ENABLED=true`.
