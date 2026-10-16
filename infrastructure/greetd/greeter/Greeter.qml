// State and logic of the login screen (a singleton: `Greeter`): users, authentication (greetd or a fake backend), keyboard layout, which output
// shows the form, menus and key handling. The views (OutputView, FormPane, BottomBar) only bind to this object.
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Services.Greetd

Singleton {
    id: ctrl

    // ---- modes (environment) --------------------------------------------------------------------------------------
    // GREETER_DEMO=1: a floating window with two virtual outputs inside a running session (no layer shell, no dpms,
    // no marker file). Without a greetd socket the fake backend is used as well: the password "demo" succeeds and the
    // launch only quits. GREETER_TEST_SESSION=1: launch /usr/bin/true instead of the session (greetd PAM dry run).
    readonly property bool demoWindow: Quickshell.env("GREETER_DEMO") === "1"
    readonly property bool fakeAuth: demoWindow || !Greetd.available
    readonly property bool testSession: Quickshell.env("GREETER_TEST_SESSION") === "1"
    readonly property var demoScreens: ["DEMO-1", "DEMO-2"]

    // ---- configuration (users.json) -------------------------------------------------------------------------------
    property var cfg: ({ main: "", users: [], formOutputs: [], sessions: [] })
    readonly property var entries: {
        const list = [];
        for (let i = 0; i < cfg.users.length; i++) {
            const u = cfg.users[i];
            list.push({ kind: "user", name: u.name, accent: u.accent, main: u.name === cfg.main });
        }
        list.push({ kind: "other", name: "", accent: "aqua", main: false });
        return list;
    }
    readonly property var sessions: cfg.sessions

    FileView {
        id: usersFile
        path: Quickshell.shellPath("users.json")
        blockLoading: true
    }

    function accentColor(name: string): color {
        switch (name) {
        case "green": return Theme.green;
        case "orange": return Theme.orange;
        case "blue": return Theme.blue;
        case "purple": return Theme.purple;
        case "red": return Theme.red;
        case "yellow": return Theme.yellow;
        default: return Theme.aqua;
        }
    }

    // ---- selection and fields -------------------------------------------------------------------------------------
    property int selected: 0
    readonly property var current: entries[selected]
    readonly property bool otherSelected: current.kind === "other"
    property string field: "password"      // field that has the keyboard: "user" (Other user only) or "password"
    property string typedUser: ""
    property string password: ""
    readonly property string loginUser: otherSelected ? typedUser.trim() : current.name
    property int sessionIndex: 0

    signal focusRequested
    signal shake

    function selectEntry(index: int) {
        if (busy || fading)
            return;
        const n = entries.length;
        selected = ((index % n) + n) % n;
        field = otherSelected ? "user" : "password";
        password = "";
        clearStatus();
        focusRequested();
    }

    function setField(name: string) {
        if (name === "user" && !otherSelected)
            return;
        field = name;
        focusRequested();
    }

    // ---- status line ----------------------------------------------------------------------------------------------
    property string statusText: ""
    property int statusKind: 0              // 0 none, 1 info, 2 error
    property int attempts: 0
    property bool failed: false             // the last attempt failed and nothing was typed since

    function clearStatus() {
        statusText = "";
        statusKind = 0;
        failed = false;
    }

    onPasswordChanged: {
        if (password !== "" && failed)
            clearStatus();
    }

    function showStatus(text: string, kind: int) {
        statusText = text;
        statusKind = kind;
    }

    // ---- authentication -------------------------------------------------------------------------------------------
    property bool busy: false               // an authentication round is running
    property bool fading: false             // the screen fades to black before the session starts
    property bool awaitingExtra: false      // PAM asked a further question after the password
    property string extraPrompt: ""
    property bool extraEcho: false
    property bool passwordSent: false
    property bool fakeLaunched: false       // the fake backend reached the launch step
    property string pendingPassword: ""

    function submit() {
        if (busy || fading)
            return;
        if (awaitingExtra) {
            const answer = password;
            awaitingExtra = false;
            busy = true;
            clearStatus();
            password = "";
            if (fakeAuth)
                demoTimer.restart();
            else
                Greetd.respond(answer);
            return;
        }
        if (otherSelected && field === "user") {
            if (typedUser.trim() === "") {
                showStatus("Enter a user name", 2);
                return;
            }
            setField("password");
            return;
        }
        if (loginUser === "") {
            setField("user");
            showStatus("Enter a user name", 2);
            return;
        }
        if (password === "")
            return;
        busy = true;
        clearStatus();
        passwordSent = false;
        pendingPassword = password;
        if (fakeAuth)
            demoTimer.restart();
        else
            Greetd.createSession(loginUser);
    }

    // Esc: clear the password; with an empty field leave a pending PAM conversation, then leave "Other user...".
    function pressEscape() {
        if (menu !== "") {
            closeMenu();
        } else if (password !== "") {
            password = "";
            clearStatus();
        } else if (awaitingExtra) {
            awaitingExtra = false;
            cancelAuth();
        } else if (busy) {
            cancelAuth();
        } else if (otherSelected) {
            if (field === "password" && typedUser !== "")
                setField("user");
            else
                selectEntry(entryIndexOfMain());
        } else {
            clearStatus();
        }
    }

    function entryIndexOfMain(): int {
        for (let i = 0; i < entries.length; i++) {
            if (entries[i].main)
                return i;
        }
        return 0;
    }

    function cancelAuth() {
        busy = false;
        demoTimer.stop();
        if (!fakeAuth && Greetd.state !== GreetdState.Inactive)
            Greetd.cancelSession();
        password = "";
        clearStatus();
        focusRequested();
    }

    function authFailed() {
        busy = false;
        attempts += 1;
        pendingPassword = "";
        password = "";
        showStatus((otherSelected ? "Wrong user or password (" : "Wrong password (") + attempts + ")", 2);
        failed = true;
        shake();
        focusRequested();
    }

    function beginLaunch() {
        pendingPassword = "";
        fading = true;
        launchTimer.start();
    }

    function doLaunch() {
        const s = sessions[sessionIndex];
        const cmd = testSession ? ["/usr/bin/true"] : s.cmd;
        if (fakeAuth) {
            console.log("greeter: fake backend, would launch " + JSON.stringify(cmd) + " with " + JSON.stringify(s.env));
            fakeLaunched = true;
            if (Quickshell.env("GREETER_SELFTEST") !== "1")
                Qt.quit();
        } else {
            Greetd.launch(cmd, s.env, true);   // true: quickshell exits 0 once greetd has the session, which run-qs turns into greeter-ok
        }
    }

    Timer {
        id: launchTimer
        interval: 280
        onTriggered: ctrl.doLaunch()
    }

    // The fake backend: one second of "checking", then success for the password "demo".
    Timer {
        id: demoTimer
        interval: 900
        onTriggered: {
            if (ctrl.pendingPassword === "demo")
                ctrl.beginLaunch();
            else
                ctrl.authFailed();
        }
    }

    Connections {
        target: Greetd
        enabled: !ctrl.fakeAuth

        function onAuthMessage(message: string, error: bool, responseRequired: bool, echoResponse: bool) {
            if (!responseRequired) {
                ctrl.showStatus(message, error ? 2 : 1);
                return;
            }
            if (!ctrl.passwordSent) {
                ctrl.passwordSent = true;
                Greetd.respond(ctrl.pendingPassword);
                ctrl.pendingPassword = "";
                return;
            }
            // a further question (one-time code, ...): ask for it in the password field
            ctrl.extraPrompt = message;
            ctrl.extraEcho = echoResponse;
            ctrl.awaitingExtra = true;
            ctrl.busy = false;
            ctrl.password = "";
            ctrl.focusRequested();
        }

        function onAuthFailure(message: string) {
            ctrl.authFailed();
        }

        function onReadyToLaunch() {
            ctrl.beginLaunch();
        }

        function onError(error: string) {
            ctrl.busy = false;
            ctrl.password = "";
            ctrl.showStatus(error, 2);
            if (Greetd.state !== GreetdState.Inactive)
                Greetd.cancelSession();
            ctrl.focusRequested();
        }
    }

    // ---- outputs: the form follows the pointer --------------------------------------------------------------------
    property string pointerScreen: ""
    readonly property var screenNames: {
        if (demoWindow)
            return demoScreens;
        const names = [];
        const list = Quickshell.screens;
        for (let i = 0; i < list.length; i++)
            names.push(list[i].name);
        return names;
    }
    readonly property string formScreen: {
        if (screenNames.indexOf(pointerScreen) >= 0)
            return pointerScreen;
        for (let i = 0; i < cfg.formOutputs.length; i++) {
            if (screenNames.indexOf(cfg.formOutputs[i]) >= 0)
                return cfg.formOutputs[i];
        }
        return screenNames.length > 0 ? screenNames[0] : "";
    }

    function pointerEntered(name: string) {
        pointerScreen = name;
    }

    // Hyprland moves the monitor focus with the pointer (follow_mouse), which also works before the first pointer event.
    Connections {
        target: Hyprland
        enabled: !ctrl.demoWindow

        function onFocusedMonitorChanged() {
            if (Hyprland.focusedMonitor)
                ctrl.pointerScreen = Hyprland.focusedMonitor.name;
        }
    }

    // ---- keyboard layout indicator --------------------------------------------------------------------------------
    property string layoutName: ""
    readonly property string layoutCode: codeOfLayout(layoutName)
    readonly property bool layoutWarn: layoutCode !== "" && layoutCode !== "US"

    function codeOfLayout(name: string): string {
        if (name === "")
            return "";
        if (name.indexOf("English") === 0 || name.indexOf("(US)") >= 0)
            return "US";
        if (name.indexOf("Ukrainian") === 0)
            return "UA";
        if (name.indexOf("Russian") === 0)
            return "RU";
        return name.substring(0, 2).toUpperCase();
    }

    // `hyprctl -j devices`: the main keyboard's active_keymap is the layout in use
    function parseDevices(json: string) {
        try {
            const keyboards = JSON.parse(json).keyboards;
            let kb = keyboards[0];
            for (let i = 0; i < keyboards.length; i++) {
                if (keyboards[i].main)
                    kb = keyboards[i];
            }
            if (kb && layoutName === "")
                layoutName = kb.active_keymap;
        } catch (e) {
            console.log("greeter: cannot read the keyboard layout: " + e);
        }
    }

    // Hyprland event socket: activelayout>>keyboard name,layout name
    function onLayoutEvent(data: string) {
        layoutName = data.substring(data.lastIndexOf(",") + 1);
    }

    Process {
        command: ["hyprctl", "-j", "devices"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() !== "")
                    ctrl.parseDevices(text);
            }
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event.name === "activelayout")
                ctrl.onLayoutEvent(event.data);
        }
    }

    // ---- hostname, battery, clock ---------------------------------------------------------------------------------
    readonly property string hostname: hostFile.loaded ? hostFile.text().trim() : ""
    property int battery: -1

    FileView {
        id: hostFile
        path: "/etc/hostname"
    }

    FileView {
        id: batteryFile
        path: "/sys/class/power_supply/BAT0/capacity"
        onLoaded: {
            const v = parseInt(text());
            ctrl.battery = isNaN(v) ? -1 : v;
        }
    }

    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: batteryFile.reload()
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    readonly property string timeText: Qt.formatDateTime(clock.date, "HH:mm")
    readonly property string dateText: Qt.locale("en_US").toString(clock.date, "dddd, dd MMMM")

    // ---- idle: fade the form after 60 s, panels off after 300 s (OLED) ------------------------------------------------
    property bool idle: false

    IdleMonitor {
        timeout: 60
        onIsIdleChanged: ctrl.idle = isIdle && !ctrl.busy
    }

    IdleMonitor {
        timeout: 300
        enabled: !ctrl.demoWindow
        onIsIdleChanged: {
            if (isIdle)
                dpmsOff.running = true;
        }
    }

    Process {
        id: dpmsOff
        command: ["hyprctl", "dispatch", "hl.dsp.dpms({ action = \"off\" })"]
    }

    // ---- menus (session F2, power F12) ----------------------------------------------------------------------------
    property string menu: ""                // "", "session" or "power"
    property int menuIndex: 0
    readonly property var powerItems: [
        { label: "Suspend", glyph: "󰤄", cmd: ["systemctl", "suspend"] },
        { label: "Reboot", glyph: "󰜉", cmd: ["systemctl", "reboot"] },
        { label: "Power off", glyph: "󰐥", cmd: ["systemctl", "poweroff"] }
    ]
    readonly property int menuCount: menu === "session" ? sessions.length : powerItems.length

    function openMenu(name: string) {
        if (busy || fading)
            return;
        if (menu === name) {
            closeMenu();
            return;
        }
        menu = name;
        menuIndex = name === "session" ? sessionIndex : 0;
    }

    function closeMenu() {
        menu = "";
        focusRequested();
    }

    function menuMove(delta: int) {
        menuIndex = (menuIndex + delta + menuCount) % menuCount;
    }

    function menuActivate(index: int) {
        if (menu === "session") {
            sessionIndex = index;
        } else if (menu === "power") {
            if (demoWindow) {
                showStatus("Power actions are disabled in demo mode", 1);
            } else {
                powerProc.command = powerItems[index].cmd;
                powerProc.running = true;
            }
        }
        closeMenu();
    }

    Process {
        id: powerProc
        onExited: exitCode => {
            if (exitCode !== 0)
                ctrl.showStatus("Power action failed (exit " + exitCode + ")", 2);
        }
    }

    // ---- keys -----------------------------------------------------------------------------------------------------
    // Letters are matched by physical key (xkb keycode = evdev + 8: H 43, J 44, K 45, L 46), so the vim keys work on
    // the ua and ru layouts too. The Qt key code is only the fallback when no scan code arrives.
    function physical(event): string {
        switch (event.nativeScanCode) {
        case 43: return "h";
        case 44: return "j";
        case 45: return "k";
        case 46: return "l";
        case 0:
            switch (event.key) {
            case Qt.Key_H: return "h";
            case Qt.Key_J: return "j";
            case Qt.Key_K: return "k";
            case Qt.Key_L: return "l";
            }
        }
        return "";
    }

    function activeFieldEmpty(): bool {
        return (field === "user" && otherSelected) ? typedUser === "" : password === "";
    }

    function handleKey(event) {
        const ctrlMod = (event.modifiers & Qt.ControlModifier) !== 0;
        const shiftMod = (event.modifiers & Qt.ShiftModifier) !== 0;
        const letter = physical(event);
        const key = event.key;
        event.accepted = true;

        if (menu !== "") {
            if (key === Qt.Key_Escape || (key === Qt.Key_F2 && menu === "session") || (key === Qt.Key_F12 && menu === "power"))
                closeMenu();
            else if (key === Qt.Key_Down || letter === "j")
                menuMove(1);
            else if (key === Qt.Key_Up || letter === "k")
                menuMove(-1);
            else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space || letter === "l")
                menuActivate(menuIndex);
            else if (letter === "h")
                closeMenu();
            return;
        }

        if (key === Qt.Key_F2) {
            openMenu("session");
        } else if (key === Qt.Key_F12) {
            openMenu("power");
        } else if (ctrlMod && letter === "h") {
            selectEntry(selected - 1);
        } else if (ctrlMod && letter === "l") {
            selectEntry(selected + 1);
        } else if (ctrlMod && letter === "j") {
            setField("password");
        } else if (ctrlMod && letter === "k") {
            setField("user");
        } else if (key === Qt.Key_Left && activeFieldEmpty()) {
            selectEntry(selected - 1);
        } else if (key === Qt.Key_Right && activeFieldEmpty()) {
            selectEntry(selected + 1);
        } else if (key === Qt.Key_Down && otherSelected) {
            setField("password");
        } else if (key === Qt.Key_Up && otherSelected) {
            setField("user");
        } else if (key === Qt.Key_Tab || key === Qt.Key_Backtab) {
            if (otherSelected)
                setField(field === "user" ? "password" : "user");
            else if (password === "")
                selectEntry(selected + ((key === Qt.Key_Backtab || shiftMod) ? -1 : 1));
        } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            submit();
        } else if (key === Qt.Key_Escape) {
            pressEscape();
        } else {
            event.accepted = false;
        }
    }

    // ---- start marker for run-qs ----------------------------------------------------------------------------------
    // run-qs waits for $XDG_RUNTIME_DIR/greeter-alive and falls back to tuigreet when it never appears.
    property bool aliveWritten: false

    function markAlive() {
        if (demoWindow || aliveWritten)
            return;
        aliveWritten = true;
        aliveProc.running = true;
    }

    Process {
        id: aliveProc
        command: ["touch", (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/greeter-alive"]
    }

    // ---- start ----------------------------------------------------------------------------------------------------
    Component.onCompleted: {
        try {
            cfg = JSON.parse(usersFile.text());
        } catch (e) {
            console.log("greeter: cannot read users.json: " + e);
        }
        selected = entryIndexOfMain();
        if (Hyprland.focusedMonitor && !demoWindow)
            pointerScreen = Hyprland.focusedMonitor.name;
    }
}
