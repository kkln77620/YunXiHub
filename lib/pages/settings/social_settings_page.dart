import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/remote/friends_service.dart';

/// 应用设置 → 社交：主页展示项开关（仅好友可见的追番/历史）
class SocialSettingsPage extends StatefulWidget {
  const SocialSettingsPage({super.key});

  @override
  State<SocialSettingsPage> createState() => _SocialSettingsPageState();
}

class _SocialSettingsPageState extends State<SocialSettingsPage> {
  late bool _showCollect;
  late bool _showHistory;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // 本地没有持久化社交开关，从服务器拉取（登录后才有值）
    _showCollect = true;
    _showHistory = true;
    _load();
  }

  Future<void> _load() async {
    final uid = AuthService.instance.uid;
    if (uid <= 0) return;
    final p = await FriendsService.instance.profile(uid);
    if (!mounted || p == null) return;
    setState(() {
      _showCollect = p.showCollect == 1;
      _showHistory = p.showHistory == 1;
    });
  }

  Future<void> _save({bool? collect, bool? history}) async {
    if (_saving) return;
    setState(() => _saving = true);
    final err = await FriendsService.instance.setPrivacy(
      showCollect: collect ?? _showCollect,
      showHistory: history ?? _showHistory,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (err != null) {
      KazumiDialog.showToast(message: err);
    } else {
      if (collect != null) setState(() => _showCollect = collect);
      if (history != null) setState(() => _showHistory = history);
      KazumiDialog.showToast(message: '已保存');
    }
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = AuthService.instance.isLoggedIn;
    return SettingsDetailScaffold(
      title: const Text('社交'),
      body: SettingsList(
        sections: [
          if (!loggedIn)
            SettingsSection(
              title: const Text('提示'),
              tiles: const [
                SettingsTile(
                  leading: Icons.lock_rounded,
                  onPressed: null,
                  title: Text('登录后可用'),
                  description: Text('社交设置属于账号功能，请先在“我的”页登录'),
                ),
              ],
            )
          else ...[
            SettingsSection(
              title: const Text('主页展示'),
              tiles: [
                SettingsTile.switchTile(
                  leading: Icons.bookmark_rounded,
                  onToggle: (v) => _save(collect: v ?? false),
                  title: const Text('展示我的追番'),
                  description: const Text('好友访问你的主页时可查看追番列表'),
                  initialValue: _showCollect,
                ),
                SettingsTile.switchTile(
                  leading: Icons.history_rounded,
                  onToggle: (v) => _save(history: v ?? false),
                  title: const Text('展示我的观看历史'),
                  description: const Text('好友访问你的主页时可查看观看记录'),
                  initialValue: _showHistory,
                ),
              ],
            ),
            SettingsSection(
              title: const Text('说明'),
              tiles: const [
                SettingsTile(
                  leading: Icons.info_outline_rounded,
                  onPressed: null,
                  title: Text('仅好友可查看你的追番与历史'),
                  description: Text('非好友只能看到昵称、等级与 UID；自己始终可见全部'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}