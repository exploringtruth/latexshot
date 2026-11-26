// Author-created printed equations. npm tools are used only to generate fixtures.
const fs = require('node:fs');
const path = require('node:path');
const {mathjax} = require('mathjax-full/js/mathjax.js');
const {TeX} = require('mathjax-full/js/input/tex.js');
const {SVG} = require('mathjax-full/js/output/svg.js');
const {liteAdaptor} = require('mathjax-full/js/adaptors/liteAdaptor.js');
const {RegisterHTMLHandler} = require('mathjax-full/js/handlers/html.js');
const {AllPackages} = require('mathjax-full/js/input/tex/AllPackages.js');
const sharp = require('sharp');
const PDFDocument = require('pdfkit');
const SVGtoPDF = require('svg-to-pdfkit');
const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);
const document = mathjax.document('', {InputJax: new TeX({packages: AllPackages}),
    OutputJax: new SVG({fontCache: 'none'})});
const directory = path.join(__dirname, 'fixtures');
fs.mkdirSync(directory, {recursive: true});

async function main() {
    const manifest = [];
    const pages = [];
    const pdf = new PDFDocument({autoFirstPage: false});
    const pdfStream = fs.createWriteStream(path.join(directory, 'printed.pdf'));
    pdf.pipe(pdfStream);
    for (let i = 1; i <= 10; i++) {
        const formulas = [
            ['fractions', `\\frac{x^{${i}}+${i}}{y+1}=\\frac{${i}}{2}`],
            ['roots', `\\sqrt{x+${i}}+\\sqrt[3]{y}=${i}`],
            ['matrices', `A=\\begin{pmatrix}${i}&2\\\\3&4\\end{pmatrix}`],
            ['aligned', `\\begin{aligned}x+y&=${i}\\\\x-y&=2\\end{aligned}`],
            ['small-type', `\\sum_{k=1}^{${i+10}} k^2=\\frac{n(n+1)(2n+1)}{6}`],
            ['dark-background', `\\int_0^${i} x^2\\,dx=\\frac{${i}^3}{3}`]
        ];
        for (const [category, latex] of formulas) {
            const id = `${category}-${String(i).padStart(2, '0')}`;
            const fontSize = category === 'small-type' ? 12 : 26;
            const dark = category === 'dark-background';
            let svg = adaptor.outerHTML(document.convert(latex, {display: true}));
            svg = svg.slice(svg.indexOf('<svg'), svg.lastIndexOf('</svg>')+6);
            svg = svg.replace(/width="([\d.]+)ex"/, (_, size) => `width="${Math.ceil(size*fontSize/2)}"`)
                .replace(/height="([\d.]+)ex"/, (_, size) => `height="${Math.ceil(size*fontSize/2)}"`)
                .replace(/currentColor/g, dark ? '#ffffff' : '#101010');
            await sharp(Buffer.from(svg)).extend({top: 15, bottom: 15, left: 15, right: 15,
                background: dark ? '#181818' : '#ffffff'}).flatten({background: dark ? '#181818' : '#ffffff'})
                .png().toFile(path.join(directory, `${id}.png`));
            pdf.addPage({size: [612, 180]});
            if (dark) pdf.rect(0,0,612,180).fill('#181818');
            SVGtoPDF(pdf, svg, 24, 24, {width: 560, height: 130, preserveAspectRatio: 'xMinYMin meet'});
            pages.push(`<article><p>${id}</p>${svg}</article>`);
            manifest.push({id, category, latex, image: `${id}.png`,
                source: 'Author-created MathJax SVG, also embedded in printed.pdf and printed.html',
                license: 'CC0-1.0', fontSize});
        }
    }
    pdf.end();
    fs.writeFileSync(path.join(directory, 'manifest.json'), JSON.stringify(manifest,null,2)+'\n');
    fs.writeFileSync(path.join(directory, 'printed.html'), '<!doctype html><meta charset="utf-8"><title>LaTeXShot printed fixtures</title>'+pages.join('\n'));
    await new Promise(resolve => pdfStream.on('finish', resolve));
}
main().catch(error => {console.error(error); process.exitCode=1;});
