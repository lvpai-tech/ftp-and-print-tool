'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { downloadFile } = require('../src/api');

test('图片下载拒绝HTTP200业务错误JSON，正常图片保持字节不变', async () => {
  const jpeg = Buffer.from('ffd8ffe10000ffd9', 'hex');
  const server = http.createServer((request, response) => {
    if (request.url === '/error') {
      response.writeHead(200, { 'Content-Type': 'application/json;charset=UTF-8' });
      response.end(JSON.stringify({ code: 50001, message: '系统繁忙', data: null }));
    } else {
      response.writeHead(200, { 'Content-Type': 'image/jpeg' });
      response.end(jpeg);
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const config = { base: `http://127.0.0.1:${server.address().port}`, token: 'test' };
    await assert.rejects(() => downloadFile(config, '/error'), /图片接口返回错误响应（错误码 50001）/);
    assert.deepEqual((await downloadFile(config, '/image')).buffer, jpeg);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
