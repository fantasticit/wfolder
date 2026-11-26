import DOMPurify from "dompurify";
import MarkdownIt from "markdown-it";
import hljs from "highlight.js/lib/common";

const markdown = new MarkdownIt({
  html: true,
  highlight(source, language) {
    if (source.length > 64 * 1024 || !language || !hljs.getLanguage(language)) return "";
    try {
      return hljs.highlight(source, { language, ignoreIllegals: true }).value;
    } catch {
      return "";
    }
  },
});

const renderFence = markdown.renderer.rules.fence;
markdown.renderer.rules.fence = (tokens, index, options, env, renderer) => {
  const fence = tokens[index];
  if (fence.info.trim().toLowerCase() === "mermaid") {
    const source = markdown.utils.escapeHtml(fence.content);
    return `<figure class="diagram"><pre><code>${source}</code></pre></figure>`;
  }
  return renderFence(tokens, index, options, env, renderer);
};

const allowedMarkup = {
  ALLOWED_TAGS: [
    "a", "b", "blockquote", "br", "code", "del", "details", "div", "em",
    "figure", "figcaption", "h1", "h2", "h3", "h4", "h5", "h6", "hr",
    "i", "img", "kbd", "li", "ol", "p", "pre", "s", "span", "strong",
    "sub", "summary", "sup", "table", "tbody", "td", "th", "thead", "tr", "ul",
  ],
  ALLOWED_ATTR: ["align", "alt", "class", "height", "href", "open", "src", "start", "style", "title", "width"],
  ALLOW_DATA_ATTR: false,
  RETURN_DOM_FRAGMENT: true,
};

DOMPurify.addHook("uponSanitizeAttribute", (node, attribute) => {
  if (attribute.attrName === "style") {
    attribute.keepAttr = ["TD", "TH"].includes(node.tagName) &&
      /^text-align:(left|center|right);?$/.test(attribute.attrValue);
  }
});

function imageURL(reference) {
  if (!reference) return null;
  if (reference.startsWith("//")) return `https:${reference}`;
  if (/^(https?:|data:image\/)/i.test(reference)) return reference;
  if (/^[a-z][a-z\d+.-]*:/i.test(reference)) return null;
  return `wfolder-image://local/?path=${encodeURIComponent(reference)}`;
}

function prepareImage(image) {
  const reference = image.getAttribute("src")?.trim();
  const url = imageURL(reference);
  const showFailure = () => {
    const fallback = document.createElement("span");
    fallback.className = "image-unavailable";
    fallback.textContent = image.alt ? `图片加载失败 · ${image.alt}` : "图片加载失败";
    image.replaceWith(fallback);
  };
  if (!url) {
    showFailure();
    return;
  }
  image.addEventListener("error", showFailure, { once: true });
  image.loading = "lazy";
  image.decoding = "async";
  image.referrerPolicy = "no-referrer";
  image.src = url;
}

globalThis.showMarkdown = (source) => {
  const documentBody = document.querySelector("main");
  const content = DOMPurify.sanitize(markdown.render(source), allowedMarkup);
  for (const image of content.querySelectorAll("img")) prepareImage(image);
  documentBody.replaceChildren(content);

  const ids = new Set();
  for (const heading of documentBody.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
    const slug = heading.textContent.trim().toLowerCase()
      .replace(/[^\p{L}\p{N}\p{M}_\s-]/gu, "")
      .replace(/\s+/g, "-");
    if (!slug) continue;
    let id = slug;
    for (let count = 1; ids.has(id); count++) id = `${slug}-${count}`;
    ids.add(id);
    heading.id = id;
  }

  for (const table of documentBody.querySelectorAll("table")) {
    const scroll = document.createElement("div");
    scroll.className = "table-scroll";
    table.replaceWith(scroll);
    scroll.append(table);
  }

  globalThis.showDiagrams?.(documentBody);
};
