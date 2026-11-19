(function (root) {
  'use strict';
  const ORIGIN = 'https://cdn.hilvpai.com';
  const platforms = ['windows-x64', 'macos-arm64', 'macos-x64', 'ios'];
  function validStoreUrl(value) {
    if (typeof value !== 'string') return false;
    if (!/^https:\/\/(?:testflight\.apple\.com\/join\/[A-Za-z0-9]{8}|apps\.apple\.com\/(?:[a-z]{2}\/)?app\/(?:[A-Za-z0-9%._~-]+\/)?id[0-9]+)$/.test(value)) return false;
    try {
      const u = new URL(value);
      if (u.protocol !== 'https:' || u.username || u.password || u.port || u.search || u.hash) return false;
      return (u.hostname === 'testflight.apple.com' && /^\/join\/[A-Za-z0-9]{8}$/.test(u.pathname)) ||
        (u.hostname === 'apps.apple.com' && /^\/(?:[a-z]{2}\/)?app\/(?:[A-Za-z0-9%._~-]+\/)?id[0-9]+$/.test(u.pathname));
    } catch (_) { return false; }
  }
  function validate(data, platform, channel) {
    if (!platforms.includes(platform) || !['local', 'test', 'prd'].includes(channel) || !data ||
        data.platform !== platform || data.channel !== channel || !Number.isInteger(data.versionCode) ||
        data.versionCode < 1 || data.versionCode > 2000000000 || typeof data.versionName !== 'string' ||
        !/^[0-9A-Za-z][0-9A-Za-z._-]{0,31}$/.test(data.versionName)) throw Error('版本清单平台或字段无效');
    if (platform === 'ios') {
      if (!validStoreUrl(data.storeUrl)) throw Error('苹果安装入口无效');
      return Object.freeze({ ...data, url: data.storeUrl });
    }
    const ext = platform === 'windows-x64' ? '.zip' : '.dmg';
    const url = `${ORIGIN}/ftp-client/${channel}/${platform}/lvpai-ftp-${data.versionName}-${data.versionCode}-${platform}${ext}`;
    if (data.installerUrl !== url || typeof data.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(data.sha256) ||
        !Number.isInteger(data.sizeBytes) || data.sizeBytes < 1 || data.sizeBytes > 512 * 1024 * 1024) {
      throw Error('安装包地址或校验字段无效');
    }
    return Object.freeze({ ...data, url });
  }
  const api = Object.freeze({ validate, validStoreUrl, platforms });
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.FtpReleases = api;
})(globalThis);
