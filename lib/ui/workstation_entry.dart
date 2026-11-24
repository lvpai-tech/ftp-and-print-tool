import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../workstation_account.dart';
import '../workstation_session.dart';
import 'dropdown_field.dart';
import 'workstation_login.dart';
import 'workstation_shell.dart';

class WorkstationEntry extends StatefulWidget {
  const WorkstationEntry({super.key, required this.session});
  final WorkstationSession session;

  @override
  State<WorkstationEntry> createState() => _WorkstationEntryState();
}

class _WorkstationEntryState extends State<WorkstationEntry>
    with WidgetsBindingObserver {
  WorkstationSession get session => widget.session;
  WorkstationAccount get account => session.account!;
  WorkstationIdentity? _identity;
  WorkstationScenic? _scenic;
  Timer? _poll;
  bool _checking = true;
  bool _changing = false;
  String? _notice;
  bool _locked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    _poll = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_identity != null || _locked) unawaited(_refresh());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _identity != null) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (_changing) return;
    _changing = true;
    try {
      if (_locked) await _lock(_notice ?? '请重新验证工作台会话');
      final next = await account.restore();
      if (!mounted) return;
      final previous = _identity;
      if (next == null && previous != null) {
        await _lock('登录已失效，请重新登录。');
      } else if (next != null) {
        final changed =
            previous != null &&
            (previous.role != next.role ||
                previous.scenics
                    .map((row) => row.id)
                    .toSet()
                    .difference(next.scenics.map((row) => row.id).toSet())
                    .isNotEmpty);
        if (changed && _scenic != null) {
          await _lock('景区授权已更新，请重新选择景区。');
        }
        if (mounted) await _accept(next);
      }
    } catch (error) {
      if (!mounted) return;
      final message = error is WorkstationAccountError
          ? error.message
          : '无法读取或验证工作台会话，请重试';
      if (_scenic != null && !_locked) {
        try {
          await _lock(message);
        } catch (_) {
          // 保持遮挡，直到任务和本地队列安全收尾。
        }
      }
      if (mounted) {
        setState(() => _notice = _locked ? '正在保留当前队列进度，请重试关闭工作台。' : message);
      }
    } finally {
      _changing = false;
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _accept(WorkstationIdentity identity) async {
    final first = _identity == null;
    setState(() {
      _identity = identity;
      session.identity = identity;
      _notice = null;
    });
    if (_scenic == null && identity.scenics.length == 1) {
      await _open(identity.scenics.single);
    } else if (first && _scenic == null && identity.scenics.isNotEmpty) {
      try {
        final saved = await account.lastScenic(identity);
        if (mounted && identity.permits(saved)) {
          await _open(identity.scenics.firstWhere((row) => row.id == saved));
        }
      } catch (_) {
        if (mounted && _scenic == null) {
          setState(() => _notice = '无法读取上次使用的景区，请手动选择。');
        }
      }
    }
  }

  Future<void> _open(WorkstationScenic scenic) async {
    if (session.scenic != null || !mounted) return;
    setState(() {
      _scenic = scenic;
      session.scenic = scenic;
      session.workspaceLocked = false;
      _notice = null;
    });
    final identity = _identity;
    if (identity != null) {
      try {
        await account.rememberScenic(identity, scenic);
      } catch (_) {
        if (mounted) session.report('无法保存本次景区选择。');
      }
    }
    if (mounted &&
        !session.closingWorkspace &&
        session.scenic?.id == scenic.id) {
      await session.startPrinting();
    }
  }

  Future<void> _lock(String message) async {
    final hasWorkspace = _scenic != null;
    setState(() {
      _checking = true;
      _notice = message;
      _locked = true;
    });
    if (hasWorkspace) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      await session.closeWorkspace();
    }
    if (!mounted) return;
    session.identity = null;
    setState(() {
      _scenic = null;
      _identity = null;
      _locked = false;
    });
  }

  Future<void> _logout() async {
    if (_changing) return;
    _changing = true;
    try {
      setState(() => _checking = true);
      await session.closeWorkspace();
      try {
        await account.logout();
        _notice = null;
      } on WorkstationAccountError {
        if (account.token != null) rethrow;
        _notice = '已退出本机。未收到服务端撤销确认。';
      }
      if (!mounted) return;
      session.identity = null;
      setState(() {
        _scenic = null;
        _identity = null;
      });
    } catch (_) {
      if (mounted) {
        if (session.scenic == null) {
          setState(() {
            _scenic = null;
            _notice = '无法清除本机登录凭据，请重试退出登录。';
          });
        } else {
          await _resumeAfterCloseFailure('退出失败，请稍后重试。');
        }
      }
    } finally {
      _changing = false;
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _changeScenic() async {
    if (_changing) return;
    _changing = true;
    try {
      setState(() => _checking = true);
      await session.closeWorkspace();
      if (mounted) setState(() => _scenic = null);
    } catch (_) {
      if (mounted) {
        await _resumeAfterCloseFailure('当前无法切换景区，请稍后重试。');
      }
    } finally {
      _changing = false;
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _resumeAfterCloseFailure(String message) async {
    try {
      await session.resumeWorkspace();
      session.report(message);
    } catch (_) {
      if (mounted) {
        setState(() {
          _locked = true;
          _notice = message;
        });
      }
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scenic = _scenic;
    final identity = _identity;
    if (scenic != null && identity != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          WorkstationShell(
            session: session,
            onLogout: _logout,
            onChangeScenic: _changeScenic,
          ),
          if (_checking || _locked)
            WorkstationLoginFrame(
              children: [
                const Text('正在停止接收新任务'),
                const SizedBox(height: 16),
                if (_checking) const LinearProgressIndicator(),
                if (_notice case final message?) Text(message),
                if (_locked && !_checking)
                  FilledButton(onPressed: _refresh, child: const Text('重试')),
              ],
            ),
        ],
      );
    }
    if (_checking) {
      return const WorkstationLoginFrame(
        children: [
          Text('正在验证工作台登录'),
          SizedBox(height: 16),
          LinearProgressIndicator(),
        ],
      );
    }
    if (identity != null) {
      return WorkstationLoginFrame(
        children: [
          Text(identity.name, style: Theme.of(context).textTheme.titleLarge),
          if (_notice case final message?) Text(message),
          const SizedBox(height: 16),
          if (identity.scenics.isEmpty)
            const Text('请联系管理员分配景区。')
          else
            DropdownField<WorkstationScenic>(
              label: '工作景区',
              placeholder: '请选择景区',
              options: identity.scenics,
              labelFor: (scenic) => scenic.name,
              value: null,
              onChanged: _open,
            ),
          const SizedBox(height: 16),
          TextButton(onPressed: _logout, child: const Text('退出登录')),
        ],
      );
    }
    if (account.token != null) {
      return WorkstationLoginFrame(
        children: [
          Text(_notice ?? '需要重新验证工作台会话'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              setState(() => _checking = true);
              unawaited(_refresh());
            },
            child: const Text('重试'),
          ),
          TextButton(onPressed: _logout, child: const Text('退出登录')),
        ],
      );
    }
    return WorkstationLogin(
      account: account,
      onLogin: _accept,
      notice: _notice,
    );
  }
}
