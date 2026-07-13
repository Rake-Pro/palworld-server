FROM ghcr.io/rake-pro/steamcmd-base:latest

LABEL name="rake-pro/palworld-server"

# WineHQ package version for Debian bookworm (winehq-stable). Bump
# deliberately: the server runs the WINDOWS build under this wine.
ARG WINE_VERSION=11.0.0.0~bookworm-1

# Root only for the apt layers - runtime user stays steam.
USER root

# House lesson: bookworm-slim base layers go stale; without an upgrade pass
# old gnutls/openssl CRITICALs fail the Trivy gate.
RUN apt-get update && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      unzip \
      xvfb \
      winbind \
      cabextract \
      winetricks \
 && rm -rf /var/lib/apt/lists/*

# WineHQ repo (deb822 .sources file per the official install docs; i386 arch
# is already enabled by the base image). winehq-stable is installed WITH
# recommends on purpose: wine-stable only Recommends the i386 half, and wine
# needs it to build a working prefix.
RUN mkdir -pm755 /etc/apt/keyrings \
 && curl -fsSL https://dl.winehq.org/wine-builds/winehq.key \
      -o /etc/apt/keyrings/winehq-archive.key \
 && curl -fsSL https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
      -o /etc/apt/sources.list.d/winehq-bookworm.sources \
 && apt-get update \
 && apt-get install -y --install-recommends "winehq-stable=${WINE_VERSION}" \
 && rm -rf /var/lib/apt/lists/*

# Palworld dedicated server app id (Windows depot pulled via
# +@sSteamCmdForcePlatformType windows in init.sh)
ENV STEAMAPPID=2394010 \
    INSTALL_DIR=/palworld \
    SKIPUPDATE=false \
    SERVER_NAME="Palworld Server" \
    SERVER_DESCRIPTION="" \
    MAX_PLAYERS=32 \
    SERVER_PASSWORD="" \
    GAME_PORT=8211 \
    QUERY_PORT=27015 \
    PUBLIC_LOBBY=false \
    PUBLIC_IP="" \
    PUBLIC_PORT="" \
    RESTAPI_ENABLED=true \
    RESTAPI_PORT=8212 \
    ENABLE_INVADER_ENEMY=true \
    UE4SS_ENABLED=true \
    UE4SS_VERSION=experimental-palworld \
    UE4SS_FORCE_REINSTALL=false \
    MODS="" \
    UE4SS_MODS="" \
    WINEPREFIX=/palworld/.wine \
    DISPLAY=:99

COPY --chown=steam:steam ./scripts /home/steam/server/

RUN chmod +x /home/steam/server/*.sh \
 && mkdir -p /palworld \
 && chown -R steam:steam /palworld

WORKDIR /home/steam/server

# The Windows build's server process under wine is
# PalServer-Win64-Shipping-Cmd.exe; match on the stable prefix.
HEALTHCHECK --start-period=20m \
            CMD pgrep -f PalServer-Win64 > /dev/null || exit 1

USER steam

ENTRYPOINT ["/home/steam/server/init.sh"]
