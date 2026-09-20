#!/usr/bin/env bash
set -euo pipefail

output=$1
sysroot=/usr/x86_64-w64-mingw32/sys-root/mingw
mkdir -p /work "$sysroot/include/virgl" "$sysroot/lib/pkgconfig"

cp /winq/libvirglrenderer-1.dll "$sysroot/bin/"
gendef /winq/libvirglrenderer-1.dll
x86_64-w64-mingw32-dlltool -d libvirglrenderer-1.def -l "$sysroot/lib/libvirglrenderer.dll.a"

# /work is normally a persistent Docker volume (see the justfile's
# build-qemu-runtime recipe), so a plain rerun would otherwise still re-clone
# QEMU/virglrenderer/libslirp and reconfigure from scratch every time. Skip
# the whole clone-and-patch section when this script's own content hasn't
# changed since the last run; only `make` runs unconditionally, so it does an
# incremental rebuild instead of a full one. Editing this script (or the
# patches it applies) invalidates the cache automatically.
recipe_hash=$(sha256sum "$0" | cut -d' ' -f1)
recipe_marker=/work/.recipe-hash
if [ -f "$recipe_marker" ] && [ "$(cat "$recipe_marker")" = "$recipe_hash" ]; then
    echo "build-winq-borderless-docker: reusing cached /work source tree"
    cached_source=1
else
    echo "build-winq-borderless-docker: recipe changed (or no cache); rebuilding source tree from scratch"
    rm -rf /work/qemu /work/virglrenderer /work/libslirp /work/libslirp-build /work/build
    cached_source=0
fi

if [ "$cached_source" = "0" ]; then
    git clone --quiet --no-checkout https://github.com/cmspam/winq-emu-virglrenderer.git /work/virglrenderer
    git -C /work/virglrenderer checkout --quiet e80354b8f5a0dedc62374b905a181874682659cc
fi
cp /work/virglrenderer/src/virglrenderer.h "$sysroot/include/virgl/"
sed -e 's/@VIRGL_MAJOR_VERSION@/1/g' -e 's/@VIRGL_MINOR_VERSION@/3/g' -e 's/@VIRGL_MICRO_VERSION@/0/g' \
    /work/virglrenderer/src/virgl-version.h.meson > "$sysroot/include/virgl/virgl-version.h"
cat >"$sysroot/lib/pkgconfig/virglrenderer.pc" <<EOF
prefix=$sysroot
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include/virgl

Name: virglrenderer
Description: Virtual GPU renderer
Version: 1.3.0
Libs: -L\${libdir} -lvirglrenderer
Cflags: -I\${includedir}
EOF

if [ "$cached_source" = "0" ]; then
    git clone --quiet https://gitlab.freedesktop.org/slirp/libslirp.git /work/libslirp
    git -C /work/libslirp checkout --quiet 26be815b86e8d49add8c9a8b320239b9594ff03d
    meson setup /work/libslirp-build /work/libslirp --cross-file=/usr/share/mingw/toolchain-mingw64.meson --prefix="$sysroot"
    meson compile -C /work/libslirp-build
    meson install -C /work/libslirp-build
else
    meson install -C /work/libslirp-build
fi

if [ "$cached_source" = "0" ]; then
    git clone --quiet --no-checkout https://github.com/cmspam/winq-emu-qemu.git /work/qemu
    git -C /work/qemu config core.symlinks false
    git -C /work/qemu checkout --quiet 2ce303cfbbc8b0e4a7a3c66e27a094a980426d73
    for patch in /app/runtime-build/patches/qemu/[0-9][0-9][0-9][0-9]-*.patch; do
        git -C /work/qemu apply --ignore-space-change "$patch"
    done
fi

if [ "$cached_source" = "1" ]; then
    mkdir -p /work/build
    pushd /work/build
    make -j8
    popd
    cp /work/build/qemu-system-x86_64.exe /work/build/qemu-img.exe "$output/"
    x86_64-w64-mingw32-objcopy --subsystem windows \
        /work/build/qemu-system-x86_64.exe "$output/qemu-system-x86_64w.exe"
    cp "$sysroot/bin"/*.dll "$output/"
    cp -a /winq/share "$output/"
    exit 0
fi

# The borderless SDL display mode (and the Windows DPI-awareness/blackout/
# multi-monitor/decoration-persistence fixes it depends on) is applied above
# as patches/qemu/0013-add-borderless-sdl-display-mode.patch, alongside the
# other numbered QEMU patches. Sanity-check it actually landed.
grep -q 'has_borderless' /work/qemu/ui/sdl2.c

mkdir -p /work/build
pushd /work/build
../qemu/configure \
    --cross-prefix=x86_64-w64-mingw32- \
    --extra-cflags=-mcrtdll=ucrt \
    --extra-ldflags=-mcrtdll=ucrt \
    --target-list=x86_64-softmmu \
    --enable-whpx \
    --enable-sdl \
    --enable-opengl \
    --enable-virglrenderer \
    --enable-slirp \
    --disable-gtk \
    --disable-docs \
    --disable-plugins
make -j8
popd

cp /work/build/qemu-system-x86_64.exe /work/build/qemu-img.exe "$output/"
x86_64-w64-mingw32-objcopy --subsystem windows \
    /work/build/qemu-system-x86_64.exe "$output/qemu-system-x86_64w.exe"
cp "$sysroot/bin"/*.dll "$output/"
cp -a /winq/share "$output/"

# Only mark the cache valid once the full rebuild has actually succeeded, so a
# failed build never leaves a false-positive marker for the next run.
echo "$recipe_hash" > "$recipe_marker"