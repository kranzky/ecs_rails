// ECS-35 review of states a URL alone does not reach: validation errors, a
// declined checkout, empty results, an empty basket, a filtered geocoder.
// Records axe results, phone overflow and the page's role="alert"/"status"
// messages (what a screen reader announces). Run pages.rb first, then:
//
//   node states.js [run-name]
const fs = require("fs");
const path = require("path");
const puppeteer = require("puppeteer-core");
const axeSource = fs.readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");
const BASE = process.env.BASE_URL || "http://localhost:3021";
// Any installed Chrome or Chromium; puppeteer-core downloads no browser.
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const OUT = path.join(__dirname, "../../tmp/qa", process.argv[2] || "states");
const ids = JSON.parse(fs.readFileSync(path.join(__dirname, "../../tmp/qa/pages.json")));
fs.mkdirSync(OUT, { recursive: true });

async function actAs(page, userId) {
  await page.goto(BASE + "/about", { waitUntil: "networkidle0" });
  await page.select("#acting_as_user_id", userId);
  await Promise.all([page.waitForNavigation({ waitUntil: "networkidle0" }), page.click('.acting-bar__form input[type="submit"]')]);
}
async function submit(page, selector) {
  await Promise.all([page.waitForNavigation({ waitUntil: "networkidle0" }), page.click(selector)]);
}

const flows = {
  "person-invalid": async (page) => {
    await page.goto(BASE + "/users/new", { waitUntil: "networkidle0" });
    await page.type("input[name=\"user[email]\"]", "not-an-email");
    await submit(page, 'form input[type="submit"][value="Add person"]');
  },
  "product-invalid": async (page) => {
    await actAs(page, ids.ada); // Ada owns Analytical Engines
    await page.goto(BASE + `/products/new?company_id=${ids.engines}`, { waitUntil: "networkidle0" });
    await page.$eval('input[name="product[sku]"]', (el) => (el.value = "AE-DE2")); // taken
    await page.type('input[name="product[title]"]', "Duplicate SKU");
    await submit(page, 'form input[type="submit"]:not([value="Switch"])');
  },
  "checkout-declined": async (page) => {
    await actAs(page, ids.alan);
    await page.goto(BASE + `/users/${ids.alan}/checkout/new`, { waitUntil: "networkidle0" });
    const fill = async (name, value) => page.$eval(`[name="${name}"]`, (el, v) => (el.value = v), value);
    await fill("checkout[shipping][line1]", "Hollymeade");
    await fill("checkout[shipping][locality]", "Wilmslow");
    await fill("checkout[shipping][country]", "GB");
    await fill("checkout[card_number]", "4000000000000002");
    await submit(page, 'form input[type="submit"]:not([value="Switch"])');
  },
  "posts-empty-search": async (page) => page.goto(BASE + "/posts?q=zzzzqqq", { waitUntil: "networkidle0" }),
  "market-empty-search": async (page) => page.goto(BASE + "/products?q=zzzzqqq", { waitUntil: "networkidle0" }),
  "basket-empty": async (page) => page.goto(BASE + `/users/${ids.katherine}/basket`, { waitUntil: "networkidle0" }),
  "geocoder-users": async (page) => page.goto(BASE + "/geocoder?model=users", { waitUntil: "networkidle0" }),
};

(async () => {
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: true });
  const report = {};
  for (const [name, flow] of Object.entries(flows)) {
    report[name] = {};
    for (const scheme of ["light", "dark"]) {
      for (const [vp, size] of [["desktop", { width: 1280, height: 900 }], ["phone", { width: 390, height: 844, deviceScaleFactor: 2, isMobile: true }]]) {
        const page = await browser.newPage();
        await page.setViewport(size);
        await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: scheme }]);
        await flow(page);
        await page.screenshot({ path: path.join(OUT, `${name}-${vp}-${scheme}.png`), fullPage: true });
        const entry = { url: page.url().replace(BASE, "") };
        entry.alerts = await page.$$eval('[role="alert"], [role="status"]', (els) => els.map((el) => `${el.getAttribute("role")}: ${el.innerText.trim().slice(0, 120)}`));
        if (vp === "desktop") {
          await page.evaluate(axeSource);
          entry.axe = await page.evaluate(async () => (await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "best-practice"] } }))
            .violations.map((v) => `${v.id} (${v.nodes.length}) ${v.nodes[0].target.join(" ")}`));
        } else {
          entry.overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
        }
        report[name][`${vp}-${scheme}`] = entry;
        await page.close();
      }
    }
  }
  fs.writeFileSync(path.join(OUT, "report.json"), JSON.stringify(report, null, 2));
  for (const [name, v] of Object.entries(report)) {
    const d = v["desktop-light"];
    console.log(name, "|", d.url, "| axe light:", d.axe.length, "dark:", v["desktop-dark"].axe.length, "| overflow:", v["phone-light"].overflow, "|", d.alerts.join(" / ") || "(no alert)");
    for (const a of [...d.axe, ...v["desktop-dark"].axe]) console.log("   ", a);
  }
  await browser.close();
})();
