import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 头衔选择页：展示已拥有的头衔，可切换当前展示头衔
class TitleSelectPage extends StatefulWidget {
  const TitleSelectPage({super.key});

  @override
  State<TitleSelectPage> createState() => _TitleSelectPageState();
}

class _TitleSelectPageState extends State<TitleSelectPage> {
  static const _titles = <String>['普通用户', '赞助用户', '管理员'];

  Future<void> _select(String title) async {
    await GStorage.putSetting(SettingsKeys.authSelectedTitle, title);
    if (!mounted) return;
    Navigator.of(context).pop();
    KazumiDialog.showToast(message: '已切换头衔：$title');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final current = AuthService.instance.title;
    return Scaffold(
      appBar: AppBar(title: const Text('头衔')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              '选择要展示的头衔（仅限已拥有）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final title in _titles)
            ListTile(
              leading: Icon(
                switch (title) {
                  '管理员' => Icons.shield_rounded,
                  '赞助用户' => Icons.workspace_premium_rounded,
                  _ => Icons.person_rounded,
                },
                color: switch (title) {
                  '管理员' => colorScheme.primary,
                  '赞助用户' => colorScheme.tertiary,
                  _ => colorScheme.onSurfaceVariant,
                },
              ),
              title: Text(title),
              subtitle: AuthService.instance.hasTitle(title)
                  ? null
                  : Text(
                      title == '管理员'
                          ? '需要管理员账号'
                          : '需要赞助用户',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.outline,
                      ),
                    ),
              trailing: current == title
                  ? Icon(Icons.check_circle_rounded, color: colorScheme.primary)
                  : (AuthService.instance.hasTitle(title)
                      ? const Icon(Icons.chevron_right_rounded)
                      : Icon(
                          Icons.lock_outline_rounded,
                          color: colorScheme.outlineVariant,
                        )),
              enabled: AuthService.instance.hasTitle(title),
              onTap: AuthService.instance.hasTitle(title)
                  ? () => _select(title)
                  : null,
            ),
        ],
      ),
    );
  }
}