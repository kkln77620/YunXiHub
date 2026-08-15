import 'package:flutter/material.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 播放设置 → 评论屏蔽：关键词 / 正则 / 等级（纯本地）
class CommentFilterSettingsPage extends StatefulWidget {
  const CommentFilterSettingsPage({super.key});

  @override
  State<CommentFilterSettingsPage> createState() =>
      _CommentFilterSettingsPageState();
}

class _CommentFilterSettingsPageState extends State<CommentFilterSettingsPage> {
  late bool _enabled = GStorage.getSetting(SettingsKeys.commentFilterEnabled);
  late final TextEditingController _keywords =
      TextEditingController(text: GStorage.getSetting(SettingsKeys.commentFilterKeywords));
  late final TextEditingController _regex =
      TextEditingController(text: GStorage.getSetting(SettingsKeys.commentFilterRegex));
  late int _minLevel = GStorage.getSetting(SettingsKeys.commentFilterMinLevel);

  @override
  void dispose() {
    _keywords.dispose();
    _regex.dispose();
    super.dispose();
  }

  Future<void> _save({bool? enabled, String? keywords, String? regex, int? minLevel}) async {
    if (enabled != null) {
      _enabled = enabled;
      await GStorage.putSetting(SettingsKeys.commentFilterEnabled, enabled);
    }
    if (keywords != null) {
      await GStorage.putSetting(SettingsKeys.commentFilterKeywords, keywords);
    }
    if (regex != null) {
      await GStorage.putSetting(SettingsKeys.commentFilterRegex, regex);
    }
    if (minLevel != null) {
      _minLevel = minLevel;
      await GStorage.putSetting(SettingsKeys.commentFilterMinLevel, minLevel);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('评论屏蔽'),
      body: SettingsList(
        sections: [
          SettingsSection(
            title: const Text('开关'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.visibility_off_rounded,
                onToggle: (v) => _save(enabled: v ?? false),
                title: const Text('启用评论屏蔽'),
                description: const Text('对播放器内的 Bangumi 评论与社区评论生效'),
                initialValue: _enabled,
              ),
            ],
          ),
          SettingsSection(
            title: const Text('关键词过滤'),
            tiles: [
              SettingsTile(
                leading: Icons.key_rounded,
                onPressed: (_) {},
                title: TextField(
                  controller: _keywords,
                  decoration: const InputDecoration(
                    hintText: '输入关键词，多个用逗号分隔',
                    border: InputBorder.none,
                  ),
                  onChanged: (v) => _save(keywords: v),
                ),
                description: const Text('例如：剧透,广告,求资源'),
              ),
            ],
          ),
          SettingsSection(
            title: const Text('正则过滤'),
            tiles: [
              SettingsTile(
                leading: Icons.data_object_rounded,
                onPressed: (_) {},
                title: TextField(
                  controller: _regex,
                  decoration: const InputDecoration(
                    hintText: '输入正则表达式，如 第\\d+话 下载',
                    border: InputBorder.none,
                  ),
                  onChanged: (v) => _save(regex: v),
                ),
                description: const Text('匹配命中即屏蔽；语法错误时自动忽略'),
              ),
            ],
          ),
          SettingsSection(
            title: const Text('等级过滤（社区评论）'),
            tiles: [
              SettingsTile(
                leading: Icons.school_rounded,
                onPressed: (_) {},
                title: const Text('屏蔽低于该等级的用户评论'),
                value: Text('L$_minLevel 以下'),
                description: const Text('L0=未考核用户；0 表示不过滤等级'),
              ),
              Slider(
                value: _minLevel.clamp(0, 9).toDouble(),
                min: 0,
                max: 9,
                divisions: 9,
                label: _minLevel == 0 ? '不过滤' : 'L$_minLevel 以下屏蔽',
                onChanged: (v) => _save(minLevel: v.round()),
              ),
            ],
          ),
          SettingsSection(
            title: const Text('说明'),
            tiles: [
              const SettingsTile(
                leading: Icons.info_outline_rounded,
                onPressed: null,
                title: Text('屏蔽规则仅保存在本机，不影响服务器与其他用户'),
                description: Text('播放器评论页会显示已屏蔽条数'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}