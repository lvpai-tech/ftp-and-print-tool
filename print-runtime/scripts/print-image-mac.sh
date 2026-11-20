#!/bin/bash
# 工作台出图：把图片交给 macOS 打印系统（CUPS）。
# 退出码 0 才表示打印机已受理。版式沿用系统等比铺满，不假定纸张规格。
set -u

File=""
Printer=""
Copies="1"
Kind="ORIGINAL"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -File)
      File="${2-}"
      shift 2
      ;;
    -Printer)
      Printer="${2-}"
      shift 2
      ;;
    -Copies)
      Copies="${2-}"
      shift 2
      ;;
    -Kind)
      Kind="${2-}"
      shift 2
      ;;
    *)
      echo "未知参数：$1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$File" || ! -f "$File" ]]; then
  echo "图片不存在：$File" >&2
  exit 2
fi

if ! [[ "$Copies" =~ ^[1-9][0-9]*$ ]]; then
  echo "份数必须是正整数：$Copies" >&2
  exit 2
fi

lp_args=(-n "$Copies" -t "lvpai-$Kind" -o fit-to-page)
if [[ -n "$Printer" ]]; then
  if ! /usr/bin/lpstat -p "$Printer" >/dev/null 2>&1; then
    echo "打印机不可用：$Printer" >&2
    exit 1
  fi
  lp_args=(-d "$Printer" "${lp_args[@]}")
fi

if ! /usr/bin/lp "${lp_args[@]}" "$File"; then
  echo "打印系统未受理：$Kind" >&2
  exit 1
fi
