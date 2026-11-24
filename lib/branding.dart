import 'release/update_service.dart' show updateChannel;

const _channelSuffix = updateChannel == 'test'
    ? '（测试版）'
    : updateChannel == 'local'
    ? '（本地版）'
    : '';
const appBrandName = '帧集快拍$_channelSuffix';
const appSlogan = '一分钟拍大片';
const workstationTitle = '$appBrandName · 上传与打印工作台';
