import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/sync/bangumi_sync_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/services/storage/settings_keys.dart';

class WebDavSettingsPage extends StatefulWidget {
  const WebDavSettingsPage({super.key});

  @override
  State<WebDavSettingsPage> createState() => _PlayerSettingsPageState();
}

class _PlayerSettingsPageState extends State<WebDavSettingsPage> {
  late bool enableGitProxy;
  late bool enableBangumiProxy;
  late bool bangumiSyncEnable;
  late bool cloudHistorySyncEnable;
  late bool cloudCollectSyncEnable;

  @override
  void initState() {
    super.initState();
    enableGitProxy = GStorage.getSetting(SettingsKeys.enableGitProxy);
    enableBangumiProxy = GStorage.getSetting(SettingsKeys.enableBangumiProxy);
    bangumiSyncEnable = GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
    cloudHistorySyncEnable =
        GStorage.getSetting(SettingsKeys.cloudHistorySyncEnable);
    cloudCollectSyncEnable =
        GStorage.getSetting(SettingsKeys.cloudCollectSyncEnable);
  }

  void onBackPressed(BuildContext context) {
    if (KazumiDialog.observer.hasKazumiDialog) {
      KazumiDialog.dismiss();
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        onBackPressed(context);
      },
      child: SettingsDetailScaffold(
        title: const Text('同步设置'),
        body: SettingsList(
          sections: [
            SettingsSection(
              title: Text('YunXiHub 云同步'),
              tiles: [
                SettingsTile(
                  leading: Icons.account_circle_rounded,
                  onPressed: (_) async {
                    await context.pushNamed('/settings/account/');
                    setState(() {});
                  },
                  title: Text(
                    GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty
                        ? '账号已登录'
                        : '登录账号（游客也可同步）',
                  ),
                  description: Text(
                    GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty
                        ? '历史与追番已云同步，登录后自动合并游客数据'
                        : '未登录时以设备维度云同步，登录后自动并入账号',
                  ),
                ),
                SettingsTile.switchTile(
                  leading: Icons.history_rounded,
                  onToggle: (value) async {
                    cloudHistorySyncEnable = value ?? !cloudHistorySyncEnable;
                    await GStorage.putSetting(
                        SettingsKeys.cloudHistorySyncEnable,
                        cloudHistorySyncEnable);
                    setState(() {});
                  },
                  title: Text('历史记录云同步'),
                  description: Text('观看记录自动同步到 YunXiHub 云'),
                  initialValue: cloudHistorySyncEnable,
                ),
                SettingsTile.switchTile(
                  leading: Icons.favorite_rounded,
                  onToggle: (value) async {
                    cloudCollectSyncEnable = value ?? !cloudCollectSyncEnable;
                    await GStorage.putSetting(
                        SettingsKeys.cloudCollectSyncEnable,
                        cloudCollectSyncEnable);
                    setState(() {});
                  },
                  title: Text('追番收藏云同步'),
                  description: Text('追番状态自动同步到 YunXiHub 云'),
                  initialValue: cloudCollectSyncEnable,
                ),
              ],
            ),
            SettingsSection(
              title: Text('规则仓库'),
              tiles: [
                SettingsTile.switchTile(
                  leading: Icons.hub_rounded,
                  onToggle: (value) async {
                    enableGitProxy = value ?? !enableGitProxy;
                    await GStorage.putSetting(
                        SettingsKeys.enableGitProxy, enableGitProxy);
                    setState(() {});
                  },
                  title: Text('规则仓库镜像'),
                  description: Text('使用镜像访问规则更新和管理仓库'),
                  initialValue: enableGitProxy,
                ),
              ],
            ),
            SettingsSection(
              title: Text('Bangumi'),
              tiles: [
                SettingsTile.switchTile(
                  leading: Icons.cloud_rounded,
                  onToggle: (value) async {
                    enableBangumiProxy = value ?? !enableBangumiProxy;
                    await GStorage.putSetting(
                        SettingsKeys.enableBangumiProxy, enableBangumiProxy);
                    if (mounted) {
                      setState(() {});
                    }
                  },
                  title: Text('Bangumi 镜像'),
                  description: Text('使用本地 Bangumi 缓存后端加载热门与分类榜单'),
                  initialValue: enableBangumiProxy,
                ),
                SettingsTile(
                  leading: Icons.tune_rounded,
                  onPressed: (_) async {
                    await context.pushNamed('/settings/bangumi/');
                    setState(() {});
                  },
                  title: Text('Bangumi 配置'),
                  description: Text('绑定 Access Token 以发表吐槽/评分'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}