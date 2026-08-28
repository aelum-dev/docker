FROM archlinux:latest

# Static build toolchain for the Aelum ISO pipeline.
# Installed once and cached by Docker across builds; only re-pulled when the
# base tag updates or this layer is edited. Per-run work (clones, the offline
# cache download, AUR builds) stays in build.sh, not here.

RUN pacman -Syu --noconfirm \
    && pacman -S --noconfirm \
        git base-devel archiso \
        go nodejs-lts-jod npm \
        gtk3 webkit2gtk-4.1 libsoup3 \
        grub memtest86+ \
    && pacman -Sc --noconfirm

WORKDIR /app
