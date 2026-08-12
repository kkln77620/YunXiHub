import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/services/remote/points_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 积分页：每日签到获取积分；兑换功能预留（暂隐藏）
class PointsPage extends StatefulWidget {
  const PointsPage({super.key});

  @override
  State<PointsPage> createState() => _PointsPageState();
}

class _PointsPageState extends State<PointsPage> {
  PointsInfo? _info;
  bool _loading = true;
  bool _checking = false;
  String _error = '';

  /// 登录态以本地 token 为准（不依赖网络请求，避免误判）
  bool get _loggedIn =>
      GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    // 有缓存时秒显（页面切换不再重新转圈），再后台刷新
    _info = PointsService.instance.cached;
    if (_info != null) {
      _loading = false;
    }
    _load();
  }

  Future<void> _load() async {
    if (!_loggedIn) {
      setState(() {
        _info = null;
        _loading = false;
        _error = '';
      });
      return;
    }
    setState(() {
      _loading = _info == null;
      _error = '';
    });
    try {
      final info = await PointsService.instance.me();
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // 已登录但请求失败：显示错误+重试，不再误判为“未登录”
      setState(() {
        _error = '积分加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _checkin() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final result = await PointsService.instance.checkin();
      if (!mounted) return;
      KazumiDialog.showToast(message: result.msg);
      await _load();
    } catch (e) {
      if (!mounted) return;
      KazumiDialog.showToast(message: e.toString());
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('积分')),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : !_loggedIn
                ? Center(
                    child: GeneralErrorWidget(
                      errMsg: '登录后即可签到获取积分',
                      actions: [
                        GeneralErrorButton(
                          text: '去登录',
                          onPressed: () async {
                            await context.pushNamed('/settings/account/');
                            if (mounted) _load();
                          },
                        ),
                      ],
                    ),
                  )
                : _error.isNotEmpty && _info == null
                    ? Center(
                        child: GeneralErrorWidget(
                          errMsg: _error,
                          actions: [
                            GeneralErrorButton(
                              text: '重试',
                              onPressed: () => _load(),
                            ),
                          ],
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.stars_rounded,
                                  size: 48,
                                  color: colorScheme.primary,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '我的积分',
                                  style: textTheme.titleMedium?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: '${_info?.points ?? 0}',
                                        style:
                                            textTheme.displayMedium?.copyWith(
                                          color: colorScheme.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      TextSpan(
                                        text: ' 分',
                                        style: textTheme.titleMedium?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                                FilledButton.icon(
                                  onPressed:
                                      (_info?.checkedInToday ?? false) ||
                                              _checking
                                          ? null
                                          : _checkin,
                                  icon: _checking
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        )
                                      : const Icon(Icons.task_alt_rounded),
                                  label: Text(
                                    (_info?.checkedInToday ?? false)
                                        ? '今日已签到'
                                        : '每日签到 +10 积分',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.storefront_rounded,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '积分商城',
                                        style: textTheme.titleSmall,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '兑换功能即将上线，敬请期待',
                                        style: textTheme.bodySmall?.copyWith(
                                          color:
                                              colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
      ),
    );
  }
}