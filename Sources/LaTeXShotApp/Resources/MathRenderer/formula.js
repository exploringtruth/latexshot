const mathJaxBundle = 'mathjax-3.2.2/tex-svg-full.js';
const mathJaxSafe = new URL('mathjax-3.2.2/ui/safe.js', document.baseURI).href;
let mathJaxReady;

function loadScript(path) {
    return new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = path;
        script.onload = resolve;
        script.onerror = () => reject(new Error('Could not load ' + path));
        document.head.append(script);
    });
}

function loadMathJax() {
    if (!mathJaxReady) {
        let timeout;
        mathJaxReady = new Promise((resolve, reject) => {
            timeout = setTimeout(() => reject(new Error('MathJax startup timed out')), 2000);
            window.MathJax = {
                loader: {
                    load: ['ui/safe'],
                    source: { 'ui/safe': mathJaxSafe },
                    // The combined bundle contains the TeX packages and SVG glyphs.
                    require: url => url === mathJaxSafe
                        ? loadScript(mathJaxSafe)
                        : Promise.reject(new Error('Unexpected MathJax component')),
                    failed: reject
                },
                startup: {
                    typeset: false,
                    ready() {
                        MathJax.startup.defaultReady();
                        MathJax.startup.promise.then(resolve, reject);
                    }
                },
                tex: {
                    // Only preloaded math packages. Leave out extension loading, HTML,
                    // style escapes and packages that substitute output for TeX errors.
                    packages: [
                        'base', 'ams', 'amscd', 'boldsymbol', 'braket', 'bussproofs',
                        'cancel', 'cases', 'centernot', 'empheq', 'extpfeil', 'gensymb',
                        'mathtools', 'mhchem', 'newcommand', 'textcomp', 'textmacros',
                        'upgreek', 'verb'
                    ],
                    maxMacros: 1000,
                    formatError(_jax, error) { throw error; }
                },
                svg: { fontCache: 'local' },
                options: {
                    enableMenu: false,
                    safeOptions: {
                        allow: { URLs: 'none', classes: 'none', cssIDs: 'none', styles: 'none' }
                    }
                }
            };
            loadScript(mathJaxBundle).then(() => {
                if (!MathJax.startup?.promise) {
                    reject(new Error('MathJax did not initialize'));
                }
            }, reject);
        }).finally(() => clearTimeout(timeout));
    }
    return mathJaxReady;
}

async function renderFormula(formula, naturalSize = false) {
    const view = document.getElementById('formula');
    document.body.classList.toggle('natural-size', naturalSize);
    view.style.transform = '';
    view.replaceChildren();
    try {
        katex.render(formula, view, {
            displayMode: true, throwOnError: true, trust: false, maxSize: 20, maxExpand: 1000
        });
    } catch {
        try {
            await loadMathJax();
            const rendered = MathJax.tex2svg(formula, { display: true });
            if (!rendered.querySelector('svg') || rendered.querySelector('[data-mjx-error], [data-mml-node="merror"]')) {
                return false;
            }
            view.replaceChildren(rendered);
        } catch {
            return false;
        }
    }
    // Flush layout so the inserted KaTeX glyphs request their fonts before we await them.
    view.getBoundingClientRect();
    await document.fonts.ready;
    if (!naturalSize) fitFormula();
    return true;
}

function fitFormula() {
    const view = document.getElementById('formula');
    const scale = Math.min(1, Math.max(0, innerWidth - 8) / view.offsetWidth,
        Math.max(0, innerHeight - 8) / view.offsetHeight);
    if (Number.isFinite(scale)) view.style.transform = 'scale(' + scale + ')';
}

window.addEventListener('resize', () => {
    if (!document.body.classList.contains('natural-size')) fitFormula();
});
