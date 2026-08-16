import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:image_picker/image_picker.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/pages/account/login_page.dart';
import 'package:kazumi/pages/account/title_select_page.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/remote/history_sync_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

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

  /// 打开头衔选择页
  Future<void> _openTitleSelect() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TitleSelectPage()),
    );
    if (mounted) setState(() {});
  }

  /// 编辑资料：昵称 + 头像（审查在服务端执行，支持选择后本地预览再保存；
/// 保存成功自动关闭并提示，横屏键盘不重叠）
  Future<void> _editProfile() async {
    final nicknameController = TextEditingController(
      text: AuthService.instance.nickname,
    );
    // 选择头像后先本地预览，保存时统一提交
    String? pendingAvatarPath;
    var pendingAvatarChanged = false;
    final currentAvatar = AuthService.instance.avatar;
    final baseUrl = _baseUrl;
    var saving = false;
    await KazumiDialog.show(
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            final bottomInset =
                MediaQuery.of(context).viewInsets.bottom;
            return Padding(
              // 键盘弹出时整体上移，避免横屏重叠
              padding: EdgeInsets.only(bottom: bottomInset),
              child: SingleChildScrollView(
                child: AlertDialog(
                  title: const Text('编辑资料'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 头像预览（原头像或新选择）
                      Stack(
                        children: [
                          CircleAvatar(
                            radius: 36,
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            foregroundImage: (pendingAvatarPath != null
                                ? FileImage(File(pendingAvatarPath!))
                                : (currentAvatar.isNotEmpty
                                    ? NetworkImage(
                                        currentAvatar.startsWith('http')
                                            ? currentAvatar
                                            : '$baseUrl$currentAvatar')
                                    : null)) as ImageProvider<Object>?,
                            child: (pendingAvatarPath == null &&
                                    currentAvatar.isEmpty)
                                ? Icon(
                                    Icons.person_rounded,
                                    size: 40,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  )
                                : null,
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: InkWell(
                              onTap: () async {
                                final picker = ImagePicker();
                                try {
                                  final file = await picker.pickImage(
                                      source: ImageSource.gallery);
                                  if (file == null) return;
                                  setState(() {
                                    pendingAvatarPath = file.path;
                                    pendingAvatarChanged = true;
                                  });
                                } catch (_) {
                                  KazumiDialog.showToast(
                                      message: '选择图片失败');
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.primary,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.photo_camera_rounded,
                                  size: 16,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        pendingAvatarPath != null
                            ? '点击头像更换（待保存）'
                            : '点击相机图标更换头像',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: nicknameController,
                        maxLength: 30,
                        decoration: const InputDecoration(
                          labelText: '昵称',
                          hintText: '不超过30字节',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: Text(
                        '取消',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ),
                    FilledButton(
                      onPressed: saving
                          ? null
                          : () async {
                              final nick = nicknameController.text.trim();
                              if (nick.isEmpty) {
                                KazumiDialog.showToast(message: '昵称不能为空');
                                return;
                              }
                              // 字节限制（UTF-8，≤30字节）
                              if (utf8.encode(nick).length > 30) {
                                KazumiDialog.showToast(message: '昵称不能超过30字节');
                                return;
                              }
                              setState(() => saving = true);
                              try {
                                var avatarUrl = '';
                                if (pendingAvatarChanged &&
                                    pendingAvatarPath != null) {
                                  // 按钮内转圈反馈（不再叠加全局 loading 弹窗）
                                  avatarUrl = await AuthService.instance
                                      .uploadImage(pendingAvatarPath!,
                                          use: 'avatar');
                                }
                                await AuthService.instance.updateProfile(
                                  nickname: nick,
                                  avatar:
                                      avatarUrl.isEmpty ? null : avatarUrl,
                                );
                                if (!mounted) return;
                                Navigator.of(dialogContext).pop(); // 关对话框
                                setState(() {});
                                KazumiDialog.showToast(message: '资料已保存');
                              } on AuthException catch (e) {
                                if (!mounted) return;
                                setState(() => saving = false);
                                KazumiDialog.showToast(message: '保存失败：${e.message}');
                              } catch (e) {
                                if (!mounted) return;
                                setState(() => saving = false);
                                KazumiDialog.showToast(message: '保存失败：$e');
                              }
                            },
                      child: saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('保存'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 服务器地址（与 AuthService 一致）
  String get _baseUrl {
    var base = GStorage.getSetting(SettingsKeys.remoteResolverBaseUrl).trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  String get _vipLabel {
    if (AuthService.instance.isAdmin) return '管理员';
    if (_vipLevel <= 0) return '普通用户';
    if (_vipExpire.isNotEmpty) return '赞助用户 · 有效期至 $_vipExpire';
    return '赞助用户';
  }

  /// 等级累计经验阈值（L2..L9 所需累计经验，与服务器一致）
  static const List<int> _expThresholds = [
    1000, 3000, 7000, 15000, 31000, 63000, 127000, 255000,
  ];

  String get _levelDesc {
    final lv = AuthService.instance.level;
    final exp = AuthService.instance.totalExp;
    if (lv <= 0) return '未通过入站考核（L0）· 通过考核升级 L1';
    if (lv >= 9) return '已满级（L9）· 累计经验 $exp';
    final next = _expThresholds[lv - 1];
    return '当前经验 $exp · 距 L${lv + 1} 还需 ${next - exp}';
  }

  double get _levelProgress {
    final lv = AuthService.instance.level;
    if (lv <= 0) return 0;
    if (lv >= 9) return 1;
    final next = _expThresholds[lv - 1];
    final prev = lv <= 1 ? 0 : _expThresholds[lv - 2];
    final p = (AuthService.instance.totalExp - prev) / (next - prev);
    return p.clamp(0.0, 1.0);
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
                  leading: Icons.military_tech_rounded,
                  onPressed: (_) => context.pushNamed('/settings/exam/'),
                  title: Text('等级 L${AuthService.instance.level}'),
                  description: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_levelDesc),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _levelProgress,
                          minHeight: 6,
                        ),
                      ),
                    ],
                  ),
                ),
                SettingsTile(
                  leading: Icons.account_box_rounded,
                  onPressed: (_) => _editProfile(),
                  title: Text(
                    AuthService.instance.nickname.isNotEmpty
                        ? '${AuthService.instance.nickname}（${_vipLabel}）'
                        : '编辑资料',
                  ),
                  description: Text('昵称 / 头像 · 邀请码 ${AuthService.instance.inviteCode}'),
                ),
                SettingsTile(
                  leading: Icons.mail_outline_rounded,
                  onPressed: (_) {},
                  title: const Text('邮箱'),
                  description: Text(_email),
                ),
                SettingsTile(
                  leading: Icons.workspace_premium_rounded,
                  onPressed: (_) => _openTitleSelect(),
                  title: const Text('头衔'),
                  description: Text(AuthService.instance.title),
                ),
                SettingsTile(
                  leading: Icons.redeem_rounded,
                  onPressed: (_) => context.pushNamed('/settings/redeem/'),
                  title: const Text('兑换码'),
                  description: const Text('兑换积分与赞助用户时长'),
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