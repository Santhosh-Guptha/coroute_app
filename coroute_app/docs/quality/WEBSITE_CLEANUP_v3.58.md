# Website cleanup: one place for each idea (v3.58, ships with build 3.55.0+10030)

Owner request (14 Nov 2026): "the website has become so big with so many repeated things, resolve it".

## What was repeated

The home page had grown to 22 sections and about 4,600 words. Crash detection and SOS were explained six times
(hero, scroll story, "Six things", "Built for the moment", "If something goes wrong", FAQ). The group map, intercom,
regroup and lead/sweep were explained four times (story, "Six things", "Day five... still together", "Get safety for
your group rides"). The site had two FAQs that disagreed: the how-it-works one still said the intercom needs mobile
data and that the host pays for a membership. Community totals appeared three times (home "in numbers", home "impact",
features strip) and the leaderboard twice.

## What changed

| Before (home) | Now |
|---|---|
| Built for the moment nobody plans for; If something goes wrong | Told by the scroll story and "Six things"; full detail on /safety and /features (now linked from "Six things") |
| Day five, still together; Get safety for your group rides | Same: story + "Six things"; detail on /features |
| Every ride becomes a story you keep; Know your riding (ride analytics) | Story chapter 7; /features "Every ride becomes a story you keep" (same heading as before) with the ride analytics item |
| Ready before the first kick-start | /how-it-works (the final call to action links it) |
| CoRoute in numbers + impact + leaderboard teaser | One impact block (hidden until real numbers), linking /leaderboard |
| Help us build (rate + idea cards) | Rate card moved under the rider reviews; ideas go through the feedback form (topic "Safety idea") |
| Home FAQ (10) + how-it-works FAQ (6, partly outdated) | One FAQ of 12 on /how-it-works#faq, the current answers; the home final call to action links it |
| /features impact strip | Removed (home has the full block, /safety keeps its safety strip) |

Home page now: hero, scroll story, six things, comparison, impact, privacy, pricing (free promise), reviews + rate,
latest news, final call to action, feedback: 11 sections, about 2,500 words (-46 %).

Code removed with it: the "CoRoute in numbers" / ride analytics script block in site.js (about 10 KB), and every CSS
rule whose class is no longer used anywhere on the site (home.css, site.css, pages.css; checked against all HTML, JS,
and the gateway's HTML generators, keeping class prefixes that scripts build at run time such as rv-card--). A
before/after screenshot comparison of all 26 pages at 390 px and 1280 px showed no visual change from the CSS clean-up.

| File | Before | After |
|---|---|---|
| index.html | 85 KB | 54 KB |
| home.css | 68 KB | 44 KB |
| pages.css | 55 KB | 30 KB |
| site.css | 59 KB | 57 KB |
| site.js | 65 KB | 55 KB |
| Total of these + features/how-it-works | 382 KB | 289 KB (-24 %) |

## Kept on purpose

- The scroll story (the home page's main idea) and the comparison table (the only place it exists).
- The short privacy section on home ("Your location is for your group"): it is the main worry riders have; the full
  page is /privacy-and-security.
- The permissions summary on /how-it-works (four lines, links the full list on /get) and the step-by-step permissions in
  the guide: different readers, different depth.
- The #feedback anchor (e-mails link to /#feedback) and #pricing / #community-free (the hero links them).

## Tests updated on purpose

website.test.js, website_privacy_messaging, website_impact_355, website_ios_blocks, website_leaderboard_355,
website_live, website_stories_render: they now check that the duplicates are gone, that the home links the detail
pages, and that the FAQ lives on /how-it-works.
