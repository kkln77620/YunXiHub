import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 入站考核页：随机 50 题 × 2 分，80 分通过 → 升级 L1（每小时可考一次）
class ExamPage extends StatefulWidget {
  const ExamPage({super.key});

  @override
  State<ExamPage> createState() => _ExamPageState();
}

class _ExamPageState extends State<ExamPage> {
  List<Map<String, dynamic>> _questions = [];
  final Map<int, int> _answers = {}; // qid -> 选项索引
  bool _loading = true;
  bool _error = false;
  String _errorMsg = '';
  bool _submitting = false;
  String _rule = '';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final resp = await _dio.get<dynamic>('$_baseUrl/api/exam/questions');
      final data = (resp.data is Map)
          ? (resp.data as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      if (data['code'] == 0) {
        final items = data['items'] as List? ?? [];
        if (mounted) {
          setState(() {
            _questions = [
              for (final it in items)
                if (it is Map) it.cast<String, dynamic>()
            ];
            _rule = data['rule']?.toString() ?? '';
            _loading = false;
          });
        }
      } else if (data['code'] == 3) {
        // 已通过考核
        if (mounted) {
          setState(() {
            _error = true;
            _errorMsg = data['msg']?.toString() ?? '你已通过入站考核';
            _loading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _error = true;
            _errorMsg = data['msg']?.toString() ?? '加载失败';
            _loading = false;
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = true;
          _errorMsg = '网络错误，请稍后重试';
          _loading = false;
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (_answers.length < _questions.length) {
      KazumiDialog.showToast(
          message: '还有 ${_questions.length - _answers.length} 题未作答');
      return;
    }
    setState(() => _submitting = true);
    try {
      final resp = await _dio.post<dynamic>(
        '$_baseUrl/api/exam/submit',
        data: {
          'answers': {
            for (final q in _questions) '${q['id']}': _answers[q['id']] ?? -1,
          },
        },
      );
      final data = (resp.data is Map)
          ? (resp.data as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      if (data['code'] == 0) {
        final passed = (data['passed'] as num?)?.toInt() == 1;
        final score = (data['score'] as num?)?.toInt() ?? 0;
        await _refreshLocalUser();
        if (mounted) {
          showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(passed ? '🎉 考核通过' : '未通过'),
              content: Text(
                passed
                    ? '得分 $score 分，已升级为 L1！\n现在可以正常发表评论了。'
                    : '得分 $score 分（需 80 分）\n1 小时后可重新参加考核。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('知道了'),
                ),
              ],
            ),
          );
        }
      } else {
        KazumiDialog.showToast(
            message: data['msg']?.toString() ?? '提交失败');
      }
    } catch (_) {
      KazumiDialog.showToast(message: '提交失败，请检查网络');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 提交成功后刷新本地账号信息（level/exam_passed）
  Future<void> _refreshLocalUser() async {
    try {
      final resp = await _dio.get<dynamic>('$_baseUrl/api/auth/me');
      final data = (resp.data is Map)
          ? (resp.data as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      if (data['code'] == 0 && data['data'] is Map) {
        final user = (data['data'] as Map).cast<String, dynamic>();
        await GStorage.putSetting(
            SettingsKeys.authLevel, (user['level'] as num?)?.toInt() ?? 0);
        await GStorage.putSetting(
            SettingsKeys.authTotalExp,
            (user['total_exp'] as num?)?.toInt() ?? 0);
        await GStorage.putSetting(SettingsKeys.authExamPassed,
            (user['exam_passed'] as num?)?.toInt() ?? 0);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SysAppBar(title: const Text('入站考核')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.school_rounded, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(_errorMsg,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _load,
                child: const Text('刷新'),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _rule,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                '答题进度：${_answers.length}/${_questions.length}',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: _questions.length,
            itemBuilder: (context, index) {
              final q = _questions[index];
              final qid = (q['id'] as num?)?.toInt() ?? index;
              final options = (q['options'] as List?)?.cast<String>() ?? [];
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${index + 1}. ${q['question']}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 4),
                      for (var i = 0; i < options.length; i++)
                        RadioListTile<int>(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${String.fromCharCode(65 + i)}. ${options[i]}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          value: i,
                          groupValue: _answers[qid],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => _answers[qid] = v);
                          },
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
                label: Text(_submitting ? '提交中...' : '提交答卷'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}