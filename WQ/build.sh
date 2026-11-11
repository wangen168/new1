#!/usr/bin/env bash
# 裸 clang 交叉编译（不需要 theos）
set -euo pipefail
SDK="${SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
OUT="${1:-WQCollector.dylib}"

xcrun --sdk iphoneos clang -arch arm64 -dynamiclib \
  -isysroot "$SDK" -miphoneos-version-min=15.0 \
  -fobjc-arc -O2 -Wno-deprecated-declarations \
  -framework Foundation -framework UIKit -framework Security -lz \
  -install_name @executable_path/Frameworks/AppRuntime/WQCollector.dylib \
  -o "$OUT" WQCollector.m worse_query.m

echo "built: $OUT"
echo "下一步："
echo "  python ../../tools/inject.py 名人国际_signready.ipa $OUT 名人国际_wq.ipa"
