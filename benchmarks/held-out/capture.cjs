// Capture original MathML in archived source pages using Chrome's native renderer.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {spawn} = require('node:child_process');
const crypto = require('node:crypto');
const [cache, directory] = process.argv.slice(2);
if (!cache || !directory) throw new Error('Pass source HTML cache and frozen corpus directory');
const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json')));
const before = crypto.createHash('sha256').update(JSON.stringify(manifest)).digest('hex');
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'latexshot-corpus-chrome-'));
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const child = spawn(chrome, ['--headless', '--no-first-run', '--disable-background-networking',
    '--hide-scrollbars', '--remote-debugging-port=0', '--user-data-dir=' + profile, 'about:blank'],
    {stdio: ['ignore', 'ignore', 'pipe']});
let nextId = 0;
const pending = new Map();
let socket;
function send(method, params = {}) {
    const id = ++nextId;
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {pending.delete(id); reject(new Error(method + ' timed out'));}, 45000);
        pending.set(id, {resolve, reject, timer});
        socket.send(JSON.stringify({id, method, params}));
    });
}
async function evaluate(expression) {
    const reply = await send('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true});
    if (reply.exceptionDetails) throw new Error(JSON.stringify(reply.exceptionDetails));
    return reply.result.value;
}
async function main() {
    const endpoint = await new Promise((resolve, reject) => {
        let output = '';
        child.stderr.on('data', data => {output += data; const match = output.match(/DevTools listening on (ws:\/\/\S+)/); if (match) resolve(match[1]);});
        child.on('exit', code => reject(new Error('Chrome exited ' + code)));
    });
    const address = endpoint.replace(/^ws:/, 'http:').replace(/\/devtools\/browser\/.*$/, '/json/list');
    const pages = await (await fetch(address)).json();
    socket = new WebSocket(pages.find(page => page.type === 'page').webSocketDebuggerUrl);
    await new Promise(resolve => socket.addEventListener('open', resolve, {once: true}));
    socket.addEventListener('message', event => {
        const reply = JSON.parse(event.data);
        if (!pending.has(reply.id)) return;
        const call = pending.get(reply.id); pending.delete(reply.id); clearTimeout(call.timer);
        if (reply.error) call.reject(new Error(JSON.stringify(reply.error))); else call.resolve(reply.result);
    });
    await send('Page.enable');
    await send('Emulation.setDeviceMetricsOverride', {width: 1500, height: 1100, deviceScaleFactor: 1, mobile: false});
    fs.mkdirSync(path.join(directory, 'crops'), {recursive: true});
    for (const source of [...new Set(manifest.map(row => row.source_page))]) {
        let html = fs.readFileSync(path.join(cache, source + '.html'), 'utf8');
        html = html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '');
        html = html.replace('<head>', '<head><base href="https://en.wikipedia.org/">');
        const archive = path.join(profile, source + '.html');
        fs.writeFileSync(archive, html);
        await send('Page.navigate', {url: 'file://' + archive});
        await evaluate('new Promise(resolve => {if(document.readyState === "complete") resolve(); else window.addEventListener("load", resolve, {once:true});})');
        await evaluate('document.fonts.ready.then(() => true)');
        for (const row of manifest.filter(item => item.source_page === source)) {
            const input = JSON.stringify({id: row.source_node_id, latex: row.latex, category: row.category});
            const bounds = await evaluate(`(async () => {
                const input = ${input};
                const node = (input.id && document.getElementById(input.id)) || [...document.querySelectorAll('math[data-mw]')].find(
                    element => JSON.parse(element.getAttribute('data-mw')).body?.extsrc?.trim() === input.latex);
                if (!node || JSON.parse(node.getAttribute('data-mw')).body.extsrc.trim() !== input.latex) throw new Error('Ground truth mismatch');
                document.getElementById('corpus-render-style')?.remove();
                const style = document.createElement('style'); style.id = 'corpus-render-style';
                style.textContent = input.category === 'dark-background'
                    ? 'html,body,.mw-body,.mw-parser-output{background:#181818!important;color:#eee!important}math{color:#eee!important}'
                    : 'html,body,.mw-body,.mw-parser-output{background:white!important;color:black!important}math{color:black!important}';
                if (input.category === 'small-type') style.textContent += 'math{font-size:12px!important}';
                document.head.append(style);
                await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                const rect = node.firstElementChild.getBoundingClientRect();
                const padding = node.getAttribute('display') === 'block' ? 6 : 2;
                if (rect.width < 2 || rect.height < 2) throw new Error('Empty math bounds');
                return {x:Math.max(0,rect.x+scrollX-padding),y:Math.max(0,rect.y+scrollY-padding),width:rect.width+padding*2,height:rect.height+padding*2,scale:1};
            })()`);
            const image = await send('Page.captureScreenshot', {format: 'png', clip: bounds, captureBeyondViewport: true});
            const data = Buffer.from(image.data, 'base64');
            fs.writeFileSync(path.join(directory, row.image), data);
            row.image_sha256 = crypto.createHash('sha256').update(data).digest('hex');
            row.capture_bounds_css_px = bounds;
            console.log(row.id, Math.round(bounds.width), Math.round(bounds.height));
        }
    }
    fs.writeFileSync(path.join(directory, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
    const version = await send('Browser.getVersion');
    fs.writeFileSync(path.join(directory, 'capture.json'), JSON.stringify({source_manifest_sha256: before,
        browser: version, mode: 'Original archived Wikipedia page HTML with original native MathML',
        changes: 'Scripts removed to prevent asynchronous layout changes. Base URL restored for linked styles. Light/dark and small-type style overrides recorded per case.',
        cases: manifest.length}, null, 2) + '\n');
}
main().catch(error => {console.error(error); process.exitCode = 1;}).finally(() => {
    socket?.close(); child.kill();
});
