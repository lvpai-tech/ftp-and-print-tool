import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class EnrollmentLocationFields extends StatelessWidget {
  const EnrollmentLocationFields({
    super.key,
    required this.name,
    required this.location,
    required this.locationHint,
  });

  final TextEditingController name;
  final TextEditingController location;
  final String locationHint;

  static const _maxNameLength = 20;
  static const _maxLocationLength = 60;

  String get description => '${name.text.trim()} · ${location.text.trim()}';

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 12,
    children: [
      TextFormField(
        controller: name,
        textInputAction: TextInputAction.next,
        maxLength: _maxNameLength,
        maxLengthEnforcement: MaxLengthEnforcement.none,
        decoration: InputDecoration(
          labelText: '申请人姓名',
          counterText: '',
          suffixIcon: _characterCount(name, _maxNameLength),
        ),
        validator: (value) {
          if (value == null || value.trim().isEmpty) return '请填写申请人姓名';
          if (value.characters.length > _maxNameLength) {
            return '姓名最多 $_maxNameLength 个字符';
          }
          return null;
        },
      ),
      TextFormField(
        controller: location,
        maxLength: _maxLocationLength,
        maxLengthEnforcement: MaxLengthEnforcement.none,
        decoration: InputDecoration(
          labelText: '具体地点',
          hintText: locationHint,
          counterText: '',
          suffixIcon: _characterCount(location, _maxLocationLength),
        ),
        validator: (value) {
          if (value == null || value.trim().isEmpty) return '请填写具体地点';
          if (value.characters.length > _maxLocationLength) {
            return '地点最多 $_maxLocationLength 个字符';
          }
          // The Java request DTO counts UTF-16 code units in the combined value.
          if (description.length > 100) return '姓名和地点合计过长，请缩短后提交';
          return null;
        },
      ),
    ],
  );

  Widget _characterCount(TextEditingController controller, int limit) => Center(
    widthFactor: 1,
    heightFactor: 1,
    child: Padding(
      padding: const EdgeInsetsDirectional.only(start: 8, end: 12),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final count = value.text.characters.length;
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
          return Text(
            '$count/$limit',
            semanticsLabel: '已输入 $count 个字符，上限 $limit 个字符',
            style: theme.textTheme.bodySmall?.copyWith(
              color: count > limit ? colors.error : colors.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );
        },
      ),
    ),
  );
}
