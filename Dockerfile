# syntax=docker/dockerfile:1.7
#
# RF Online: Golden Age (rf2232) - container images.
#
# One Dockerfile, three targets:
#   gameserver  scratch + the static gameserver binary + data/ and scripts/
#   webserver   scratch + the static webserver binary (the site is embedded in it)
#   tools       alpine + sqlite/mysql clients, the MySQL schema and the stock
#               game content database; runs init, backups, restores, rfassets
#
# The server bundle is passed in as the named build context "bundle"
# (docker-compose.yml points it at RF_BUNDLE_DIR). Only the files COPY'd below
# are read from it: client/, client-gommo/, backups/, logs/, the Windows binaries
# and your live databases never end up in an image.

ARG ALPINE_VERSION=3.20

# ---------------------------------------------------------------------------
# Minimal root filesystem for the scratch images: CA roots (Let's Encrypt, the
# update check), zoneinfo (TZ=...), a writable /tmp and a passwd entry.
# ---------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS rootfs
RUN apk add --no-cache ca-certificates tzdata \
 && mkdir -p /out/etc/ssl/certs /out/usr/share /out/tmp /out/opt/rf2232 \
 && cp /etc/ssl/certs/ca-certificates.crt /out/etc/ssl/certs/ \
 && cp -r /usr/share/zoneinfo /out/usr/share/ \
 && printf 'root:x:0:0:root:/root:/sbin/nologin\nrf2232:x:1000:1000:rf2232:/tmp:/sbin/nologin\n' > /out/etc/passwd \
 && printf 'root:x:0:\nrf2232:x:1000:\n' > /out/etc/group \
 && chmod 1777 /out/tmp

# ---------------------------------------------------------------------------
FROM scratch AS gameserver
COPY --from=rootfs /out/ /
COPY --from=bundle --chmod=0755 server/linux/gameserver /opt/rf2232/server/linux/gameserver
COPY --from=bundle data/    /opt/rf2232/data/
COPY --from=bundle scripts/ /opt/rf2232/scripts/
ENV TZ=UTC HOME=/tmp
WORKDIR /opt/rf2232
USER 1000:1000
# 27800 game client socket, 27801 launcher. 29913 (stats) is loopback only.
EXPOSE 27800/tcp 27801/tcp
STOPSIGNAL SIGTERM
ENTRYPOINT ["/opt/rf2232/server/linux/gameserver"]

# ---------------------------------------------------------------------------
FROM scratch AS webserver
COPY --from=rootfs /out/ /
COPY --from=bundle --chmod=0755 server/linux/webserver /opt/rf2232/server/linux/webserver
ENV TZ=UTC HOME=/tmp
WORKDIR /opt/rf2232
USER 1000:1000
EXPOSE 8080/tcp 80/tcp 443/tcp
STOPSIGNAL SIGTERM
ENTRYPOINT ["/opt/rf2232/server/linux/webserver"]
CMD ["-http", ":8080"]

# ---------------------------------------------------------------------------
# Only three MariaDB client binaries are needed; the mariadb-client package
# drags in perl (~40 MB) for scripts we never run, so copy them out instead.
FROM alpine:${ALPINE_VERSION} AS mariadb-client
RUN apk add --no-cache mariadb-client mariadb-connector-c \
 && mkdir -p /out/usr/bin /out/usr/lib /out/usr/share \
 && cp /usr/bin/mariadb /usr/bin/mariadb-dump /usr/bin/mariadb-admin /out/usr/bin/ \
 && cp -r /usr/lib/mariadb /out/usr/lib/ \
 && cp -r /usr/share/mariadb /out/usr/share/

# The stock game content database, stored compressed (189 MB -> ~48 MB).
FROM alpine:${ALPINE_VERSION} AS seed
COPY --from=bundle db/gamedata_rf2232.db /seed/gamedata_rf2232.db
RUN gzip -6 /seed/gamedata_rf2232.db

FROM alpine:${ALPINE_VERSION} AS tools
RUN apk add --no-cache bash coreutils findutils gzip tzdata ca-certificates \
        sqlite libssl3 libcrypto3 zlib ncurses-libs libstdc++ libgcc
COPY --from=mariadb-client /out/ /
COPY --from=bundle --chmod=0755 server/linux/rfassets server/linux/manifgen /usr/local/bin/
COPY --from=bundle database-mysql/                /opt/rf2232-seed/database-mysql/
COPY --from=bundle settings/settings.cfg.example  /opt/rf2232-seed/settings.cfg.example
COPY --from=seed   /seed/gamedata_rf2232.db.gz    /opt/rf2232-seed/db/gamedata_rf2232.db.gz
COPY --chmod=0755 tools/rf-tools.sh /usr/local/bin/rf-tools
ENV TZ=UTC RF_ROOT=/opt/rf2232
WORKDIR /opt/rf2232
ENTRYPOINT ["/usr/local/bin/rf-tools"]
CMD ["help"]
