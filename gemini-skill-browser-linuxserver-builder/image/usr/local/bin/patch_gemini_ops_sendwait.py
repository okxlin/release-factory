#!/usr/bin/env python3
from pathlib import Path
import sys

TARGET = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('/opt/gemini-skill/src/gemini-ops.js')

if not TARGET.exists():
    raise SystemExit(f'target not found: {TARGET}')

s = TARGET.read_text()

# --- 1) sendAndWait: 避免长期 stop 态导致误超时 ---
anchor1 = "      const start = Date.now();\n      let lastStatus = null;\n"
insert1 = "      const start = Date.now();\n      let lastStatus = null;\n      let lastText = '';\n      let stableTextRounds = 0;\n"

if "let stableTextRounds = 0;" not in s:
    if anchor1 not in s:
        raise SystemExit('anchor1 not found in gemini-ops.js')
    s = s.replace(anchor1, insert1, 1)

old_block = """        if (poll.status === 'mic') {
          // 回复完成，自动提取最新文字回复
          const textResp = await this.getLatestTextResponse();
          return {
            ok: true,
            elapsed: Date.now() - start,
            finalStatus: poll,
            text: textResp.ok ? textResp.text : null,
            textIndex: textResp.ok ? textResp.index : null,
          };
        }
        if (poll.status === 'unknown') {
          console.warn('[ops] unknown status, may need screenshot to debug');
        }
"""

new_block = """        const textResp = await this.getLatestTextResponse();
        const currentText = textResp.ok ? String(textResp.text || '').trim() : '';

        if (currentText && currentText === lastText) {
          stableTextRounds += 1;
        } else {
          stableTextRounds = 0;
          lastText = currentText;
        }

        const streamSeemsDone = poll.status === 'stop' && !!currentText && stableTextRounds >= 2;

        if (poll.status === 'mic' || streamSeemsDone) {
          return {
            ok: true,
            elapsed: Date.now() - start,
            finalStatus: poll,
            text: textResp.ok ? textResp.text : null,
            textIndex: textResp.ok ? textResp.index : null,
          };
        }

        if (poll.status === 'unknown') {
          console.warn('[ops] unknown status, may need screenshot to debug');
        }
"""

if "streamSeemsDone" not in s:
    if old_block not in s:
        raise SystemExit('sendAndWait block not found in gemini-ops.js')
    s = s.replace(old_block, new_block, 1)

# --- 2) 图片选择器兼容新版 Gemini ---
old_all_images = """    async getAllImages() {
      return op.query(() => {
        const imgs = [...document.querySelectorAll('img.image.loaded')];
        if (!imgs.length) {
          return { ok: false, images: [], total: 0, newCount: 0, error: 'no_loaded_images' };
        }

        const images = imgs.map((img, i) => ({
          src: img.src || '',
          alt: img.alt || '',
          width: img.naturalWidth || 0,
          height: img.naturalHeight || 0,
          isNew: img.classList.contains('animate'),
          index: i,
        }));

        const newCount = images.filter(i => i.isNew).length;
        return { ok: true, images, total: images.length, newCount };
      });
    },
"""
new_all_images = """    async getAllImages() {
      return op.query(() => {
        const byClass = [...document.querySelectorAll('img.image.loaded, img.image.animate, img.image')];
        const byAltOrBlob = [...document.querySelectorAll('img[alt*=\"AI 生成\"], img[src^=\"blob:https://gemini.google.com/\"]')];
        const seen = new Set();
        const imgs = [...byClass, ...byAltOrBlob].filter((img) => {
          const src = img.src || img.getAttribute('src') || '';
          if (!src) return false;
          if (seen.has(src)) return false;
          seen.add(src);
          const isGeminiBlob = src.startsWith('blob:https://gemini.google.com/');
          const hasImageClass = img.classList.contains('image');
          const aiAlt = (img.alt || '').includes('AI 生成');
          return isGeminiBlob || hasImageClass || aiAlt;
        });

        if (!imgs.length) {
          return { ok: false, images: [], total: 0, newCount: 0, error: 'no_loaded_images' };
        }

        const images = imgs.map((img, i) => ({
          src: img.src || img.getAttribute('src') || '',
          alt: img.alt || '',
          width: img.naturalWidth || img.width || 0,
          height: img.naturalHeight || img.height || 0,
          isNew: img.classList.contains('animate'),
          index: i,
        }));

        const newCount = images.filter(i => i.isNew).length;
        return { ok: true, images, total: images.length, newCount };
      });
    },
"""
if "img[alt*=\"AI 生成\"], img[src^=\"blob:https://gemini.google.com/\"]" not in s and old_all_images in s:
    s = s.replace(old_all_images, new_all_images, 1)

old_latest = """    async getLatestImage() {
      return op.query(() => {
        // 优先：最新生成的图片（带 animate）
        const newImgs = [...document.querySelectorAll('img.image.animate.loaded')];
        // 回退：所有已加载图片
        const allImgs = [...document.querySelectorAll('img.image.loaded')];

        if (!allImgs.length) {
          return { ok: false, error: 'no_loaded_images' };
        }

        // 取最新生成的最后一张，没有则取全部的最后一张
        const img = newImgs.length > 0
          ? newImgs[newImgs.length - 1]
          : allImgs[allImgs.length - 1];
        const isNew = newImgs.length > 0 && newImgs[newImgs.length - 1] === img;

        // 查找下载按钮
        let container = img;
        while (container && container !== document.body) {
          if (container.classList?.contains('image-container')) break;
          container = container.parentElement;
        }
        const dlBtn = container
          ? (container.querySelector('mat-icon[fonticon=\"download\"]')
            || container.querySelector('mat-icon[data-mat-icon-name=\"download\"]'))
          : null;

        return {
          ok: true,
          src: img.src || '',
          alt: img.alt || '',
          width: img.naturalWidth || 0,
          height: img.naturalHeight || 0,
          isNew,
          hasDownloadBtn: !!dlBtn,
        };
      });
    },
"""
new_latest = """    async getLatestImage() {
      return op.query(() => {
        const newImgs = [...document.querySelectorAll('img.image.animate, img.image.animate.loaded')];
        const allClassImgs = [...document.querySelectorAll('img.image.loaded, img.image.animate, img.image')];
        const fallbackImgs = [...document.querySelectorAll('img[alt*=\"AI 生成\"], img[src^=\"blob:https://gemini.google.com/\"]')];
        const merged = [...allClassImgs, ...fallbackImgs];

        if (!merged.length) {
          return { ok: false, error: 'no_loaded_images' };
        }

        const img = newImgs.length > 0
          ? newImgs[newImgs.length - 1]
          : merged[merged.length - 1];
        const isNew = newImgs.length > 0 && newImgs[newImgs.length - 1] === img;

        let container = img;
        while (container && container !== document.body) {
          if (container.classList?.contains('image-container') || container.classList?.contains('image-button')) break;
          container = container.parentElement;
        }
        const dlBtn = container
          ? (container.querySelector('mat-icon[fonticon=\"download\"]')
            || container.querySelector('mat-icon[data-mat-icon-name=\"download\"]'))
          : null;

        return {
          ok: true,
          src: img.src || img.getAttribute('src') || '',
          alt: img.alt || '',
          width: img.naturalWidth || img.width || 0,
          height: img.naturalHeight || img.height || 0,
          isNew,
          hasDownloadBtn: !!dlBtn,
        };
      });
    },
"""
if "const fallbackImgs = [...document.querySelectorAll('img[alt*=\"AI 生成\"], img[src^=\"blob:https://gemini.google.com/\"]')];" not in s and old_latest in s:
    s = s.replace(old_latest, new_latest, 1)

# --- 3) blob 提取兜底：避免 0x0 canvas 返回伪成功 ---
s = s.replace("const imgs = [...document.querySelectorAll('img.image.loaded')];", "const imgs = [...document.querySelectorAll('img.image.loaded, img.image.animate, img.image')];")

s = s.replace(
    "const h = fallback.naturalHeight || fallback.height;\n           try {",
    "const h = fallback.naturalHeight || fallback.height;\n           if (!w || !h) {\n             return { ok: false, error: 'no_loaded_images', width: w, height: h, needFetch: true };\n           }\n           try {",
    1,
)

s = s.replace(
    "const h = img.naturalHeight || img.height;\n         try {",
    "const h = img.naturalHeight || img.height;\n         if (!w || !h) {\n           return { ok: false, error: 'no_loaded_images', width: w, height: h, needFetch: true };\n         }\n         try {",
    1,
)

s = s.replace(
    "if (canvasResult.needFetch || canvasResult.error === 'canvas_tainted') {",
    "if (canvasResult.needFetch || canvasResult.error === 'canvas_tainted' || canvasResult.error === 'no_loaded_images') {",
    1,
)

# --- 4) 新增：预览层原图提取 ---
preview_methods = """
    /** 打开最新图片预览层 */
    async openLatestImagePreview() {
      return op.query(() => {
        const buttons = [...document.querySelectorAll('button.image-button')];
        const btn = buttons[buttons.length - 1];
        if (!btn) return { ok: false, error: 'no_image_button' };
        btn.scrollIntoView({ block: 'center' });
        btn.click();
        return { ok: true, total: buttons.length };
      });
    },

    /** 从预览层提取原尺寸 base64（优先） */
    async extractPreviewImageBase64() {
      const result = await op.query(async () => {
        const pick = () => {
          const imgs = [...document.querySelectorAll('mat-dialog-container img, .cdk-overlay-container img, img.image-container')]
            .filter((img) => {
              const r = img.getBoundingClientRect();
              return r.width > 200 && r.height > 200;
            })
            .map((img) => {
              const r = img.getBoundingClientRect();
              return { img, area: r.width * r.height, rect: r };
            })
            .sort((a, b) => b.area - a.area);
          return imgs[0]?.img || null;
        };

        const waitForImage = async (ms = 10000) => {
          const start = Date.now();
          while (Date.now() - start < ms) {
            const img = pick();
            if (img && (img.naturalWidth || 0) > 0 && (img.naturalHeight || 0) > 0) return img;
            await new Promise((r) => setTimeout(r, 200));
          }
          return null;
        };

        const img = await waitForImage(12000);
        if (!img) return { ok: false, error: 'preview_img_not_loaded' };

        try {
          const w = img.naturalWidth || img.width;
          const h = img.naturalHeight || img.height;
          if (!w || !h) return { ok: false, error: 'preview_zero_size' };

          const canvas = document.createElement('canvas');
          canvas.width = w;
          canvas.height = h;
          const ctx = canvas.getContext('2d');
          ctx.drawImage(img, 0, 0, w, h);
          const dataUrl = canvas.toDataURL('image/png');
          return {
            ok: true,
            dataUrl,
            width: w,
            height: h,
            src: img.getAttribute('src') || '',
            method: 'preview-canvas',
          };
        } catch (e) {
          return { ok: false, error: 'preview_canvas_failed', detail: e.message || String(e) };
        }
      });

      if (!result.ok) return result;

      const wmResult = await removeWatermarkFromDataUrl(result.dataUrl);
      if (wmResult.ok && !wmResult.skipped) {
        return { ok: true, dataUrl: wmResult.dataUrl, method: 'preview-canvas', width: result.width, height: result.height };
      }

      return { ok: true, dataUrl: result.dataUrl, method: 'preview-canvas', width: result.width, height: result.height };
    },
"""

if "async openLatestImagePreview()" not in s:
    marker = "    /**\n     * 完整生图流程：发送提示词 → 等待 → 提取图片"
    if marker not in s:
        raise SystemExit('generateImage marker not found for preview method insertion')
    s = s.replace(marker, preview_methods + "\n" + marker, 1)

# --- 5) generateImage 优先预览层提取原图 ---
old_generate = """    async generateImage(prompt, opts = {}) {
      const { timeout = 120_000, fullSize = false, onPoll } = opts;

      // 1. 发送并等待
      const waitResult = await this.sendAndWait(prompt, { timeout, onPoll });
      if (!waitResult.ok) {
        return { ...waitResult, step: 'sendAndWait' };
      }

      // 3. 等图片渲染完成
      await sleep(2000);

      // 4. 获取图片
      let imgInfo = await this.getLatestImage();
      if (!imgInfo.ok) {
        await sleep(3000);
        imgInfo = await this.getLatestImage();
        if (!imgInfo.ok) {
          return { ok: false, error: 'no_image_found', elapsed: waitResult.elapsed, imgInfo };
        }
      }

      // 5. 提取 / 下载
      if (fullSize) {
        // 完整尺寸下载：通过 CDP 拦截，文件保存到 config.outputDir
        const dlResult = await this.downloadFullSizeImage();
        return { ok: dlResult.ok, method: 'fullSize', elapsed: waitResult.elapsed, ...dlResult };
      } else {
        // 低分辨率：提取页面预览图的 base64
        const b64Result = await this.extractImageBase64(imgInfo.src);
        return { ok: b64Result.ok, method: b64Result.method, elapsed: waitResult.elapsed, ...b64Result };
      }
    },
"""

new_generate = """    async generateImage(prompt, opts = {}) {
      const { timeout = 120_000, fullSize = false, onPoll } = opts;

      // 1. 发送并等待
      const waitResult = await this.sendAndWait(prompt, { timeout, onPoll });
      if (!waitResult.ok) {
        return { ...waitResult, step: 'sendAndWait' };
      }

      // 2. 优先走预览层原图提取（新版 Gemini 最稳定）
      await sleep(1200);
      const openPreview = await this.openLatestImagePreview();
      if (openPreview.ok) {
        const previewResult = await this.extractPreviewImageBase64();
        if (previewResult.ok) {
          return {
            ok: true,
            method: fullSize ? 'preview-canvas-fullsize' : 'preview-canvas',
            elapsed: waitResult.elapsed,
            ...previewResult,
          };
        }
      }

      // 3. 回退到旧流程（兼容历史页面）
      await sleep(2000);
      let imgInfo = await this.getLatestImage();
      if (!imgInfo.ok) {
        await sleep(3000);
        imgInfo = await this.getLatestImage();
        if (!imgInfo.ok) {
          return {
            ok: false,
            error: 'no_image_found',
            elapsed: waitResult.elapsed,
            imgInfo,
            previewError: openPreview.ok ? 'preview_extract_failed' : 'preview_not_opened',
          };
        }
      }

      if (fullSize) {
        const dlResult = await this.downloadFullSizeImage();
        return { ok: dlResult.ok, method: 'fullSize', elapsed: waitResult.elapsed, ...dlResult };
      }

      const b64Result = await this.extractImageBase64(imgInfo.src);
      return { ok: b64Result.ok, method: b64Result.method, elapsed: waitResult.elapsed, ...b64Result };
    },
"""

if "method: fullSize ? 'preview-canvas-fullsize' : 'preview-canvas'" not in s:
    if old_generate not in s:
        raise SystemExit('generateImage block not found in gemini-ops.js')
    s = s.replace(old_generate, new_generate, 1)

TARGET.write_text(s)
print(f'patched {TARGET}')
