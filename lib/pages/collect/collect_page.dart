import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/bean/card/bangumi_card.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/widget/collect_button.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/services/remote/collect_sync_service.dart';
import 'package:kazumi/services/storage/storage.dart';

class CollectPage extends StatefulWidget {
  const CollectPage({
    super.key,
    required this.controller,
  });

  final CollectController controller;

  @override
  State<CollectPage> createState() => _CollectPageState();
}

class _CollectPageState extends State<CollectPage>
    with SingleTickerProviderStateMixin {
  CollectController get collectController => widget.controller;
  TabController? tabController;
  bool showDelete = false;
  bool syncCollectiblesing = false;

  Future<void> _syncWithCloud() async {
    if (syncCollectiblesing) return;
    setState(() => syncCollectiblesing = true);
    try {
      final ok = await CollectSyncService.instance.syncNow();
      if (!mounted) return;
      KazumiDialog.showToast(
        message: ok ? '追番云同步完成' : '追番云同步失败，请检查网络后重试',
      );
    } finally {
      if (mounted) setState(() => syncCollectiblesing = false);
    }
  }

  @override
  void initState() {
    super.initState();
    collectController.loadCollectibles();
    // 云同步完成后自动刷新列表
    CollectSyncService.instance.syncedVersion.addListener(_onCloudSynced);
    tabController = TabController(vsync: this, length: tabs.length);
  }

  void _onCloudSynced() {
    if (!mounted) return;
    collectController.loadCollectibles();
  }

  @override
  void dispose() {
    CollectSyncService.instance.syncedVersion.removeListener(_onCloudSynced);
    tabController?.dispose();
    super.dispose();
  }

  final List<Tab> tabs = const <Tab>[
    Tab(text: '在看'),
    Tab(text: '想看'),
    Tab(text: '搁置'),
    Tab(text: '看过'),
    Tab(text: '抛弃'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SysAppBar(
        needTopOffset: false,
        toolbarHeight: 104,
        bottom: TabBar(
          controller: tabController,
          tabs: tabs,
          indicatorColor: Theme.of(context).colorScheme.primary,
        ),
        title: const Text('追番'),
        actions: [
          IconButton(
              onPressed: () {
                setState(() {
                  showDelete = !showDelete;
                });
              },
              icon: showDelete
                  ? const Icon(Icons.edit_outlined)
                  : const Icon(Icons.edit))
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          if (showDelete) {
            KazumiDialog.showToast(message: '编辑模式无法执行同步');
            return;
          }
          await _syncWithCloud();
        },
        child: syncCollectiblesing
            ? const SizedBox(
                width: 32, height: 32, child: CircularProgressIndicator())
            : const Icon(Icons.sync_rounded),
      ),
      body: Observer(builder: (context) {
        return renderBody;
      }),
    );
  }

  Widget get renderBody {
    if (collectController.collectibles.isNotEmpty) {
      return TabBarView(
        controller: tabController,
        children: contentGrid(collectController.collectibles),
      );
    } else {
      return const Center(
        child: GeneralEmptyState(
          icon: Icons.favorite_border_rounded,
          title: '暂无追番内容',
        ),
      );
    }
  }

  List<Widget> contentGrid(List<CollectedBangumi> collectedBangumiList) {
    final bool showAnimeCounter =
        GStorage.getSetting(SettingsKeys.showAnimeCounter);
    List<Widget> gridViewList = [];
    List<List<CollectedBangumi>> collectedBangumiRenderItemList =
        List.generate(tabs.length, (_) => <CollectedBangumi>[]);
    for (CollectedBangumi element in collectedBangumiList) {
      collectedBangumiRenderItemList[element.type - 1].add(element);
    }
    for (List<CollectedBangumi> list in collectedBangumiRenderItemList) {
      list.sort((a, b) => b.time.millisecondsSinceEpoch
          .compareTo(a.time.millisecondsSinceEpoch));
    }
    int crossCount = 3;
    if (MediaQuery.sizeOf(context).width > LayoutBreakpoint.compact['width']!) {
      crossCount = 5;
    }
    if (MediaQuery.sizeOf(context).width > LayoutBreakpoint.medium['width']!) {
      crossCount = 6;
    }
    for (List<CollectedBangumi> collectedBangumiRenderItem
        in collectedBangumiRenderItemList) {
      gridViewList.add(
        CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(StyleString.cardSpace,
                  StyleString.cardSpace, StyleString.cardSpace, 0),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  mainAxisSpacing: StyleString.cardSpace - 2,
                  crossAxisSpacing: StyleString.cardSpace,
                  crossAxisCount: crossCount,
                  mainAxisExtent:
                      MediaQuery.of(context).size.width / crossCount / 0.65 +
                          MediaQuery.textScalerOf(context).scale(32.0),
                ),
                delegate: SliverChildBuilderDelegate(
                  (BuildContext context, int index) {
                    return collectedBangumiRenderItem.isNotEmpty
                        ? Stack(
                            children: [
                              BangumiCardV(
                                bangumiItem: collectedBangumiRenderItem[index]
                                    .bangumiItem,
                                canTap: !showDelete,
                              ),
                              Positioned(
                                right: 5,
                                bottom: 5,
                                child: showDelete
                                    ? Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .secondaryContainer,
                                          shape: BoxShape.circle,
                                        ),
                                        child: CollectButton(
                                          bangumiItem:
                                              collectedBangumiRenderItem[index]
                                                  .bangumiItem,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSecondaryContainer,
                                        ),
                                      )
                                    : Container(),
                              ),
                            ],
                          )
                        : null;
                  },
                  childCount: collectedBangumiRenderItem.isNotEmpty
                      ? collectedBangumiRenderItem.length
                      : 10,
                ),
              ),
            ),
            if (collectedBangumiRenderItem.isNotEmpty && showAnimeCounter)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 12),
                      child: Text(
                        '总计：${collectedBangumiRenderItem.length}',
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    }
    return gridViewList;
  }
}
