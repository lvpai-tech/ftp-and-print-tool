(function () {
  'use strict';
  function text(tag, value, className) {
    const node = document.createElement(tag);
    node.textContent = value;
    if (className) node.className = className;
    return node;
  }
  async function load(card) {
    const target = card.querySelector('.release');
    target.replaceChildren(text('p', '正在读取版本…', 'muted'));
    try {
      const platform = card.dataset.platform;
      const response = await fetch(new URL(`./prd/${platform}/latest.json`, location.href), {
        cache: 'no-store', redirect: 'error', signal: AbortSignal.timeout(15000),
      });
      if (response.status === 404) {
        target.replaceChildren(text('p', '尚未发布', 'unavailable'));
        return;
      }
      if (!response.ok) throw Error('版本服务暂时不可用，请稍后刷新');
      // 流式限制清单大小，避免远端异常响应占用过多内存。
      const reader = response.body.getReader();
      const chunks = [];
      let size = 0;
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          size += value.length;
          if (size > 16384) throw Error('版本清单过大，已拒绝');
          chunks.push(value);
        }
      } finally { await reader.cancel(); }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      const release = FtpReleases.validate(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)), platform, 'prd');
      const link = text('a', platform === 'ios' ? '前往苹果安装入口' : '下载更新包');
      link.href = release.url;
      link.rel = 'noopener noreferrer';
      target.replaceChildren(text('p', `v${release.versionName} · build ${release.versionCode}`, 'version'));
      if (platform !== 'ios') target.append(text('p', `${(release.sizeBytes / 1048576).toFixed(1)} MiB`, 'muted'));
      target.append(link);
      if (platform !== 'ios') target.append(text('p', `SHA-256：${release.sha256}`, 'checksum'));
    } catch (error) {
      target.replaceChildren(text('p', '版本读取失败，请刷新重试', 'error'));
    }
  }
  async function refresh() {
    const button = document.getElementById('refresh');
    button.disabled = true;
    try { await Promise.all([...document.querySelectorAll('[data-platform]')].map(load)); }
    finally { button.disabled = false; }
  }
  document.getElementById('refresh').addEventListener('click', refresh);
  refresh();
})();
