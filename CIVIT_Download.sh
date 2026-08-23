#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/private-io.sh
source "$SCRIPT_DIR/lib/private-io.sh"
private_io_init

CIVIT_TOKEN=""
private_read_secret CIVIT_TOKEN "Civitai API token" "${CIVIT_API_FD:-}"
trap 'unset CIVIT_TOKEN' EXIT

# 檢查是否至少有一個參數（URL）
if [ $# -lt 1 ]; then
  echo "用法：CIVIT_Download.sh <URL1> [URL2] [URL3] ..."
  echo "範例："
  echo "  CIVIT_Download.sh 'https://civitai.com/api/download/models/1111838?type=Model&format=SafeTensor' \\"
  echo "                     'https://civitai.com/api/download/models/2222222?type=Model&format=SafeTensor'"
  exit 1
fi

# 逐一處理每個引數(URL)
for DOWNLOAD_URL in "$@"; do
  echo "—————"
  echo "開始下載請求"

  escaped_token="${CIVIT_TOKEN//\\/\\\\}"
  escaped_token="${escaped_token//\"/\\\"}"
  if printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$escaped_token" \
      | curl --fail --location --remote-header-name --remote-name --config - -- "$DOWNLOAD_URL"; then
    echo "下載成功！"
  else
    echo "下載失敗。" >&2
  fi
done

echo "全部下載完成。"
