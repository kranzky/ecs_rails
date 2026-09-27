// ECS-35 rendered and accessibility review, page by page. For every page in
// tmp/qa/pages.json: full-page screenshots at desktop (1280) and phone (390,
// emulated) widths in light and dark schemes; an axe-core scan (WCAG 2.1 A/AA
// plus best practice) per scheme; a phone horizontal-overflow check; and a
// keyboard pass recording each Tab stop and whether it shows a focus ring.
//
//   cd script/qa && npm install
//   node pages.js [run-name] [page,page,...]    # the dev server on :3021
//
// Results: tmp/qa/<run-name>/report.json and the screenshots beside it.
const fs = require("fs");
const path = require("path");
const puppeteer = require("puppeteer-core");
const axeSource = fs.readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");

const BASE = process.env.BASE_URL || "http://localhost:3021";
// Any installed Chrome or Chromium; puppeteer-core downloads no browser.
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const OUT = path.join(__dirname, "../../tmp/qa", process.argv[2] || "pages");
const ONLY = process.argv[3] ? process.argv[3].split(",") : null;
const { pages, grace, product_edit } = JSON.parse(fs.readFileSync(path.join(__dirname, "../../tmp/qa/pages.json")));
fs.mkdirSync(OUT, { recursive: true });

const viewports = {
  desktop: { width: 1280, height: 900, deviceScaleFactor: 1 },
  phone: { width: 390, height: 844, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
};

async function actAs(page, userId) {
  await page.goto(BASE + "/about", { waitUntil: "networkidle0" });
  await page.select("#acting_as_user_id", userId);
  await Promise.all([page.waitForNavigation({ waitUntil: "networkidle0" }), page.click('.acting-bar__form input[type="submit"]')]);
}

async function keyboardPass(page) {
  await page.evaluate(() => document.activeElement && document.activeElement.blur());
  const stops = [];
  for (let i = 0; i < 45; i++) {
    await page.keyboard.press("Tab");
    const stop = await page.evaluate(() => {
      const el = document.activeElement;
      if (!el || el === document.body) return null;
      const cs = getComputedStyle(el);
      const ring = (cs.outlineStyle !== "none" && parseFloat(cs.outlineWidth) > 0) || (cs.boxShadow && cs.boxShadow !== "none");
      const name = (el.getAttribute("aria-label") || el.innerText || el.value || el.name || el.id || "").trim().slice(0, 40);
      return { tag: el.tagName.toLowerCase(), name, ring };
    });
    if (!stop) break;
    stops.push(stop);
  }
  return stops;
}

(async () => {
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
  });
  const report = {};
  const targets = Object.entries(pages).concat([["product-edit", product_edit]]);
  for (const [name, url] of targets) {
    if (ONLY && !ONLY.includes(name)) continue;
    report[name] = {};
    for (const scheme of ["light", "dark"]) {
      for (const [vpName, vp] of Object.entries(viewports)) {
        const page = await browser.newPage();
        await page.setViewport(vp);
        await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: scheme }]);
        if (name === "product-edit") await actAs(page, grace);
        const response = await page.goto(BASE + url, { waitUntil: "networkidle0" });
        const key = `${vpName}-${scheme}`;
        const entry = { status: response.status(), finalUrl: page.url().replace(BASE, "") };
        await page.screenshot({ path: path.join(OUT, `${name}-${key}.png`), fullPage: true });
        if (vpName === "phone") {
          entry.overflow = await page.evaluate(() => {
            const wide = [...document.querySelectorAll("body *")].filter((el) => {
              const r = el.getBoundingClientRect();
              return r.right > window.innerWidth + 1 && getComputedStyle(el).position !== "fixed" && !el.closest(".table-scroll, pre, svg");
            });
            return { scrollWidth: document.documentElement.scrollWidth, innerWidth: window.innerWidth,
                     offenders: wide.slice(0, 5).map((el) => el.tagName.toLowerCase() + (el.className ? "." + String(el.className).split(" ")[0] : "")) };
          });
        } else {
          await page.evaluate(axeSource);
          const axe = await page.evaluate(async () => {
            const r = await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "best-practice"] } });
            return r.violations.map((v) => ({ id: v.id, impact: v.impact, count: v.nodes.length,
              targets: v.nodes.slice(0, 4).map((n) => n.target.join(" ")), summary: v.nodes[0] && v.nodes[0].failureSummary.split("\n").slice(0, 3).join(" ") }));
          });
          entry.axe = axe;
          if (scheme === "light") entry.keyboard = await keyboardPass(page);
        }
        report[name][key] = entry;
        await page.close();
      }
    }
    process.stdout.write(name + " ");
  }
  fs.writeFileSync(path.join(OUT, "report.json"), JSON.stringify(report, null, 2));
  await browser.close();
  console.log("\ndone");
})();
