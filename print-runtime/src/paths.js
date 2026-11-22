'use strict';

const path = require('node:path');

/**
 * 应用根目录：
 * - 安装包/启动器：环境变量 LVPAI_PRINT_APP_ROOT（exe 旁挂 config 与 scripts）
 * - pkg 单文件：exe 所在目录
 * - 开发：仓库内 print-runtime/
 */
function appRoot() {
  if (process.env.LVPAI_PRINT_APP_ROOT) {
    return path.resolve(process.env.LVPAI_PRINT_APP_ROOT);
  }
  if (process.pkg) {
    return path.dirname(process.execPath);
  }
  return path.resolve(__dirname, '..');
}

module.exports = { appRoot };
