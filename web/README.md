# 语音狗子官网

`https://coolboylcy.github.io/voice-doggo/`

Vite + 原生 HTML/CSS/JS，没有框架。`main` 分支上 `web/` 有改动就自动部署
（见 `.github/workflows/pages.yml`）。

```bash
npm install
npm run dev       # 本地开发
npm run verify    # 构建 + 体检，部署前跑这个
```

## 两件容易踩的事

**版本号不要写死。** 页面上的版本号、JSON-LD 的 `softwareVersion`、埋点里的
version，全都从仓库根目录的 `project.yml` 读（`vite.config.js` 在构建时注入
`%APP_VERSION%` 和 `__APP_VERSION__`）。官网写着 1.0.0 而 App 已经发到 1.1.0
这种事发生过一次，抄三遍必然漏一处。

**下载链接用固定名的最新版资产**：

```
https://github.com/coolboylcy/voice-doggo/releases/latest/download/VoiceDoggo.dmg
```

`scripts/publish-release.sh` 每次发版都会额外传一份固定文件名的副本，所以这条
地址永远指向最新版，官网不用跟着改。别写成带版本号的那种地址。

## 换域名

改 `vite.config.js` 顶部两个常量：

```js
const SITE_ORIGIN = 'https://你的域名';
const BASE = '/';                    // GitHub Pages 项目站点才需要 /voice-doggo/
```

然后同步 `public/sitemap.xml` 和 `public/robots.txt` 里的地址。

## 体检都检什么

`npm run check` 的每一条都对应真实踩过的坑，共同点是「页面看着好好的，但对
搜索引擎或某类设备是坏的」：

- 构建占位符没替换 → 页面上直接显示 `%SITE_URL%`
- canonical / og:url / og:image 不是绝对地址 → 社交平台抓不到图，分享出去是白卡片
- 下载链接写死版本号 → 发新版后官网还在发旧包
- 页面声称支持 Intel 或 macOS 12 → 识别引擎只有 arm64，最低 13，写错会让人下到装不了的东西
- JSON-LD 解析失败 → 等于没写结构化数据
- sitemap 的 xmlns 写成 w3.org → 搜索引擎拒绝解析（正确的是 sitemaps.org）
- 平台检测用 `/Mac/` 而不是 `/mac/i` → `navigator.userAgentData.platform` 返回的是小写
  `macOS`，用大写正则会把一台真 Mac 判成 Windows，然后对着 Mac 用户说「你用不了」
