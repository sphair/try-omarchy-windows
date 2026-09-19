#!/usr/bin/env bash
set -euo pipefail

output=$1
sysroot=/usr/x86_64-w64-mingw32/sys-root/mingw
mkdir -p /work "$sysroot/include/virgl" "$sysroot/lib/pkgconfig"

cp /winq/libvirglrenderer-1.dll "$sysroot/bin/"
gendef /winq/libvirglrenderer-1.dll
x86_64-w64-mingw32-dlltool -d libvirglrenderer-1.def -l "$sysroot/lib/libvirglrenderer.dll.a"

git clone --quiet --no-checkout https://github.com/cmspam/winq-emu-virglrenderer.git /work/virglrenderer
git -C /work/virglrenderer checkout --quiet e80354b8f5a0dedc62374b905a181874682659cc
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

git clone --quiet https://gitlab.freedesktop.org/slirp/libslirp.git /work/libslirp
git -C /work/libslirp checkout --quiet 26be815b86e8d49add8c9a8b320239b9594ff03d
meson setup /work/libslirp-build /work/libslirp --cross-file=/usr/share/mingw/toolchain-mingw64.meson --prefix="$sysroot"
meson compile -C /work/libslirp-build
meson install -C /work/libslirp-build

git clone --quiet --no-checkout https://github.com/cmspam/winq-emu-qemu.git /work/qemu
git -C /work/qemu config core.symlinks false
git -C /work/qemu checkout --quiet 2ce303cfbbc8b0e4a7a3c66e27a094a980426d73
for patch in /app/runtime-build/patches/qemu/[0-9][0-9][0-9][0-9]-*.patch; do
    git -C /work/qemu apply --ignore-space-change "$patch"
done

sed -i '/#include "qemu\/cutils.h"/a#include "qemu/error-report.h"' /work/qemu/ui/sdl2.c
sed -i '/static int gui_fullscreen;/a static bool gui_borderless;' /work/qemu/ui/sdl2.c
sed -i '/flags |= SDL_WINDOW_RESIZABLE;/a\        if (gui_borderless) {\n            flags |= SDL_WINDOW_BORDERLESS;\n        }' /work/qemu/ui/sdl2.c
sed -i '/                                         flags);/a\    if (gui_borderless) {\n        SDL_MaximizeWindow(scon->real_window);\n    }' /work/qemu/ui/sdl2.c
perl -0pi -e 's%static void toggle_full_screen\(struct sdl2_console \*scon\)\n\{\n%static void toggle_full_screen(struct sdl2_console *scon)\n{\n    if (gui_borderless) {\n        bool borderless = SDL_GetWindowFlags(scon->real_window) & SDL_WINDOW_BORDERLESS;\n        SDL_SetWindowBordered(scon->real_window, borderless ? SDL_TRUE : SDL_FALSE);\n        if (borderless) {\n            SDL_RestoreWindow(scon->real_window);\n        } else {\n            SDL_MaximizeWindow(scon->real_window);\n        }\n        sdl2_redraw(scon);\n        return;\n    }\n%' /work/qemu/ui/sdl2.c
sed -i '/gui_fullscreen = o->has_full_screen && o->full_screen;/a\    gui_borderless = o->u.sdl.has_borderless && o->u.sdl.borderless;\n    if (gui_fullscreen && gui_borderless) {\n        error_report("full-screen and borderless cannot be used together");\n        exit(1);\n    }' /work/qemu/ui/sdl2.c
sed -i '/#     "G" key to release the mouse grab\./a\#\n# @borderless: Start with window decorations disabled and the window\n#     maximized (default: off).' /work/qemu/qapi/ui.json
sed -i "/'data'    : { '\*grab-mod'   : 'HotKeyMod' } }/c\  'data'    : { '*grab-mod'   : 'HotKeyMod', '*borderless' : 'bool' } }" /work/qemu/qapi/ui.json
grep -q 'has_borderless' /work/qemu/ui/sdl2.c

mkdir /work/build
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
cp "$sysroot/bin"/*.dll "$output/"