# Device test checklist

Your hands-on test on the real iPhone 17 Pro and Apple Watch SE. Each step says what you should see, and what to do if you don't. If anything fails, tell me what you saw (a photo of the screen is fine). With Remote Control on, I can read your Diagnostics uploads from the Mac and fix things while you test.

**Time needed:** about 45 minutes today, then a few minutes each day for 3 days.

---

## Part A: one-time setup (Mac + phone + watch)

### A1. Sign in to Xcode
1. On the Mac, open **Xcode → Settings → Accounts**, click **+**, choose **Apple Account**, and sign in.
2. Select your account. Under **Team** you should see "*(Your name)* (Personal Team)".

✅ **Expected:** a Personal Team is listed.
❌ **If not:** quit and reopen Xcode and try again. A free account is enough.

### A2. Tell the project your Team ID
1. In Xcode → Settings → Accounts → your account, click the team. Its 10-character **Team ID** is shown, or ask me and I'll read it with `security find-identity` once you're signed in.
2. In Terminal: `open -e ~/Developer/fengshui/apple/Config/Local.xcconfig` and change the line to `DEVELOPMENT_TEAM = ABCDE12345` (your ID). Save.

✅ **Expected:** the file has your ID. It's gitignored and never committed.

### A3. Turn on Developer Mode
1. **iPhone:** connect it to the Mac with a cable, unlock it, and tap **Trust** if asked. Then Settings → Privacy & Security → **Developer Mode** → On → restart → confirm.
2. **Watch:** on the watch, Settings → Privacy & Security → **Developer Mode** → On → restart. If the option isn't there, it appears after step A4 tries to install once.

✅ **Expected:** after restarting, both show Developer Mode on.

### A4. Install both apps
In Terminal:
```
cd ~/Developer/fengshui
scripts/install_on_devices.sh
```
Then on the iPhone, open the **Watch** app → My Watch → scroll to **Available Apps** → **Fengshui** → **Install**.

✅ **Expected:** "Done." in Terminal; the Fengshui icon on the iPhone; after a minute, on the watch too.
❌ **"Untrusted Developer" on the iPhone:** Settings → General → VPN & Device Management → your Apple Account → **Trust**.
❌ **Signing / provisioning error in Terminal:** open `apple/Fengshui.xcodeproj` in Xcode, select the Fengshui target → Signing & Capabilities, and send me a screenshot. If Xcode mentions an App ID limit, tell me; free accounts allow only a few new App IDs per week.
❌ **The watch app won't install (watchOS 10.6.2):** note the exact message. This is one of the things only this test can check.

### A5. Start the Mac server
```
scripts/run_server.sh
```
The first time, it prints a **token**. Keep the Terminal window open.

✅ **Expected:** `Uvicorn running on http://0.0.0.0:8765`.

---

## Part B: first launch on the iPhone

Open **Fengshui** on the iPhone.

| Step | What you do | ✅ Expected | ❌ If not |
| --- | --- | --- | --- |
| B1 | **Get started** | Health screen | — |
| B2 | **Allow Health access**, then **Turn On All** → **Allow** | Health permission sheet lists many types (≈ 200) | If the sheet doesn't appear, Settings → Health → Data Access & Devices → Fengshui → Turn On All |
| B3 | Recording: leave the defaults, **Continue** | Places screen; a location prompt appears | — |
| B4 | Location prompt: **Allow While Using App**; later iOS asks again → **Change to Always Allow** | — | Settings → Fengshui → Location → **Always** (needed for arriving Home) |
| B5 | Places: **Home** → "Use current location" (or tap the map) → **Save**; same for **Work**; optionally add others | "Set ✓" next to Home and Work | — |
| B6 | Sleep questions: set your usual wake times and bedtime → **Continue** | Notifications screen | — |
| B7 | **Allow notifications** → **Allow** | Backfill screen with a progress bar | Settings → Notifications → Fengshui → Allow |
| B8 | Wait for the backfill (your history is large: about 10–20 min). Keep the app open and the phone plugged in | "… samples · N/N types", then **Continue** becomes active | If it stops with an error, tap **Retry**: it resumes where it stopped |
| B9 | **Continue** | Today screen; within a minute "Start winding down …" with a time | Pull down to refresh |

### B9b. Data tab
Tap **Data**. ✅ Vitals, Today and Last night tiles appear, and the status line says "Live · updated …". Tap a tile to see its chart and samples. Open Fengshui on the watch, then tap **Ask watch to send now**: "Last data from watch" should change to "just now" within a minute. Start a session on the watch: a pulsing **live heart rate** card appears on the phone.
❌ "No data yet": the Health permission isn't granted. Settings → Privacy & Security → Health → Fengshui → Turn On All.

### B9c. Reports, bell and health monitor
- **Reports** tab → **30 d** → **Create PDF report**. ✅ A PDF opens. The share button saves or sends it, and the bell shows **1**.
- With a key (B11): **Let AI choose the data** → check the reasons under "Data to include" → **Create PDF report**. The PDF opens with an AI summary.
- **Ask** a question. ✅ Under the answer, "Report saved · open". It's also under Reports → Questions.
- **Bell** → **Select** → **Select all** → **Delete**. ✅ Empty, and the badge is gone.
- Settings → **Health monitor** (after B10) → every **5 min** for **1 h** → **Start**. Keep the app open: "Checks with data" counts up, and it says "Pull mode" (push needs the paid account). To let the Mac's agent use Claude, run `security add-generic-password -a "$USER" -s fengshui-anthropic -w` in Terminal. It asks for the key without showing it. Then restart the server.

### B10. Connect the app to the Mac
Settings → **Server & compute** → **Find on this network** (or type `http://<your-mac>.local:8765`) → paste the **token** from A5 → **Save & test connection**.
✅ **Expected:** "Connected ✓". Allow the **Local Network** prompt if it appears.
❌ Make sure the iPhone and the Mac are on the same Wi-Fi, and that A5 is still running.

### B11. Claude (optional)
Settings → **Claude** → paste your Anthropic API key → **Save**. Then the **Ask** tab → tap **"How active was I today?"**
✅ **Expected:** an answer that mentions which data it used, with "N tool calls" under it.

### B12. Run Diagnostics
Settings → Device test → **Diagnostics** → **Run diagnostics**.
✅ **Expected:** "Uploaded to the Mac ✓". Then tell me "diagnostics uploaded" and I'll read it on the Mac. Several checks will be ⚠️ on day 1 (for example background delivery not fired yet, no visits yet). That's normal.

---

## Part C: things only your devices can confirm

I read most of these from your Diagnostics upload. What to look at:

| Check | Where | ✅ Expected | Notes |
| --- | --- | --- | --- |
| C1 HealthKit **background delivery** works on a Personal Team | Diagnostics → *background delivery fired* (after a few hours with the app closed) | ≥ 1 wake | If 0 after a day, the app still syncs on launch and background refresh (by design), but tell me |
| C2 **Signing expiry** shown | Settings → "Signing expires in N days" | 6 or 7 days | You get a reminder the day before; reinstall with A4 |
| C3 Watch app runs on **watchOS 10.6.2** | Watch → Fengshui | Status screen: Accelerometer On, "Waiting for iPhone: N files" | Tap **Sync now** once |
| C4 **Sensor recording** | Diagnostics → *raw coverage 24h* (next day) | > 50 % of minutes | Gaps during sleep are expected (watchOS pauses recording); they're measured, not hidden |
| C5 **Transfer to phone** | Watch status "Waiting for iPhone" goes to 0; Diagnostics coverage rises | — | Keep the iPhone near the watch |
| C6 **Real compression ratio** | Diagnostics → *raw compression ratio* | about 3× (lab: 3.1–3.5×) | — |
| C7 **Compass without location** | Diagnostics → *compass chunks* > 0 | — | The watch never asks for location |
| C8 Optional complication | Long-press the watch face → Edit → Complications → **Fengshui** | Shows "FS ✓" or "FS N" | Gives the app more background time |
| C9 Recording **session** | Watch → Fengshui → **Start session**, walk 5 min, **Stop** | HR shown while running; a workout appears in Health | — |

---

## Part D: wear both for 3 days

**Every day**
- Wear the watch as usual and charge it as usual. The app copes with charging breaks.
- In the evening: the **wind-down notification** should arrive at the time shown on Today. Note roughly when it arrived. If you're out, arriving home within 90 minutes after that time sends a "Welcome home" reminder.
- Morning: open the app once. Today shows yesterday's activity timeline: do the walks, drives and workouts look right?

**Run Diagnostics again** (Settings → Device test → Diagnostics) on **day 2 evening** and **day 3 evening**, and tell me each time.

**Day 3 checks**

| Check | ✅ Expected |
| --- | --- |
| Wind-down notification fired each night | Settings → Debug → Notification log: each `wind_down_<date>` has "delivered … delay N s" with N ≤ 300 |
| Activity looks plausible | Today's bouts match what you remember; logged workouts show as workouts |
| Claude answers the three preset questions | Ask tab → tap each; answers cite tool data |
| Raw data older than 7 days archived | After day 7 (or ask me to check sooner): Settings → Server & compute → **Sync now**; Diagnostics shows chunks archived |
| Battery | Note watch battery at bedtime each day; Diagnostics records phone battery |

---

## When something goes wrong
- **App won't open after ~7 days:** the free signing expired. Run `scripts/install_on_devices.sh` again; your data is kept.
- **No notification:** Settings → Notifications → Fengshui is on? Settings → Wind-down → reminders on? Run Diagnostics and tell me.
- **Anything else:** run Diagnostics (it uploads to the Mac) and send me a message. I'll read it, fix it, re-run the tests, and tell you what to reinstall.
