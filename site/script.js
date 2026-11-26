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

for (const image of document.querySelectorAll(".motion-stage img")) {
  const hideFailedImage = () => { image.hidden = true; };

  image.addEventListener("error", hideFailedImage);
  if (image.complete && image.naturalWidth === 0) hideFailedImage();
}

for (const stage of document.querySelectorAll(".motion-stage")) {
  const video = stage.querySelector(".motion-video");
  const animation = stage.querySelector(".motion-animation");
  const control = stage.querySelector(".motion-control");
  let pausedByUser = false;

  const showFallback = () => {
    video.classList.remove("has-frame");
    animation.hidden = pausedByUser || (animation.complete && animation.naturalWidth === 0);
  };
  const showVideo = () => {
    if (pausedByUser) {
      video.pause();
      return;
    }
    video.classList.add("has-frame");
    animation.hidden = true;
  };

  video.addEventListener("playing", showVideo);
  video.addEventListener("error", showFallback);
  video.addEventListener("pause", () => {
    if (!pausedByUser && video.paused) showFallback();
  });
  if (!video.paused && video.readyState >= 2) showVideo();

  control.hidden = false;
  control.addEventListener("click", () => {
    pausedByUser = !pausedByUser;
    control.setAttribute("aria-pressed", String(pausedByUser));
    if (pausedByUser) {
      video.pause();
      animation.hidden = true;
      return;
    }

    if (!video.classList.contains("has-frame")) showFallback();
    video.play().catch(() => {
      if (!pausedByUser && video.paused) showFallback();
    });
  });
}
