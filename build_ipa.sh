#!/bin/bash
# ============================================================================
#  SparkKeeper —— 在 macOS 上一键打出未签名 IPA（给别人自签 / 自己签用）
#
#  用法：
#      ./build_ipa.sh                  # 出未签名 IPA
#      TEAM_ID=ABCDE12345 ./build_ipa.sh signed   # 用本机证书出已签名 IPA
#
#  产物：
#      build/SparkKeeper-unsigned.ipa
#      build/SparkKeeper-signed.ipa   （signed 模式）
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

PROJECT="SparkKeeper.xcodeproj"
SCHEME="SparkKeeper"
CONFIG="Release"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/SparkKeeper.xcarchive"
MODE="${1:-unsigned}"

echo "==> 清理 build/"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------- 已签名模式
if [ "$MODE" = "signed" ]; then
  TEAM_ID="${TEAM_ID:-}"
  if [ -z "$TEAM_ID" ]; then
    echo "!! 出签名 IPA 需要 TEAM_ID，例如：TEAM_ID=ABCDE12345 ./build_ipa.sh signed"
    exit 1
  fi

  echo "==> Archive（自动签名，Team $TEAM_ID）"
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic

  cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>development</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>stripSwiftSymbols</key><true/>
  <key>compileBitcode</key><false/>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

  echo "==> Export"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -allowProvisioningUpdates

  cp "$BUILD_DIR/export/"*.ipa "$BUILD_DIR/SparkKeeper-signed.ipa"
  echo "==> 完成：$BUILD_DIR/SparkKeeper-signed.ipa"
  exit 0
fi

# -------------------------------------------------------------- 未签名模式
echo "==> Archive（跳过签名）"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_BITCODE=NO

APP="$ARCHIVE/Products/Applications/SparkKeeper.app"
if [ ! -d "$APP" ]; then
  echo "!! 没找到 $APP —— 编译失败了，往上翻 xcodebuild 的报错"
  exit 1
fi

echo "==> 组装 Payload"
STAGE="$BUILD_DIR/stage"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
# 未签名包不该带签名残留，去掉交给自签工具重签
rm -rf "$STAGE/Payload/SparkKeeper.app/_CodeSignature"
rm -f  "$STAGE/Payload/SparkKeeper.app/embedded.mobileprovision"

echo "==> 压缩"
( cd "$STAGE" && zip -qry "$BUILD_DIR/SparkKeeper-unsigned.ipa" Payload )

echo "==> 完成：$BUILD_DIR/SparkKeeper-unsigned.ipa"
echo "    丢进 Sideloadly / AltStore / ESign / TrollStore 自签安装即可。"
echo "    详细步骤见 README.md。"
