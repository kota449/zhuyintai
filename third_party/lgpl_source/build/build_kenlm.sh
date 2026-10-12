#!/usr/bin/env bash
# 從本包的 KenLM 查詢碼＋bridge 重建 libKenLMQuery.dylib。
# Rebuild libKenLMQuery.dylib from the KenLM query sources + bridge in this package.
#
# 用法 / usage:   bash build/build_kenlm.sh [輸出目錄 / output dir，預設 ./out]
# 產出 / output:  <輸出目錄>/libKenLMQuery.dylib （install_name = @rpath/libKenLMQuery.dylib）
#
# 旗標與出貨版逐項相同，**一個都不能變** / flags are identical to the shipped build, do not change:
#   -std=c++14 -stdlib=libc++ -O2 -DNDEBUG=1 -DKENLM_MAX_ORDER=6 -fno-common -fvisibility-inlines-hidden -fpascal-strings
#   （取自 Xcode Release 建置的實際 clang 指令；KENLM_MAX_ORDER 與 bridge 不一致會無聲地算錯分數）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$HERE/out}"
SRC="$HERE/Vendor/KenLMQuerySource"
mkdir -p "$OUT/obj"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CXXFLAGS=(-std=c++14 -stdlib=libc++ -O2 -DNDEBUG=1 -DKENLM_MAX_ORDER=6 -fno-common -fvisibility-inlines-hidden -fpascal-strings -fPIC -isysroot "$SDK" -target arm64-apple-macosx14.0 -I"$SRC")

SOURCES=(
  util/double-conversion/bignum-dtoa.cc util/double-conversion/bignum.cc util/double-conversion/cached-powers.cc
  util/double-conversion/double-to-string.cc util/double-conversion/fast-dtoa.cc util/double-conversion/fixed-dtoa.cc
  util/double-conversion/string-to-double.cc util/double-conversion/strtod.cc
  util/bit_packing.cc util/ersatz_progress.cc util/exception.cc util/file.cc util/file_piece.cc
  util/float_to_string.cc util/integer_to_string.cc util/mmap.cc util/murmur_hash.cc util/parallel_read.cc
  util/pool.cc util/read_compressed.cc util/scoped.cc util/spaces.cc util/string_piece.cc util/usage_ios_stub.cc
  lm/bhiksha.cc lm/binary_format.cc lm/config.cc lm/lm_exception.cc lm/model.cc lm/quantize.cc lm/read_arpa.cc
  lm/search_hashed.cc lm/search_trie.cc lm/sizes.cc lm/trie.cc lm/trie_sort.cc lm/value_build.cc
  lm/virtual_interface.cc lm/vocab.cc
)
OBJS=()
for f in "${SOURCES[@]}"; do
  o="$OUT/obj/$(echo "$f" | tr '/' '_').o"
  xcrun clang++ "${CXXFLAGS[@]}" -c "$SRC/$f" -o "$o"
  OBJS+=("$o")
done
xcrun clang++ "${CXXFLAGS[@]}" -fobjc-arc -c "$HERE/Shared/KenLMQueryBridge.mm" -o "$OUT/obj/KenLMQueryBridge.o"
OBJS+=("$OUT/obj/KenLMQueryBridge.o")
xcrun clang++ -dynamiclib -target arm64-apple-macosx14.0 -isysroot "$SDK" \
  -install_name @rpath/libKenLMQuery.dylib -framework Foundation -lc++ \
  "${OBJS[@]}" -o "$OUT/libKenLMQuery.dylib"
echo "built $OUT/libKenLMQuery.dylib"
