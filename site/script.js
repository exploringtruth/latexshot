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
