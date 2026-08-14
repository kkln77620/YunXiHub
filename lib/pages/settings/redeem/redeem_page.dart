import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 兑换码页：输入兑换码 → 兑换积分 / 赞助时长（单次码 / 多次码）
class RedeemPage extends StatefulWidget {
  const RedeemPage({super.key});

  @override
  State<RedeemPage> createState() => _RedeemPageState();
}

class _RedeemPageState extends State<RedeemPage> {
  final TextEditingController _codeController = TextEditingController();
  bool _submitting = false;

  Dio get _dio {
    final token = GStorage.getSetting(SettingsKeys.authToken).trim();
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      },
    ));
  }

  String get _baseUrl {
    var base = GStorage.getSetting(SettingsKeys.remoteResolverBaseUrl).trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  Future<void> _redeem() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      KazumiDialog.showToast(message: '请输入兑换码');
      return;
    }
    final token = GStorage.getSetting(SettingsKeys.authToken).trim();
    if (token.isEmpty) {
      KazumiDialog.showToast(message: '请先登录账号');
      return;
    }
    setState(() => _submitting = true);
    try {
      final resp = await _dio.post<dynamic>(
        '$_baseUrl/api/redeem',
        data: {'code': code},
      );
      final data = (resp.data is Map)
          ? (resp.data as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      KazumiDialog.showToast(
          message: data['msg']?.toString() ?? '兑换失败');
      if (data['code'] == 0) {
        _codeController.clear();
      }
    } catch (_) {
      KazumiDialog.showToast(message: '兑换失败，请检查网络');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: SysAppBar(title: const Text('兑换码')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('兑换码', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    '输入兑换码可兑换积分与赞助用户时长',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _codeController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      hintText: '例如：ABCD1234EFGH',
                      prefixIcon: Icon(Icons.confirmation_number_rounded),
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _redeem(),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _submitting ? null : _redeem,
                      icon: _submitting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.redeem_rounded),
                      label: Text(_submitting ? '兑换中...' : '立即兑换'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '提示：兑换码分为单次码（仅限一人使用）与多次码（可多人使用），兑换后积分与赞助时长自动到账。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}