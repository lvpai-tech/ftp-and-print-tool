/// 把操作员选中的墙钟时间写成打印任务查询用的上海时间。
///
/// 使用年月日时分秒的数字本身，并固定标注 `+08:00`。
/// 不经过本机时区换算，避免工作台系统时区不是上海时把 9:30 送成别的钟点。
String shanghaiDateTime(DateTime wall) {
  String two(int value) => value.toString().padLeft(2, '0');
  final year = wall.year.toString().padLeft(4, '0');
  return '$year-${two(wall.month)}-${two(wall.day)}'
      'T${two(wall.hour)}:${two(wall.minute)}:${two(wall.second)}+08:00';
}

/// 按钮上展示的墙钟时间，与 [shanghaiDateTime] 使用同一组数字。
String formatWallClock(DateTime wall) {
  String two(int value) => value.toString().padLeft(2, '0');
  final year = wall.year.toString().padLeft(4, '0');
  return '$year-${two(wall.month)}-${two(wall.day)} '
      '${two(wall.hour)}:${two(wall.minute)}:${two(wall.second)}';
}
