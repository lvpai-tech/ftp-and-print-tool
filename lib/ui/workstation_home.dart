import 'package:material_ui/material_ui.dart';

const workstationBackground = Color(0xfff5f7fb);
const workstationInk = Color(0xff192943);
const workstationWideWidth = 800.0;

const _homeInk = Color(0xff171e27);
const _homeSecondaryInk = Color(0xff3c4654);
const _homeBorder = Color(0xffd8dde5);

enum WorkModule {
  upload('上传照片', '指定文件夹中的新照片会自动上传', '查看上传', Icons.cloud_upload_outlined),
  print('打印照片', '查看待打印照片，核对后打印', '进入打印', Icons.print_outlined),
  pickupCards('打印取片码', '', '', Icons.qr_code_2);

  const WorkModule(this.label, this.description, this.action, this.icon);

  final String label, description, action;
  final IconData icon;
}

class WorkstationHome extends StatelessWidget {
  const WorkstationHome({
    super.key,
    required this.uploadStatus,
    required this.printStatus,
    required this.uploadActive,
    required this.printActive,
    required this.onOpen,
    this.showPickupCards = false,
  });

  final String uploadStatus, printStatus;
  final bool uploadActive, printActive;
  final ValueChanged<WorkModule> onOpen;
  final bool showPickupCards;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final wide = bounds.maxWidth >= workstationWideWidth;
      final spacious = bounds.maxWidth >= 1050;
      final cards = [
        _ModuleCard(
          module: WorkModule.upload,
          status: uploadStatus,
          active: uploadActive,
          spacious: spacious,
          onTap: () => onOpen(WorkModule.upload),
        ),
        _ModuleCard(
          module: WorkModule.print,
          status: printStatus,
          active: printActive,
          spacious: spacious,
          onTap: () => onOpen(WorkModule.print),
        ),
      ];
      return SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: wide ? 40 : 16,
          vertical: spacious ? 68 : 28,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1088),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: spacious ? 48 : 24,
              children: [
                Padding(
                  padding: EdgeInsets.only(left: spacious ? 14 : 0),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 16,
                    runSpacing: 12,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          '照片工作台',
                          style: TextStyle(
                            fontSize: spacious ? 48 : 34,
                            height: 1.16,
                            color: _homeInk,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (showPickupCards)
                        MenuAnchor(
                          menuChildren: [
                            MenuItemButton(
                              leadingIcon: const Icon(Icons.qr_code_2),
                              onPressed: () => onOpen(WorkModule.pickupCards),
                              child: const Text('打印取片码'),
                            ),
                          ],
                          builder: (context, controller, _) =>
                              OutlinedButton.icon(
                                onPressed: () {
                                  if (controller.isOpen) {
                                    controller.close();
                                  } else {
                                    controller.open();
                                  }
                                },
                                icon: const Icon(Icons.expand_more),
                                label: const Text('更多操作'),
                              ),
                        ),
                    ],
                  ),
                ),
                if (wide)
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 28,
                      children: [
                        for (final card in cards) Expanded(child: card),
                      ],
                    ),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 16,
                    children: cards,
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    required this.module,
    required this.status,
    required this.active,
    required this.spacious,
    required this.onTap,
  });

  final WorkModule module;
  final String status;
  final bool active, spacious;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(18)),
      side: BorderSide(color: _homeBorder),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      canRequestFocus: false,
      excludeFromSemantics: true,
      child: Padding(
        padding: spacious
            ? const EdgeInsets.symmetric(horizontal: 36, vertical: 40)
            : const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(module.icon, size: spacious ? 60 : 44, color: _homeInk),
                SizedBox(height: spacious ? 20 : 12),
                Text(
                  module.label,
                  style: TextStyle(
                    color: _homeInk,
                    fontSize: spacious ? 38 : 28,
                    fontWeight: FontWeight.w700,
                    height: 1.18,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  module.description,
                  style: TextStyle(
                    color: _homeSecondaryInk,
                    fontSize: spacious ? 20 : 16,
                    height: 1.4,
                  ),
                ),
                SizedBox(height: spacious ? 26 : 18),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Divider(height: 1, color: _homeBorder),
                SizedBox(height: spacious ? 18 : 14),
                Row(
                  children: [
                    Icon(
                      Icons.circle,
                      size: spacious ? 16 : 12,
                      color: active
                          ? const Color(0xff15883d)
                          : const Color(0xffaab1ba),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        status,
                        key: ValueKey('status-${module.name}'),
                        style: TextStyle(
                          color: _homeSecondaryInk,
                          fontSize: spacious ? 19 : 16,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: spacious ? 24 : 18),
                FilledButton(
                  key: ValueKey('open-${module.name}'),
                  onPressed: onTap,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xff176bce),
                    foregroundColor: Colors.white,
                    minimumSize: Size(0, spacious ? 56 : 48),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(10)),
                    ),
                    textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontSize: spacious ? 22 : 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  child: Text(module.action),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
