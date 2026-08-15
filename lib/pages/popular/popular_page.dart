import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/bangumi_mirror_error_widget.dart';
import 'package:kazumi/bean/widget/custom_dropdown_menu.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';
import 'package:kazumi/bean/card/bangumi_card.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/random_anime_service.dart';
import 'package:kazumi/services/remote/messages_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/bean/appbar/drag_to_move_bar.dart' as dtb;
import 'package:kazumi/utils/device.dart';

class PopularPage extends StatefulWidget {
  const PopularPage({
    super.key,
    required this.controller,
  });

  final PopularController controller;

  @override
  State<PopularPage> createState() => _PopularPageState();
}

class _PopularPageState extends State<PopularPage> with WidgetsBindingObserver {
  late final ScrollController scrollController;
  PopularController get popularController => widget.controller;

  // Key used to position the dropdown menu for the tag selector
  final GlobalKey selectorKey = GlobalKey();

  /// 随机番剧模式
  static const String kRandomTag = '🎲 随机番剧';
  bool _randomMode = false;
  List<BangumiItem> _randomItems = [];
  bool _randomLoading = false;
  bool _randomError = false;
  List<String> _randomTags = [];
  int _randomYearMin = 0;
  int _randomYearMax = 0;

  /// 未读消息数（主页右上角信封红点）
  int _unreadCount = 0;

  /// 未读数轮询定时器（每 60 秒静默刷新，保证主页常驻显示）
  Timer? _unreadTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    scrollController = ScrollController(
      initialScrollOffset: popularController.scrollOffset,
    );
    scrollController.addListener(scrollListener);
    if (popularController.trendList.isEmpty) {
      popularController.queryBangumiByTrend();
    }
    _refreshUnread();
    // 账号数据变更（兑换码/登录/登出）时立即刷新未读徽章
    MessagesService.onDataChanged = _refreshUnread;
    // 定时刷新未读数（App 前台期间保持新鲜）
    _unreadTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) _refreshUnread();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从后台回到前台立即刷新未读数
    if (state == AppLifecycleState.resumed && mounted) {
      _refreshUnread();
    }
  }

  /// 拉取未读消息数（未登录时忽略）
  Future<void> _refreshUnread() async {
    final loggedIn =
        GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty;
    if (!loggedIn) {
      if (mounted && _unreadCount != 0) {
        setState(() => _unreadCount = 0);
      }
      return;
    }
    try {
      final result = await MessagesService.instance.list(
        type: MessageType.all,
        limit: 1,
      );
      if (mounted) {
        final badge = MessagesService.badgeUnread(result.unreadCount);
        if (badge != _unreadCount) {
          setState(() => _unreadCount = badge);
        }
      }
    } catch (_) {
      // 静默
    }
  }

  /// 打开消息中心，返回后刷新未读数
  Future<void> _openMessages() async {
    final loggedIn =
        GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty;
    if (!loggedIn) {
      KazumiDialog.showToast(message: '请先登录账号');
      await context.pushNamed('/settings/account/');
      return;
    }
    await context.pushNamed('/messages/');
    _refreshUnread();
  }

  // ==================== 随机番剧 ====================

  Future<void> _loadRandom() async {
    setState(() {
      _randomLoading = true;
      _randomError = false;
    });
    try {
      final items = await RandomAnimeService.instance.fetch(
        tags: _randomTags,
        yearMin: _randomYearMin,
        yearMax: _randomYearMax,
        count: 30,
      );
      if (!mounted) return;
      setState(() {
        _randomItems = items;
        _randomLoading = false;
      });
      if (items.isEmpty) {
        KazumiDialog.showToast(message: '没有符合条件的番剧，换个筛选试试');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _randomError = true;
        _randomLoading = false;
      });
    }
  }

  void _enterRandomMode() {
    setState(() {
      _randomMode = true;
      _randomItems = [];
    });
    _loadRandom();
  }

  void _exitRandomMode() {
    setState(() {
      _randomMode = false;
      _randomItems = [];
      _randomTags = [];
      _randomYearMin = 0;
      _randomYearMax = 0;
    });
  }

  /// 随机番剧筛选对话框：tag 多选 + 年份区间
  Future<void> _showRandomFilter() async {
    final result = await showDialog<({List<String> tags, int yearMin, int yearMax})>(
      context: context,
      builder: (dialogContext) => _RandomFilterDialog(
        initialTags: _randomTags,
        initialYearMin: _randomYearMin,
        initialYearMax: _randomYearMax,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _randomTags = result.tags;
      _randomYearMin = result.yearMin;
      _randomYearMax = result.yearMax;
    });
    _loadRandom();
  }

  @override
  void dispose() {
    _unreadTimer?.cancel();
    if (MessagesService.onDataChanged == _refreshUnread) {
      MessagesService.onDataChanged = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    scrollController.removeListener(scrollListener);
    scrollController.dispose();
    super.dispose();
  }

  void scrollListener() {
    popularController.scrollOffset = scrollController.offset;
    if (scrollController.position.pixels >=
            scrollController.position.maxScrollExtent - 200 &&
        !popularController.isLoadingMore) {
      KazumiLogger()
          .i('PopularPageController: Fetching next recommendation batch');
      if (popularController.currentTag != '') {
        popularController.queryBangumiByTag();
      } else {
        popularController.queryBangumiByTrend();
      }
    }
  }

  bool showWindowButton() {
    return GStorage.getSetting(SettingsKeys.showWindowButton);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        controller: scrollController,
        slivers: [
          buildSliverAppBar(),
          SliverToBoxAdapter(
            child: Observer(
              builder: (_) => AnimatedOpacity(
                opacity: popularController.isLoadingMore ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: popularController.isLoadingMore
                    ? const LinearProgressIndicator(minHeight: 4)
                    : const SizedBox(height: 4),
              ),
            ),
          ),
          SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                  StyleString.cardSpace, 0, StyleString.cardSpace, 0),
              sliver: Observer(builder: (_) {
                if (_randomMode) {
                  if (_randomLoading) {
                    return const SliverToBoxAdapter(
                      child: SizedBox(
                        height: 300,
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    );
                  }
                  if (_randomError) {
                    return SliverToBoxAdapter(
                      child: SizedBox(
                        height: 300,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('随机番剧加载失败'),
                              const SizedBox(height: 8),
                              FilledButton.tonal(
                                onPressed: _loadRandom,
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                  if (_randomItems.isEmpty) {
                    return const SliverToBoxAdapter(
                      child: SizedBox(
                        height: 200,
                        child: Center(child: Text('没有符合条件的番剧，点击筛选调整范围')),
                      ),
                    );
                  }
                  return contentGrid(_randomItems);
                }
                if (popularController.isTimeOut) {
                  return SliverToBoxAdapter(
                    child: SizedBox(
                      height: 400,
                      child: BangumiMirrorErrorWidget(
                        onRetry: () {
                          if (popularController.trendList.isEmpty) {
                            popularController.queryBangumiByTrend();
                          } else {
                            popularController.queryBangumiByTag();
                          }
                        },
                        onSettingsReturned: () {
                          if (mounted) {
                            setState(() {});
                          }
                        },
                      ),
                    ),
                  );
                }
                return contentGrid(
                  (popularController.currentTag == '')
                      ? popularController.trendList
                      : popularController.bangumiList,
                );
              })),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => scrollController.animateTo(0,
            duration: const Duration(milliseconds: 350), curve: Curves.easeOut),
        child: const Icon(Icons.arrow_upward),
      ),
    );
  }

  Widget contentGrid(List<BangumiItem> bangumiList) {
    int crossCount = 3;
    if (MediaQuery.sizeOf(context).width > LayoutBreakpoint.compact['width']!) {
      crossCount = 5;
    }
    if (MediaQuery.sizeOf(context).width > LayoutBreakpoint.medium['width']!) {
      crossCount = 6;
    }
    return SliverPadding(
      padding: const EdgeInsets.all(8),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          // 行间距
          mainAxisSpacing: StyleString.cardSpace - 2,
          // 列间距
          crossAxisSpacing: StyleString.cardSpace,
          // 列数
          crossAxisCount: crossCount,
          mainAxisExtent:
              MediaQuery.of(context).size.width / crossCount / 0.65 +
                  MediaQuery.textScalerOf(context).scale(32.0),
        ),
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) {
            return bangumiList.isNotEmpty
                ? BangumiCardV(bangumiItem: bangumiList[index])
                : null;
          },
          childCount: bangumiList.isNotEmpty ? bangumiList.length : 10,
        ),
      ),
    );
  }

  Widget buildSliverAppBar() {
    final theme = Theme.of(context);
    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: 120,
      elevation: 0,
      titleSpacing: 0,
      centerTitle: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      actions: buildActions(),
      title: null,
      flexibleSpace: SafeArea(
        child: dtb.DragToMoveArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double maxExtent = 120 - MediaQuery.of(context).padding.top;
              final t = (1 -
                  ((constraints.maxHeight - kToolbarHeight) /
                          (maxExtent - kToolbarHeight))
                      .clamp(0.0, 1.0));
              // 字重收缩后为 w500，展开时为 w700
              final fontWeight = t < 0.5 ? FontWeight.w700 : FontWeight.w500;
              final fontSize = lerpDouble(28, 20, t)!;
              return Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(
                      left: 16, top: 8, bottom: 8, right: 60),
                    child: SizedBox(
                      height: 44,
                      child: Observer(
                        builder: (_) {
                          if (_randomMode) {
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                InkWell(
                                  key: selectorKey,
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: showTagMenu,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '随机番剧',
                                        style: theme.textTheme.headlineMedium!
                                            .copyWith(
                                          fontWeight: fontWeight,
                                          fontSize: fontSize,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Icon(Icons.keyboard_arrow_down,
                                          size: fontSize,
                                          color: theme.iconTheme.color),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  tooltip: '筛选（tag/年份）',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: _showRandomFilter,
                                  icon: const Icon(Icons.tune_rounded, size: 20),
                                ),
                                IconButton(
                                  tooltip: '重新随机',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: _randomLoading ? null : _loadRandom,
                                  icon: const Icon(Icons.refresh_rounded,
                                      size: 20),
                                ),
                              ],
                            );
                          }
                          final bool isTrend =
                              popularController.currentTag == '';
                          return InkWell(
                            key: selectorKey,
                            borderRadius: BorderRadius.circular(8),
                            onTap: showTagMenu,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  isTrend
                                      ? '热门番组'
                                      : popularController.currentTag,
                                  style: theme.textTheme.headlineMedium!
                                      .copyWith(
                                    fontWeight: fontWeight,
                                    fontSize: fontSize,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(Icons.keyboard_arrow_down,
                                    size: fontSize,
                                    color: theme.iconTheme.color),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  List<Widget> buildActions() {
    final actions = <Widget>[
      if (MediaQuery.of(context).orientation == Orientation.portrait)
        IconButton(
          tooltip: '搜索',
          onPressed: () => context.pushNamed('/search/'),
          icon: const Icon(Icons.search),
        ),
      IconButton(
        tooltip: '消息',
        onPressed: _openMessages,
        icon: Badge(
          isLabelVisible: _unreadCount > 0,
          label: Text(
            _unreadCount > 99 ? '99+' : '$_unreadCount',
            style: const TextStyle(fontSize: 10),
          ),
          child: const Icon(Icons.mail_outline_rounded),
        ),
      ),
    ];
    actions.add(
      IconButton(
        tooltip: '历史记录',
        onPressed: () => context.pushNamed('/settings/history/'),
        icon: const Icon(Icons.history),
      ),
    );
    if (isDesktop()) {
      if (!showWindowButton()) {
        actions.add(
          IconButton(
            tooltip: '退出',
            onPressed: () => windowManager.close(),
            icon: const Icon(Icons.close),
          ),
        );
      }
    }
    return actions;
  }

  Future<void> showTagMenu() async {
    // Calculate the position of the button manually to position the dropdown menu.
    // Using CustomDropdownMenu instead of PopupMenuButton to avoid flickering issues
    // and to support different font sizes in the button and menu items.
    final RenderBox renderBox =
        selectorKey.currentContext!.findRenderObject() as RenderBox;
    final Offset offset = renderBox.localToGlobal(Offset.zero);
    final Size size = renderBox.size;

    final selected = await Navigator.push<String>(
      context,
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.transparent,
        pageBuilder: (context, animation, secondaryAnimation) {
          return CustomDropdownMenu(
            offset: offset,
            buttonSize: size,
            animation: animation,
            maxWidth: 80,
            items: [
              '',
              kRandomTag,
              ...defaultAnimeTags,
            ],
            itemBuilder: (item) => item.isEmpty ? '热门番组' : item,
          );
        },
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 150),
      ),
    );

    if (selected == null) return;
    // 随机番剧模式切换
    if (selected == kRandomTag) {
      if (_randomMode) {
        _exitRandomMode();
      } else {
        _enterRandomMode();
      }
      return;
    }
    if (_randomMode) {
      _exitRandomMode();
    }
    if (selected == '' && popularController.currentTag != '') {
      scrollController.animateTo(0,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      popularController.setCurrentTag('');
      popularController.clearBangumiList();
      if (popularController.trendList.isEmpty) {
        await popularController.queryBangumiByTrend();
      }
    } else if (selected != '' && selected != popularController.currentTag) {
      scrollController.animateTo(0,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      popularController.setCurrentTag(selected);
      await popularController.queryBangumiByTag(type: 'init');
    }
  }
}

/// 随机番剧筛选对话框：tag 多选 + 年份区间
class _RandomFilterDialog extends StatefulWidget {
  const _RandomFilterDialog({
    required this.initialTags,
    required this.initialYearMin,
    required this.initialYearMax,
  });

  final List<String> initialTags;
  final int initialYearMin;
  final int initialYearMax;

  @override
  State<_RandomFilterDialog> createState() => _RandomFilterDialogState();
}

class _RandomFilterDialogState extends State<_RandomFilterDialog> {
  late final Set<String> _tags = widget.initialTags.toSet();
  late int _yearMin = widget.initialYearMin;
  late int _yearMax = widget.initialYearMax;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return AlertDialog(
      title: const Text('随机范围'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'TAG（可多选，留空=全部）',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in defaultAnimeTags)
                    FilterChip(
                      label: Text(tag, style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      selected: _tags.contains(tag),
                      onSelected: (v) => setState(() {
                        if (v) {
                          _tags.add(tag);
                        } else {
                          _tags.remove(tag);
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '年份区间',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _yearMin == 0 ? 0 : _yearMin,
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: '起始年',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: 0,
                          child: Text('不限'),
                        ),
                        for (final y in _years())
                          DropdownMenuItem(value: y, child: Text('$y')),
                      ],
                      onChanged: (v) => setState(() => _yearMin = v ?? 0),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _yearMax == 0 ? 0 : _yearMax,
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: '结束年',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: 0,
                          child: Text('不限'),
                        ),
                        for (final y in _years())
                          DropdownMenuItem(value: y, child: Text('$y')),
                      ],
                      onChanged: (v) => setState(() => _yearMax = v ?? 0),
                    ),
                  ),
                ],
              ),
              if (_yearMin > 0 && _yearMax > 0 && _yearMin > _yearMax)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '起始年不能大于结束年',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            '取消',
            style: TextStyle(color: colorScheme.outline),
          ),
        ),
        TextButton(
          onPressed: () {
            if (_yearMin > 0 && _yearMax > 0 && _yearMin > _yearMax) return;
            Navigator.of(context).pop(
              (
                tags: _tags.toList(),
                yearMin: _yearMin,
                yearMax: _yearMax,
              ),
            );
          },
          child: const Text('确定'),
        ),
      ],
    );
  }

  List<int> _years() {
    final now = DateTime.now().year;
    return [for (var y = now; y >= 1980; y--) y];
  }
}
