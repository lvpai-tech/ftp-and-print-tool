/// PROTOTYPE only — fake print-desk jobs. Do not wire to PrintBridge.
class ProtoJob {
  const ProtoJob({
    required this.id,
    required this.phone,
    required this.content,
    required this.time,
    required this.thumbCount,
    required this.moreCount,
    this.status = ProtoJobStatus.pending,
    this.alertReason,
  });

  final int id;
  final String phone;
  final String content;
  final String time;
  final int thumbCount;
  final int moreCount;
  final ProtoJobStatus status;
  final String? alertReason;
}

enum ProtoJobStatus { pending, need, printed }

const protoScenicName = '玉龙雪山·蓝月谷';

const protoPendingJobs = <ProtoJob>[
  ProtoJob(
    id: 578,
    phone: '····8821',
    content: '开头片×1、原片×2、创意×6',
    time: '06:25:56',
    thumbCount: 3,
    moreCount: 6,
  ),
  ProtoJob(
    id: 577,
    phone: '····1093',
    content: '开头片×1、原片×2、创意×6',
    time: '06:24:51',
    thumbCount: 3,
    moreCount: 6,
  ),
  ProtoJob(
    id: 576,
    phone: '····7740',
    content: '开头片×1、原片×2、创意×6',
    time: '06:21:18',
    thumbCount: 3,
    moreCount: 6,
  ),
  ProtoJob(
    id: 575,
    phone: '····2201',
    content: '原片×4、创意×4',
    time: '06:18:02',
    thumbCount: 3,
    moreCount: 5,
  ),
  ProtoJob(
    id: 574,
    phone: '····6612',
    content: '开头片×1、创意×8',
    time: '06:12:44',
    thumbCount: 3,
    moreCount: 6,
  ),
  ProtoJob(
    id: 573,
    phone: '····9088',
    content: '原片×2、创意×6',
    time: '06:05:10',
    thumbCount: 3,
    moreCount: 5,
  ),
];

const protoAlerts = <ProtoJob>[
  ProtoJob(
    id: 552,
    phone: '····3341',
    content: '开头片×1、原片×2、创意×4',
    time: '05:48:11',
    thumbCount: 3,
    moreCount: 4,
    status: ProtoJobStatus.need,
    alertReason: '驱动报告缺纸，已暂停本单。请核实纸匣后继续。',
  ),
  ProtoJob(
    id: 541,
    phone: '····0199',
    content: '原片×2、创意×6',
    time: '05:22:03',
    thumbCount: 3,
    moreCount: 5,
    status: ProtoJobStatus.need,
    alertReason: '打印中断：任务超时。可继续剩余张数或整单重打。',
  ),
];
