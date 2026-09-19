/**
 * 构建产物体检。每条都对应一个真实踩过的坑——全是「页面看着好好的，
 * 但搜索引擎或某类设备上是坏的」那种，肉眼不盯着找根本发现不了。
 *
 * 用法：node scripts/check-site.mjs   （需要先 npm run build）
 */
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const read = (p) => readFileSync(root + p, 'utf8');

const failures = [];
const check = (ok, message) => { if (!ok) failures.push(message); };

if (!existsSync(root + 'dist/index.html')) {
  console.error('dist/index.html 不存在，先跑 npm run build');
  process.exit(1);
}

const html = read('dist/index.html');
const js = read('src/main.js');
const version = read('../project.yml').match(/MARKETING_VERSION:\s*"([^"]+)"/)[1];

// 构建期占位符没替换掉，页面上会直接显示 %SITE_URL% 这种字样
check(!/%SITE_URL%|%APP_VERSION%/.test(html), '构建产物里还有未替换的占位符');

// canonical 和 og:url 必须是绝对地址：相对地址会被搜索引擎和社交平台当成
// 自己域名下的路径，og:image 尤其——相对路径抓不到图，分享出去是白卡片
check(/<link rel="canonical" href="https:\/\//.test(html), 'canonical 缺失或不是绝对地址');
check(/<meta property="og:url" content="https:\/\//.test(html), 'og:url 缺失或不是绝对地址');
check(/<meta property="og:image" content="https:\/\//.test(html), 'og:image 不是绝对地址');

// 版本号必须跟 App 一致。官网写 1.0.0 而实际发到 1.1.0 这事发生过
check(html.includes(version), `页面里找不到当前版本号 ${version}`);
check(!/releases\/download\/v\d/.test(html), '存在写死版本号的下载链接，应该用 latest/download');
check(
  html.includes('releases/latest/download/VoiceDoggo.dmg'),
  '下载链接没有指向固定名的最新版资产',
);

// 系统要求：识别引擎只有 arm64，最低 macOS 13。写错会让 Intel 用户
// 下载到一个装上也用不了的东西
check(!/macOS 12/.test(html), '页面仍写着 macOS 12，实际要求是 13');
check(
  !/Apple Silicon 与 Intel|兼容 Apple Silicon 和 Intel/.test(html),
  '页面仍声称支持 Intel Mac，实际识别引擎只有 arm64',
);

// 结构化数据得能解析，解析不了等于没写
for (const [, block] of html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)) {
  try {
    JSON.parse(block);
  } catch (error) {
    failures.push(`JSON-LD 解析失败：${error.message}`);
  }
}

// sitemap 的命名空间只有 sitemaps.org 那个是对的，
// 写成 w3.org 搜索引擎会直接拒绝解析
const sitemap = read('public/sitemap.xml');
check(
  sitemap.includes('http://www.sitemaps.org/schemas/sitemap/0.9'),
  'sitemap.xml 的 xmlns 不对，必须是 http://www.sitemaps.org/schemas/sitemap/0.9',
);
check(read('public/robots.txt').includes('Sitemap:'), 'robots.txt 没有声明 sitemap');

// 平台检测的大小写：navigator.platform 给 'MacIntel'，
// navigator.userAgentData.platform 给 'macOS'——小写 m。
// 用 /Mac/ 测后者会漏，把真 Mac 判成 Windows，然后对着 Mac 用户说「你用不了」
check(!/\/Mac\/\.test/.test(js), '平台检测用了区分大小写的 /Mac/，会漏掉 userAgentData 的小写 macOS');
check(/\/mac\/i\.test/.test(js), '平台检测应该用 /mac/i');

if (failures.length) {
  console.error('体检未通过：');
  failures.forEach((f) => console.error('  ✗ ' + f));
  process.exit(1);
}
console.log(`体检通过（版本 ${version}）`);
