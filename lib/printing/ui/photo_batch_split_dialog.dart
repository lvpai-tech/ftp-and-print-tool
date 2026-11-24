import 'package:material_ui/material_ui.dart';

import '../../ui/workstation_form_dialog.dart';
import '../job_query_time.dart';
import '../print_bridge.dart';

class PhotoBatchSplitDialog extends StatelessWidget {
  const PhotoBatchSplitDialog({
    super.key,
    required this.before,
    required this.after,
    required this.interval,
    required this.parts,
    required this.cardTail,
    required this.managementOnly,
    required this.thumbnail,
  });

  final DateTime? before;
  final DateTime? after;
  final String interval;
  final List<Json> parts;
  final String? cardTail;
  final bool managementOnly;
  final Widget Function(Json) thumbnail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    final sharedDate =
        before != null && after != null && DateUtils.isSameDay(before, after)
        ? formatWallClock(before!).split(' ').first
        : null;
    return WorkstationFormDialog(
      title: '切分结果预览',
      titleLeading: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: SizedBox.square(
          dimension: 36,
          child: Icon(
            Icons.content_cut_rounded,
            color: colors.onPrimaryContainer,
            size: 19,
          ),
        ),
      ),
      width: 824,
      content: Column(
        spacing: 16,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: colors.primaryContainer.withValues(alpha: .42),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              spacing: 10,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sharedDate == null
                      ? '切分点 · 拍摄时间'
                      : '切分点 · 拍摄时间 · $sharedDate',
                  style: type.labelLarge?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Wrap(
                  spacing: 16,
                  runSpacing: 10,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _SplitTime(
                          label: '切分前',
                          time: before,
                          showDate: sharedDate == null,
                        ),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 18,
                          color: colors.primary,
                        ),
                        _SplitTime(
                          label: '切分后',
                          time: after,
                          showDate: sharedDate == null,
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        interval,
                        style: type.labelLarge?.copyWith(
                          color: colors.primary,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 12.0;
              final sideBySide =
                  constraints.maxWidth >= 560 &&
                  MediaQuery.textScalerOf(context).scale(16) <= 24;
              final width = sideBySide
                  ? (constraints.maxWidth - gap) / 2
                  : constraints.maxWidth;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final (index, part) in parts.indexed)
                    SizedBox(
                      width: width,
                      child: _SplitGroup(
                        part: part,
                        number: index + 1,
                        cardTail: cardTail,
                        thumbnail: thumbnail,
                      ),
                    ),
                ],
              );
            },
          ),
          if (managementOnly)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: colors.primary,
                ),
                Expanded(
                  child: Text(
                    '切分将保存到照片管理。照片的取片卡和游客权益会保留。',
                    style: type.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.check_rounded, size: 18),
          label: const Text('保存切分'),
        ),
      ],
    );
  }
}

class _SplitTime extends StatelessWidget {
  const _SplitTime({
    required this.label,
    required this.time,
    required this.showDate,
  });

  final String label;
  final DateTime? time;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stamp = time == null ? null : formatWallClock(time!).split(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          stamp?.last ?? '时间未知',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (showDate && stamp != null)
          Text(
            stamp.first,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
      ],
    );
  }
}

class _SplitGroup extends StatelessWidget {
  const _SplitGroup({
    required this.part,
    required this.number,
    required this.cardTail,
    required this.thumbnail,
  });

  final Json part;
  final int number;
  final String? cardTail;
  final Widget Function(Json) thumbnail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final type = theme.textTheme;
    final photos = (part['photos'] as List).cast<Json>();
    final count = photos
        .where(
          (photo) => photo['ending'] != true && photo['assetRole'] != 'CARD',
        )
        .length;
    final hasEnding = photos.any((photo) => photo['ending'] == true);
    final status = switch (part['directory']) {
      'aggregated' => '已归集',
      'pending_claim' => '待认领',
      'suspicious' => '可疑组',
      'incoming' => '未归集',
      _ => throw StateError('切分预览状态无效。'),
    };
    final assignment = hasEnding
        ? (cardTail == null ? '有结束照' : '取片卡 $cardTail')
        : '无结束照';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '第 $number 组',
                style: type.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(
                '$count 张游客照',
                style: type.labelLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: hasEnding
                      ? colors.secondaryContainer
                      : colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  child: Text(
                    status,
                    style: type.labelMedium?.copyWith(
                      color: hasEnding
                          ? colors.onSecondaryContainer
                          : colors.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Text(
                assignment,
                style: type.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
          Divider(height: 1, color: colors.outlineVariant),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 8.0;
              final available = constraints.maxWidth;
              final width =
                  (available >= 216 ? (available - gap) / 2 : available).clamp(
                    0.0,
                    176.0,
                  );
              return Wrap(
                spacing: gap,
                runSpacing: 12,
                children: [
                  for (final photo in photos)
                    SizedBox(
                      width: width,
                      child: _SplitPhoto(
                        photo: photo,
                        thumbnail: thumbnail(photo),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SplitPhoto extends StatelessWidget {
  const _SplitPhoto({required this.photo, required this.thumbnail});

  final Json photo;
  final Widget thumbnail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final raw = photo['shotAt'];
    final time = raw is String ? DateTime.tryParse(raw) : null;
    final full = time == null ? '拍摄时间未知' : formatWallClock(time);
    final caption = time == null ? full : full.split(' ').last;
    final ending = photo['ending'] == true;
    final card = photo['assetRole'] == 'CARD';
    final label = ending
        ? '结束照'
        : card
        ? '卡片照'
        : '游客照';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 5,
      children: [
        Semantics(
          image: true,
          label: label,
          child: AspectRatio(
            aspectRatio: 3 / 2,
            child: Container(
              clipBehavior: Clip.antiAlias,
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colors.onSurface.withValues(alpha: .10),
                ),
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: colors.surfaceContainer,
              ),
              child: thumbnail,
            ),
          ),
        ),
        Tooltip(
          message: full,
          child: Text(
            ending || card ? '$label · $caption' : caption,
            style: theme.textTheme.bodySmall?.copyWith(
              color: ending ? colors.primary : colors.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
