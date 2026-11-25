#!/bin/bash
# CUPS 受理返回 0，提交失败返回 1，送打前验证失败返回 2。
set -u
export LC_ALL=C
export CUPS_SERVER=/private/var/run/cupsd

File=""
Printer=""
Copies="1"
Kind="ORIGINAL"

while [[ $# -gt 0 ]]; do
  if [[ $# -lt 2 ]]; then
    echo "缺少参数值：$1" >&2
    exit 2
  fi
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

dpi="${LVPAI_PRINT_DPI:-300}"
if ! [[ "$dpi" =~ ^[1-9][0-9]{1,3}$ ]] || (( dpi < 72 || dpi > 1200 )); then
  echo "打印分辨率须为 72–1200 DPI 的整数" >&2
  exit 2
fi

if [[ -z "$Printer" ]]; then
  default_printer="$(/usr/bin/lpstat -d 2>/dev/null)"
  if [[ "$default_printer" = 'system default destination: '* ]]; then
    Printer="${default_printer#system default destination: }"
  fi
fi
if [[ -z "$Printer" ]] || ! /usr/bin/lpstat -p "$Printer" >/dev/null 2>&1; then
  echo "打印机不可用：${Printer:-未设置默认队列}" >&2
  exit 2
fi

select_ppd_media() {
  local line choice borderless=""
  local -a choices
  shopt -s nocasematch
  while IFS= read -r line; do
    [[ "$line" = PageSize/*:* || "$line" = PageSize:* ]] || continue
    read -r -a choices <<< "${line#*:}"
    [[ -n "${choices[0]:-}" ]] || continue
    for choice in "${choices[@]}"; do
      choice="${choice#\*}"
      case "$choice" in
        4x6|4x6in|Photo4x6|w288h432|101.6x152.4mm|102x152mm|na_index-4x6_4x6in)
          printf '%s\n' "$choice"
          return
          ;;
        4x6.Borderless|4x6.FullBleed|4x6.Borderless.*|Photo4x6.Borderless|w288h432.Borderless|w288h432.FullBleed)
          borderless="$choice"
          ;;
      esac
    done
  done
  [[ -n "$borderless" ]] && printf '%s\n' "$borderless"
}

# 优先使用驱动公布的 PageSize，只有无 PPD 纸型匹配时才查询 IPP。
if paper="$(/usr/bin/lpoptions -p "$Printer" -l 2>/dev/null | select_ppd_media)"; then
  paper_args=(-o "PageSize=$paper" -o "media=$paper")
elif [[ -n "${LVPAI_PRINT_NODE:-}" ]] &&
     paper="$("$LVPAI_PRINT_NODE" "$(dirname "${BASH_SOURCE[0]}")/../src/mac-printer.js" --photo-media "$Printer")" &&
     [[ -n "$paper" ]]; then
  paper_args=(-o "media=$paper")
else
  echo "无法为打印队列 $Printer 选择 6 寸纸（4×6 英寸），请核对驱动和队列纸型" >&2
  exit 2
fi

width=""
height=""
exif_orientation=""
if ! image_info="$(/usr/bin/sips -g pixelWidth -g pixelHeight -g orientation "$File" 2>/dev/null)" &&
   ! image_info="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$File" 2>/dev/null)"; then
  echo "无法读取待打印图片的尺寸：$File" >&2
  exit 2
fi
while read -r property value; do
  case "$property" in
    pixelWidth:) width="$value" ;;
    pixelHeight:) height="$value" ;;
    orientation:) exif_orientation="$value" ;;
  esac
done <<< "$image_info"
if ! [[ "$width" =~ ^[1-9][0-9]{0,8}$ && "$height" =~ ^[1-9][0-9]{0,8}$ ]]; then
  echo "无法读取待打印图片的尺寸：$File" >&2
  exit 2
fi
if [[ "$exif_orientation" = [5-8] ]]; then
  stored_width="$width"
  width="$height"
  height="$stored_width"
fi
orientation=3
if (( width > height )); then orientation=4; fi

# 旧 CUPS 图像过滤器使用 fit-to-page 或 scaling，IPP 路径使用 print-scaling。
lp_args=(-d "$Printer" -n "$Copies" -t "${LVPAI_PRINT_DOCUMENT_NAME:-lvpai-$Kind}"
  "${paper_args[@]}" -o "orientation-requested=$orientation"
  -o print-scaling=fit -o fit-to-page -o scaling=100 -o position=center -o "printer-resolution=${dpi}dpi")

# 将 lp 的作业编号留在 stdout，供 Node 逐张跟踪。
if ! /usr/bin/lp "${lp_args[@]}" "$File"; then
  echo "打印系统未受理：$Kind" >&2
  exit 1
fi
