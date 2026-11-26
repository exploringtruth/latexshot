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
  let visible = false;
  let playbackUnavailable = false;

  const shouldPlay = () => visible && !document.hidden && !reducedMotion.matches;
  const updateStill = () => {
    const started = video.classList.contains("started");
    const showPoster = !started && poster.naturalWidth > 0;
    poster.classList.toggle("available", showPoster);
    fallback.hidden = started || showPoster;
  };
  const showStill = () => {
    video.hidden = true;
    video.classList.remove("started");
    updateStill();
  };
  const stopAfterFailure = () => {
    playbackUnavailable = true;
    showStill();
  };
  const updatePlayback = () => {
    if (playbackUnavailable) return;

    if (!shouldPlay()) {
      video.pause();
      if (reducedMotion.matches) showStill();
      return;
    }
    if (!video.paused) return;

    video.hidden = false;
    video.play().catch(error => {
      // Scrolling or switching tabs can pause a pending play request.
      if (error.name !== "AbortError") stopAfterFailure();
    });
  };

  video.addEventListener("playing", () => {
    if (playbackUnavailable || !shouldPlay()) {
      video.pause();
      return;
    }
    video.classList.add("started");
    updateStill();
  });
  video.addEventListener("error", stopAfterFailure);
  poster.addEventListener("load", updateStill);
  poster.addEventListener("error", updateStill);
  reducedMotion.addEventListener("change", updatePlayback);
  document.addEventListener("visibilitychange", updatePlayback);
  new IntersectionObserver(([entry]) => {
    visible = entry.intersectionRatio >= 0.25;
    updatePlayback();
  }, {threshold: 0.25}).observe(stage);

  updateStill();
}
