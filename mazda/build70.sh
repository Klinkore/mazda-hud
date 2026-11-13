#!/bin/bash
# fw70 port: build libpatch-blmjciaapa.so without make (WSL has no make).
# Mirrors the Makefile's RELEASE flags, plus DEBUG-level logs (written to
# /tmp/oem-aa-mod.log on the unit only when the debug flag file exists).
set -e
cd /mnt/d/sandbox/oem-aa-mod/mazda
TC=./m3-toolchain
TRIPLE=arm-cortexa9_neon-linux-gnueabi
CXX=$TC/bin/$TRIPLE-g++
SYSROOT=$TC/$TRIPLE/sysroot
OUT=build/fw70
mkdir -p $OUT/obj

CXXFLAGS="-std=c++11 --sysroot=$SYSROOT -march=armv7-a -mtune=cortex-a9 -mfpu=neon \
 -fPIC -fvisibility=hidden -D_GLIBCXX_USE_CXX11_ABI=0 -Ipatches \
 -O2 -DNDEBUG -DLOG_LEVEL=1 -DFW70_PORT -Wall"
LDFLAGS="--sysroot=$SYSROOT -shared -Wl,--no-undefined -lpthread -ldl -lrt \
 -Wl,-s"

OBJS=""
for src in $(find patches/blmjciaapa -name '*.cpp' | sort); do
  obj=$OUT/obj/$(echo ${src#patches/} | tr '/' '_' | sed 's/\.cpp$/.o/')
  echo "CXX $src"
  $CXX $CXXFLAGS -c "$src" -o "$obj"
  OBJS="$OBJS $obj"
done
echo "LINK libpatch-blmjciaapa.so"
$CXX $OBJS $LDFLAGS -Wl,-soname,libpatch-blmjciaapa.so -o $OUT/libpatch-blmjciaapa.so
ls -la $OUT/libpatch-blmjciaapa.so
