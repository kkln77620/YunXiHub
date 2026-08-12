import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/pages/account/login_page.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/remote/history_sync_service.dart';

/// YunXiHub 账号设置页
///
/// 未登录：展示登录/注册入口；
/// 已登录：展示邮箱、赞助用户状态，支持退出登录。
class AccountSettingsPage extends StatefulWidget {
  const AccountSettingsPage({super.key});

  @override
  State<AccountSettingsPage> createState() => _AccountSettingsPageState();
}

class _AccountSettingsPageState extends State<AccountSettingsPage> {
  bool get _loggedIn => AuthService.instance.isLoggedIn;
  String get _email => AuthService.instance.email;
  int get _vipLevel => AuthService.instance.vipLevel;
  String get _vipExpire => AuthService.instance.vipExpire;

  @override
  void initState() {
    super.initState();
    // 进入页面时刷新一次 VIP 状态（静默）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AuthService.instance.refreshMe().then((_) {
        if (mounted) setState(() {});
      });
    });
  }

  Future<void> _goLogin() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    if (ok == true && mounted) {
      setState(() {});
      // 登录成功后台同步历史记录
      unawaited(HistorySyncService.instance.syncNow());
    }
  }

  Future<void> _logout() async {
    await AuthService.instance.logout();
    if (mounted) setState(() {});
    KazumiDialog.showToast(message: '已退出登录');
  }

  String get _vipLabel {
    if (_vipLevel <= 0) return '普通用户';
    if (_vipExpire.isNotEmpty) return '赞助用户 · 有效期至 $_vipExpire';
    return '赞助用户';
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('账号'),
      body: SettingsList(
        sections: [
          SettingsSection(
            title: Text(_loggedIn ? '账号信息' : '未登录'),
            tiles: [
              if (!_loggedIn)
                SettingsTile(
                  leading: Icons.login_rounded,
                  onPressed: (_) async => _goLogin(),
                  title: const Text('登录 / 注册'),
                  description: const Text('使用邮箱验证码注册，登录后解锁完整服务'),
                )
              else ...[
                SettingsTile(
                  leading: Icons.mail_outline_rounded,
                  onPressed: (_) {},
                  title: const Text('邮箱'),
                  description: Text(_email),
                ),
                SettingsTile(
                  leading: Icons.workspace_premium_rounded,
                  onPressed: (_) {},
                  title: const Text('赞助用户'),
                  description: Text(_vipLabel),
                ),
                SettingsTile(
                  leading: Icons.logout_rounded,
                  onPressed: (_) async => _logout(),
                  title: const Text('退出登录'),
                  description: const Text('清除本地登录状态'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}