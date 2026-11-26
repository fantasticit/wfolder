import mermaid from "mermaid";

globalThis.showDiagrams = (documentBody) => {
  const dark = matchMedia("(prefers-color-scheme: dark)").matches;
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    suppressErrorRendering: true,
    theme: dark ? "dark" : "default",
    htmlLabels: false,
  });

  let index = 0;
  const observer = new IntersectionObserver((entries) => {
    for (const { target, isIntersecting } of entries) {
      if (!isIntersecting) continue;
      observer.unobserve(target);
      renderDiagram(target, `markdown-diagram-${index++}`);
    }
  }, { rootMargin: "200px 0px" });
  for (const diagram of documentBody.querySelectorAll(".diagram")) observer.observe(diagram);
};

async function renderDiagram(figure, id) {
  try {
    const source = figure.querySelector("code").textContent;
    const { svg } = await mermaid.render(id, source);
    figure.innerHTML = svg;
    const image = figure.querySelector("svg");
    const width = image?.viewBox.baseVal.width;
    if (width > 0) {
      image.style.width = "100%";
      image.style.maxWidth = `${width}px`;
      image.style.minWidth = `${Math.ceil(width * 0.45)}px`;
    }
  } catch {
    const caption = document.createElement("figcaption");
    caption.textContent = "无法渲染 Mermaid 图表";
    figure.prepend(caption);
  }
}
