import { defineConfig } from 'vite';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * 站点根地址。GitHub Pages 把项目站点挂在 /<仓库名>/ 下面，不是域名根，
 * 所以 base 必须带上这一段——否则 /assets/... 这类绝对路径全部 404，
 * 本地 dev 正常、部署后一片裂图。
 *
 * 换成自有域名时，把 SITE_ORIGIN 改成 'https://你的域名'，BASE 改回 '/'。
 */
const SITE_ORIGIN = 'https://coolboylcy.github.io';
const BASE = '/voice-doggo/';

/**
 * 版本号从 App 那边的 project.yml 读，不在网页里手写。
 *
 * 官网写着 1.0.0、实际已经发到 1.1.0，这种事发生过一次了。下载按钮的副标题、
 * JSON-LD 的 softwareVersion、埋点里的 version 全都得跟着发版走，抄三遍必然
 * 漏一处。
 */
function appVersion() {
  const yml = readFileSync(
    fileURLToPath(new URL('../project.yml', import.meta.url)),
    'utf8',
  );
  const match = yml.match(/^\s*MARKETING_VERSION:\s*"([^"]+)"/m);
  if (!match) throw new Error('project.yml 里读不到 MARKETING_VERSION');
  return match[1];
}

const VERSION = appVersion();

export default defineConfig({
  base: BASE,
  define: {
    __APP_VERSION__: JSON.stringify(VERSION),
  },
  plugins: [
    {
      name: 'voice-doggo-html-vars',
      transformIndexHtml(html) {
        return html
          .replaceAll('%SITE_URL%', SITE_ORIGIN + BASE)
          .replaceAll('%APP_VERSION%', VERSION);
      },
    },
  ],
});
