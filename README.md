<div align=center>

<h1>YunXiHub</h1>

<img src="assets/images/logo/logo_rounded.png" width=200></img>

<img src="https://img.shields.io/badge/Flutter-03A9F4?style=for-the-badge&logo=flutter&logoColor=white"></img>
<img src="https://img.shields.io/badge/Dart-00B4AB?style=for-the-badge&logo=Dart&logoColor=white"></img>
<img src="https://img.shields.io/badge/Python-Flask-3776AB?style=for-the-badge&logo=python&logoColor=white"></img>
<img src="https://img.shields.io/badge/SQLite-003B57?style=for-the-badge&logo=sqlite&logoColor=white"></img>

<p>基于 <a href="https://github.com/Predidit/Kazumi">Kazumi</a> 二次开发的番剧聚合播放器，内置社区评论、用户等级体系、入站考核、积分兑换与云同步后台。</p>
</div>

## 📥 下载

🌐 官网（含安装说明）：**https://yunxi.yunxiapp.eu.cc**

点击官网「立即下载」按钮获取最新版 APK（v3.3.0 · 68.7MB · Android 7.0+）。

## ✨ 特色功能

### 播放与解析（继承 Kazumi）
- 基于 Xpath 规则的多源聚合播放
- 番剧搜索 / 目录 / 时间表 / 弹幕 / 字幕
- 倍速播放、超分辨率、一起看、番剧下载
- 自定义规则导入与分享

### 云后台（自建 Flask 服务）
- **账号体系**：邮箱注册登录、uid 10001 起、昵称/头像
- **等级体系 L0-L9**：入站考核（随机 50 题·80 分及格）→ L1，经验升级（观看/签到/分享/拉新）
- **等级权益**：L0 禁发评论；L1 可发评论·可举报；L2 可点赞；L3/L4 放宽条数/字数/图片限制（管理员豁免）
- **社区评论**：番剧/剧集/角色多区域评论、回复嵌套、点赞举报、@提醒、消息通知、剧透遮挡
- **积分体系**：签到 / 分享 / 观看时长 / 拉新奖励
- **兑换码**：单次码 / 多次码，兑换积分与赞助时长
- **云同步**：历史记录、追番收藏（登录用户 + 游客设备双通道）
- **远程更新**：版本检测、APK 分发、弹窗公告、崩溃上报、数据统计

### 服务器架构
- Flask + SQLite，按功能域分 5 库（账号 / 社区 / 考核 / 云同步 / 更新分发）
- Cloudflare Tunnel 公网接入，无需公网 IP
- 考卷快照判卷机制：抽题时记录答案位置，客户端零作弊可能

## 🖥️ 支持平台

- Android 7.0 及以上（当前分发渠道）

## 🔨 自行构建

```bash
# Flutter 环境
flutter pub get
flutter build apk --release
```

> 本项目构建需良好网络环境，国内可能需要配置镜像。

## 📄 免责声明

本项目基于 GNU 通用公共许可证第 3 版（GPL-3.0）授权，由 Kazumi 二次开发而来。

本项目不提供、不存储任何视频内容，仅提供规则解析与播放框架。使用本项目需遵守所在地法律法规，不得进行任何侵犯第三方知识产权的行为。因使用本项目而产生的数据和缓存应在24小时内清除，超出 24 小时的使用需获得相关权利人的授权。

## 🙏 致谢

- [Kazumi](https://github.com/Predidit/Kazumi) — 本项目的基础播放框架
- [XpathSelector](https://github.com/simonkimi/xpath_selector) — Xpath 规则解析
- [弹弹play](https://www.dandanplay.com/) — 弹幕交互
- [Bangumi](https://bangumi.tv/) — 番剧元数据
