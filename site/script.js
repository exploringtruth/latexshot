const copyButton = document.querySelector(".copy-button");
const example = document.querySelector("#example-latex");
const status = document.querySelector(".copy-status");

copyButton.hidden = false;
copyButton.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(example.textContent);
    status.textContent = "LaTeX copied.";
  } catch {
    const selection = window.getSelection();
    if (selection) {
      const range = document.createRange();
      range.selectNodeContents(example);
      selection.removeAllRanges();
      selection.addRange(range);
    }
    status.textContent = selection
      ? "Copy was blocked. The LaTeX is selected for manual copying."
      : "Copy was blocked. Select the LaTeX and copy it manually.";
  }
});

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

for (const demo of document.querySelectorAll(".motion-demo")) {
  const stage = demo.querySelector(".motion-stage");
  const video = demo.querySelector("video");
  const poster = demo.querySelector(".motion-poster");
  const fallback = demo.querySelector(".motion-fallback");
  const button = demo.querySelector(".motion-toggle");
  let visible = false;
  let explicitPlayback = null;
  let failed = false;

  const wantsPlayback = () => explicitPlayback ?? !reducedMotion.matches;
  const updateStill = () => {
    const started = video.classList.contains("started");
    const showPoster = !started && poster.naturalWidth > 0;
    poster.classList.toggle("available", showPoster);
    fallback.hidden = started || showPoster;
  };
  const updatePlayback = () => {
    if (failed) return;

    const action = wantsPlayback() ? "Pause" : "Play";
    button.textContent = action;
    button.setAttribute("aria-label", `${action} ${demo.dataset.motion}`);

    if (!visible || document.hidden || !wantsPlayback()) {
      video.pause();
      return;
    }
    if (!video.paused) return;

    video.hidden = false;
    video.play().catch(error => {
      if (error.name === "AbortError" || failed) return;
      explicitPlayback = false;
      updatePlayback();
    });
  };

  video.addEventListener("playing", () => {
    if (!visible || document.hidden || !wantsPlayback()) {
      video.pause();
      return;
    }
    video.classList.add("started");
    updateStill();
  });
  video.addEventListener("error", () => {
    failed = true;
    video.hidden = true;
    video.classList.remove("started");
    button.hidden = true;
    updateStill();
  });
  poster.addEventListener("load", updateStill);
  poster.addEventListener("error", updateStill);

  button.hidden = false;
  button.addEventListener("click", () => {
    explicitPlayback = !wantsPlayback();
    updatePlayback();
  });
  reducedMotion.addEventListener("change", () => {
    if (reducedMotion.matches) explicitPlayback = null;
    updatePlayback();
  });
  document.addEventListener("visibilitychange", updatePlayback);
  new IntersectionObserver(([entry]) => {
    visible = entry.intersectionRatio >= 0.25;
    updatePlayback();
  }, {threshold: 0.25}).observe(stage);

  updateStill();
  updatePlayback();
}
