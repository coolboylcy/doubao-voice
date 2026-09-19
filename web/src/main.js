import './style.css';

const optionKey = document.querySelector('.option-key');
const voiceState = document.querySelector('.voice-state b');
const typedOutput = document.querySelector('.typed-output');
const demoLines = [
  '帮我检查这个项目，修复移动端布局，然后运行测试。',
  '分析刚才的报错，找到根因并给出最小修改方案。',
  '把这个需求拆成任务，然后从最关键的一项开始实现。',
];
let lineIndex = 0;

function startListening() {
  optionKey?.classList.add('is-listening');
  if (voiceState) voiceState.textContent = '正在听…';
  if (typedOutput) typedOutput.textContent = '说吧，我在听';
}

function stopListening() {
  if (!optionKey?.classList.contains('is-listening')) return;
  optionKey.classList.remove('is-listening');
  if (voiceState) voiceState.textContent = '已输入';
  if (typedOutput) typedOutput.textContent = demoLines[lineIndex++ % demoLines.length];
  window.setTimeout(() => {
    if (voiceState) voiceState.textContent = '按住说话';
  }, 1300);
}

optionKey?.addEventListener('pointerdown', startListening);
optionKey?.addEventListener('pointerup', stopListening);
optionKey?.addEventListener('pointercancel', stopListening);
optionKey?.addEventListener('pointerleave', stopListening);
optionKey?.addEventListener('keydown', (event) => {
  if (event.key === ' ' || event.key === 'Enter') startListening();
});
optionKey?.addEventListener('keyup', stopListening);

document.querySelectorAll('.download-link').forEach((link) => {
  link.addEventListener('click', () => {
    window.dispatchEvent(new CustomEvent('voice-doggo:download', {
      detail: { placement: link.dataset.cta || 'unknown', version: __APP_VERSION__ },
    }));
  });
});

// 手机上唯一有意义的「下载」动作是把链接带到电脑上。
// clipboard API 在非 HTTPS 或旧 WebView 里可能不存在，退回 execCommand，
// 再不行就把链接选中让用户自己长按复制——总之不能点了没反应。
async function copyPageLink(button) {
  const url = window.location.href;
  let ok = false;
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(url);
      ok = true;
    }
  } catch {
    ok = false;
  }
  if (!ok) {
    const field = document.createElement('textarea');
    field.value = url;
    field.setAttribute('readonly', '');
    field.style.cssText = 'position:fixed;top:-1000px;opacity:0';
    document.body.appendChild(field);
    field.select();
    try {
      ok = document.execCommand('copy');
    } catch {
      ok = false;
    }
    field.remove();
  }

  const label = button.querySelector('strong') || button;
  const original = label.textContent;
  label.textContent = ok ? '链接已复制' : '请长按地址栏复制';
  button.classList.toggle('is-copied', ok);
  window.setTimeout(() => {
    label.textContent = original;
    button.classList.remove('is-copied');
  }, 2200);
}

document.querySelectorAll('[data-copy-target="page"]').forEach((button) => {
  button.addEventListener('click', () => copyPageLink(button));
});

const finalDownload = document.querySelector('.final-download');
const mobileDownload = document.querySelector('.mobile-download');
const heroDownload = document.querySelector('.download-button');

if (finalDownload && heroDownload && mobileDownload && 'IntersectionObserver' in window) {
  const visibleTargets = new Set();
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) visibleTargets.add(entry.target);
      else visibleTargets.delete(entry.target);
    });
    mobileDownload.classList.toggle('is-hidden', visibleTargets.size > 0);
  }, { threshold: 0.2 });
  observer.observe(heroDownload);
  observer.observe(finalDownload);
}


/**
 * 判断这台设备到底能不能装 macOS 应用。
 *
 * 光靠 CSS 断点不够准：Mac 用户把浏览器窗口缩窄，同样会落进手机断点，
 * 然后被告知「暂不支持手机」——他明明就坐在能装的机器前面。反过来 iPad
 * 横屏够宽，却一样装不了。所以宽度只做无 JS 时的保底，有 JS 就按平台纠正。
 *
 * iPadOS 的 navigator.platform 会伪装成 'MacIntel'，靠 maxTouchPoints 才能
 * 跟真 Mac 分开——触控点大于 1 的「Mac」只能是 iPad。
 */
function detectPlatform() {
  const ua = navigator.userAgent;
  const platform = navigator.userAgentData?.platform || navigator.platform || '';
  const touch = navigator.maxTouchPoints || 0;

  // 大小写必须放宽：navigator.platform 给的是 'MacIntel'，而
  // navigator.userAgentData.platform 给的是 'macOS'——小写 m。用 /Mac/ 去测
  // 后者会漏掉，把一台真 Mac 判成 Windows，然后对着 Mac 用户说「只有 macOS
  // 版本，你用不了」。
  const isIOS = /iphone|ipod/i.test(ua);
  const isIPad = /ipad/i.test(ua) || (/mac/i.test(platform) && touch > 1);
  const isAndroid = /android/i.test(ua);
  const isMacDesktop = /mac/i.test(platform) && touch <= 1;

  if (isIOS || isAndroid) return 'phone';
  if (isIPad) return 'tablet';
  if (isMacDesktop) return 'mac';
  return 'other-desktop';
}

const notice = document.querySelector('.mobile-notice');
const noticeText = notice?.querySelector('p');
const handoff = document.querySelector('.mobile-handoff');

const MESSAGES = {
  phone: ['暂不支持手机使用', '这是一个 macOS 桌面应用，请用电脑打开本页下载。'],
  tablet: ['暂不支持 iPad 使用', '这是一个 macOS 桌面应用，请用 Mac 打开本页下载。'],
  'other-desktop': ['目前只有 macOS 版本', 'Windows 和 Linux 暂时用不了，需要一台 Apple Silicon 的 Mac。'],
};

const platform = detectPlatform();
document.documentElement.dataset.platform = platform;

if (platform === 'mac') {
  // 是 Mac，只是窗口窄。把提示收掉，下载按钮照常。
  notice?.remove();
  handoff?.remove();
} else if (noticeText && MESSAGES[platform]) {
  const [title, body] = MESSAGES[platform];
  noticeText.innerHTML = '';
  const strong = document.createElement('strong');
  strong.textContent = title;
  noticeText.append(strong, document.createTextNode(body));
  notice.hidden = false;

  // 装不了的设备上，下载按钮点了只会拿到一个打不开的 DMG。
  // 改成复制链接，这是此刻唯一帮得上忙的动作。
  document.querySelectorAll('.download-link').forEach((link) => {
    link.addEventListener('click', (event) => {
      event.preventDefault();
      copyPageLink(link);
    });
  });
}
