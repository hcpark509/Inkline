"use strict";

const article = document.getElementById("document");
const empty = document.getElementById("empty");

window.setPreviewFont = (family, size, fontURL = "") => {
  const style = document.documentElement.style;
  document.getElementById("inkline-local-font")?.remove();
  if (fontURL) {
    const face = document.createElement("style");
    face.id = "inkline-local-font";
    face.textContent = `@font-face { font-family: InklineLocal; src: url("${fontURL}"); }`;
    document.head.append(face);
    style.setProperty("--reading-font", "InklineLocal");
  } else if (family) {
    style.setProperty("--reading-font", CSS.escape(family));
  } else {
    style.removeProperty("--reading-font");
  }
  style.setProperty("--reading-size", `${size}px`);
};

let previewTheme;
const applyTheme = values => {
  for (const [name, value] of Object.entries(values)) document.documentElement.style.setProperty(name, value);
};
window.setPreviewTheme = theme => {
  previewTheme = theme;
  applyTheme(theme[theme.appearance]);
};

window.preparePDFExport = async (width, height) => {
  const root = document.documentElement;
  root.style.setProperty("--page-width", `${width}px`);
  root.style.setProperty("--page-height", `${height}px`);
  root.dataset.pdf = "";
  if (previewTheme) applyTheme(previewTheme.light);
  for (const heading of article.querySelectorAll(":scope > :is(h1, h2, h3, h4, h5, h6)")) {
    const next = heading.nextElementSibling;
    if (!next || /^H[1-6]$/.test(next.tagName)) continue;
    const lead = document.createElement("div");
    lead.className = "pdf-section-lead";
    heading.before(lead);
    lead.append(heading, next);
  }
  await Promise.race([
    Promise.allSettled([document.fonts.ready, ...Array.from(document.images, image => image.decode())]),
    new Promise(resolve => setTimeout(resolve, 6000))
  ]);
  return Math.max(1, Math.ceil(article.scrollWidth / width));
};

const escapeHTML = value => value.replace(/[&<>"']/g, char => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
})[char]);

function destination(raw, kind, hasDirectory, revision) {
  const target = raw.trim();
  if (!target || /[\u0000-\u001f\u007f]/.test(target)) return null;
  if (/^https?:\/\//i.test(target)) return target;
  if (kind === "link" && /^(#|mailto:)/i.test(target)) return target;
  if (!hasDirectory || /^(?:[a-z][a-z0-9+.-]*:|[\/\\])/i.test(target)) return null;
  try {
    const path = decodeURIComponent(target.split(/[?#]/, 1)[0]);
    return `inkline-${kind}://document/?path=${encodeURIComponent(path)}&revision=${revision}`;
  } catch {
    return null;
  }
}

window.renderMarkdown = (source, hasDirectory, revision) => {
  const ids = new Set();
  const parser = new marked.Marked({
    gfm: true,
    renderer: {
      html({ text }) {
        return escapeHTML(text);
      },
      heading({ tokens, depth }) {
        const plain = this.parser.parseInline(tokens, this.parser.textRenderer);
        const slug = plain.trim().toLowerCase().replace(/[^\p{L}\p{N}_\s-]/gu, "")
          .replace(/\s+/g, "-") || "heading";
        let id = slug;
        let counter = 1;
        while (ids.has(id)) id = `${slug}-${counter++}`;
        ids.add(id);
        return `<h${depth} id="${escapeHTML(id)}">${this.parser.parseInline(tokens)}</h${depth}>\n`;
      },
      link({ href, title, tokens }) {
        const text = this.parser.parseInline(tokens);
        const url = destination(href, "link", hasDirectory, revision);
        if (!url) return text;
        const tooltip = title ? ` title="${escapeHTML(title)}"` : "";
        return `<a href="${escapeHTML(url)}"${tooltip}>${text}</a>`;
      },
      image({ href, title, text }) {
        const alt = escapeHTML(text);
        const url = destination(href, "image", hasDirectory, revision);
        if (!url) return alt;
        const tooltip = title ? ` title="${escapeHTML(title)}"` : "";
        return `<img src="${escapeHTML(url)}" alt="${alt}"${tooltip}>`;
      }
    }
  });

  const scroll = window.scrollY;
  const hasSource = source.trim().length > 0;
  article.hidden = !hasSource;
  empty.hidden = hasSource;
  article.innerHTML = hasSource ? parser.parse(source) : "";
  window.scrollTo(0, scroll);
};
