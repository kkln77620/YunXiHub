import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/remote/auth_service.dart';

/// YunXiHub 账号登录页
///
/// 三种模式：登录 / 注册（邮箱验证码）/ 忘记密码（验证码重置）
/// 登录或注册成功后保存 token 并返回。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

enum _AuthMode { login, register, reset }

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  _AuthMode _mode = _AuthMode.login;
  late TabController _tabController;

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();
  final _inviteController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _submitting = false;
  bool _obscure = true;
  int _countdown = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(() {
        if (!_tabController.indexIsChanging) return;
        setState(() {
          _mode = _tabController.index == 0 ? _AuthMode.login : _AuthMode.register;
        });
      });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tabController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    _inviteController.dispose();
    super.dispose();
  }

  void _startCountdown() {
    setState(() => _countdown = 60);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_countdown <= 1) {
        t.cancel();
        setState(() => _countdown = 0);
      } else {
        setState(() => _countdown--);
      }
    });
  }

  bool get _needCode => _mode != _AuthMode.login;

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (!_isEmail(email)) {
      KazumiDialog.showToast(message: '请输入正确的邮箱');
      return;
    }
    if (_countdown > 0) return;
    try {
      setState(() => _submitting = true);
      final purpose = _mode == _AuthMode.reset ? 'reset' : 'register';
      final msg = await AuthService.instance.sendCode(email, purpose: purpose);
      _startCountdown();
      KazumiDialog.showToast(message: msg);
    } on AuthException catch (e) {
      KazumiDialog.showToast(message: e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    setState(() => _submitting = true);
    try {
      switch (_mode) {
        case _AuthMode.login:
          await AuthService.instance.login(email: email, password: password);
          if (mounted) {
            Navigator.of(context).pop(true);
            KazumiDialog.showToast(message: '登录成功');
          }
        case _AuthMode.register:
          await AuthService.instance.register(
            email: email,
            code: _codeController.text.trim(),
            password: password,
            inviteCode: _inviteController.text.trim(),
          );
          if (mounted) {
            Navigator.of(context).pop(true);
            KazumiDialog.showToast(message: '注册成功，已自动登录');
          }
        case _AuthMode.reset:
          await AuthService.instance.reset(
            email: email,
            code: _codeController.text.trim(),
            newPassword: password,
          );
          if (mounted) {
            setState(() {
              _mode = _AuthMode.login;
              _tabController.index = 0;
              _codeController.clear();
            });
            KazumiDialog.showToast(message: '密码已重置，请用新密码登录');
          }
      }
    } on AuthException catch (e) {
      KazumiDialog.showToast(message: e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  bool _isEmail(String s) {
    return RegExp(r'^[\w.+-]+@[\w-]+(\.[\w-]+)+$').hasMatch(s);
  }

  String? _validateEmail(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return '请输入邮箱';
    if (!_isEmail(s)) return '邮箱格式不正确';
    return null;
  }

  String? _validatePassword(String? v) {
    if ((v ?? '').length < 6) return '密码至少 6 位';
    return null;
  }

  String? _validateCode(String? v) {
    if ((v ?? '').trim().isEmpty) return '请输入验证码';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_mode == _AuthMode.login
            ? '登录'
            : _mode == _AuthMode.register
                ? '注册'
                : '重置密码'),
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Icon(
                  Icons.account_circle_rounded,
                  size: 72,
                  color: colorScheme.primary,
                ),
                const SizedBox(height: 8),
                Text(
                  'YunXiHub',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),
                if (_mode == _AuthMode.login) ...[
                  TabBar(
                    controller: _tabController,
                    tabs: const [
                      Tab(text: '登录'),
                      Tab(text: '注册'),
                    ],
                  ),
                  const SizedBox(height: 16),
                ] else if (_mode == _AuthMode.register) ...[
                  TabBar(
                    controller: _tabController,
                    tabs: const [
                      Tab(text: '登录'),
                      Tab(text: '注册'),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: '邮箱',
                    prefixIcon: Icon(Icons.mail_outline_rounded),
                    border: OutlineInputBorder(),
                  ),
                  validator: _validateEmail,
                ),
                const SizedBox(height: 12),
                if (_needCode) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _codeController,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          decoration: const InputDecoration(
                            labelText: '验证码',
                            prefixIcon: Icon(Icons.sms_outlined),
                            border: OutlineInputBorder(),
                            counterText: '',
                          ),
                          validator: _validateCode,
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        height: 56,
                        child: OutlinedButton(
                          onPressed: _countdown > 0 || _submitting
                              ? null
                              : _sendCode,
                          child: Text(_countdown > 0 ? '${_countdown}s' : '发送验证码'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: _mode == _AuthMode.reset ? '新密码' : '密码',
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: _validatePassword,
                ),
                if (_mode == _AuthMode.register) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _inviteController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: '邀请码（选填）',
                      helperText: '填写邀请码注册可获 100 积分奖励',
                      prefixIcon: Icon(Icons.card_giftcard_rounded),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _mode == _AuthMode.login
                              ? '登录'
                              : _mode == _AuthMode.register
                                  ? '注册'
                                  : '重置密码',
                        ),
                ),
                const SizedBox(height: 12),
                if (_mode == _AuthMode.login)
                  Align(
                    alignment: Alignment.center,
                    child: TextButton(
                      onPressed: () {
                        setState(() => _mode = _AuthMode.reset);
                        _tabController.index = 0;
                        _codeController.clear();
                      },
                      child: const Text('忘记密码？'),
                    ),
                  )
                else if (_mode == _AuthMode.reset)
                  Align(
                    alignment: Alignment.center,
                    child: TextButton(
                      onPressed: () {
                        setState(() => _mode = _AuthMode.login);
                        _codeController.clear();
                      },
                      child: const Text('返回登录'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}