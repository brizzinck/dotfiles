// Scripted self-test of the login logic, run headless with the demo window and the fake greetd backend:
//   GREETER_SELFTEST=1 GREETER_DEMO=1 GREETER_SELFTEST_OUT=/some/dir QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
//     qs -p infrastructure/greetd/greeter
// It drives Greeter with fake key events (including a Cyrillic key with a Latin physical key), prints "SELFTEST <step>:
// ok|FAIL" lines and quits. When GREETER_SELFTEST_OUT is set it also saves PNG renders of the demo window (own items only,
// never the screen). Not used by the real greeter.
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell

Scope {
    id: test

    required property Item target          // the item that holds the demo outputs
    property int step: 0
    property int failures: 0
    readonly property string outDir: Quickshell.env("GREETER_SELFTEST_OUT") || ""

    function check(name: string, cond: bool) {
        console.log("SELFTEST " + name + ": " + (cond ? "ok" : "FAIL"));
        if (!cond)
            failures += 1;
    }

    function key(code: int, scan: int, mods: int): bool {
        const event = { key: code, nativeScanCode: scan, modifiers: mods, accepted: false };
        Greeter.handleKey(event);
        return event.accepted;
    }

    function shot(name: string) {
        if (outDir === "")
            return;
        target.grabToImage(result => {
            const ok = result.saveToFile(outDir + "/" + name + ".png");
            console.log("SELFTEST shot " + name + ": " + (ok ? "saved" : "FAIL"));
        });
    }

    function run() {
        switch (step) {
        case 0:
            check("two entries (main user + other)", Greeter.entries.length === 2);
            check("main user preselected", Greeter.selected === 0 && Greeter.current.name === Greeter.cfg.main && Greeter.current.main);
            check("login user is the main user", Greeter.loginUser === Greeter.cfg.main && Greeter.loginUser !== "");
            check("form on the first output", Greeter.formScreen === "DEMO-1");
            check("sessions loaded", Greeter.sessions.length === 2 && Greeter.sessions[0].id === "hyprland");
            Greeter.password = "";
            Greeter.parseDevices('{"keyboards":[{"name":"video-bus","main":false,"active_keymap":"English (US)"},{"name":"kbd","main":true,"active_keymap":"English (US)"}]}');
            check("layout from hyprctl devices (main keyboard)", Greeter.layoutCode === "US" && !Greeter.layoutWarn);
            shot("main");
            return 400;
        case 1:
            // Ctrl+L (physical L = 46) next entry; Cyrillic key code, Latin physical key
            check("ctrl+L accepted", key(Qt.Key_Cyrillic_el, 46, Qt.ControlModifier));
            check("ctrl+L selects Other user", Greeter.otherSelected && Greeter.field === "user");
            check("ctrl+H (Cyrillic key, scan 43) goes back", key(Qt.Key_Cyrillic_er, 43, Qt.ControlModifier) && Greeter.selected === 0);
            key(Qt.Key_Right, 0, 0);
            check("Right on an empty field selects Other user", Greeter.otherSelected);
            check("ctrl+J moves to the password field", key(Qt.Key_J, 44, Qt.ControlModifier) && Greeter.field === "password");
            check("ctrl+K moves to the user field", key(Qt.Key_K, 45, Qt.ControlModifier) && Greeter.field === "user");
            Greeter.typedUser = "ghost";
            return 400;
        case 2:
            shot("other");
            Greeter.setField("password");
            Greeter.password = "bad";
            check("Enter submits", key(Qt.Key_Return, 36, 0) && Greeter.busy);
            return 300;
        case 3:
            shot("checking");
            check("busy while checking", Greeter.busy && Greeter.statusText === "");
            return 1100;
        case 4:
            check("wrong password: failed state", !Greeter.busy && Greeter.failed && Greeter.attempts === 1);
            check("wrong password: status text", Greeter.statusText === "Wrong user or password (1)" && Greeter.statusKind === 2);
            check("wrong password: field cleared", Greeter.password === "");
            check("PAM service error text", Greeter.errorText("authentication error: pam_authenticate: SERVICE_ERR") === "Login failed: PAM service error (see journalctl -u greetd)");
            check("lost connection text", Greeter.errorText("failed to send").indexOf("lost the connection to greetd") >= 0);
            check("other error text", Greeter.errorText("boom") === "Login failed: boom (see journalctl -u greetd)");
            Greeter.onLayoutEvent("at-translated-set-2-keyboard,Ukrainian");
            check("activelayout event: Ukrainian -> UA, warns", Greeter.layoutCode === "UA" && Greeter.layoutWarn);
            Greeter.onLayoutEvent("kbd,Russian");
            check("activelayout event: Russian -> RU", Greeter.layoutCode === "RU");
            shot("failed");
            return 400;
        case 5:
            Greeter.password = "x";
            check("typing clears the failed state", !Greeter.failed && Greeter.statusText === "");
            key(Qt.Key_Escape, 9, 0);
            check("Esc clears the password", Greeter.password === "");
            key(Qt.Key_Escape, 9, 0);
            check("Esc (password field, user typed) goes to the user field", Greeter.field === "user");
            key(Qt.Key_Escape, 9, 0);
            check("Esc leaves Other user for the main user", Greeter.selected === 0 && !Greeter.otherSelected);
            return 200;
        case 6:
            Greeter.pointerEntered("DEMO-2");
            check("the form follows the pointer", Greeter.formScreen === "DEMO-2");
            Greeter.pointerEntered("elsewhere");
            check("an unknown output keeps the last form", Greeter.formScreen === "DEMO-2" || Greeter.formScreen === "DEMO-1");
            Greeter.pointerEntered("DEMO-2");
            Greeter.onLayoutEvent("kbd,English (US)");
            check("activelayout event: English (US) -> US", Greeter.layoutCode === "US" && !Greeter.layoutWarn);
            shot("form-moved");
            return 400;
        case 7:
            check("F2 opens the session menu", key(Qt.Key_F2, 68, 0) && Greeter.menu === "session");
            check("j moves down", key(Qt.Key_J, 44, 0) && Greeter.menuIndex === 1);
            check("Enter picks the Shell session", key(Qt.Key_Return, 36, 0) && Greeter.sessionIndex === 1 && Greeter.menu === "");
            key(Qt.Key_F2, 68, 0);
            key(Qt.Key_K, 45, 0);
            key(Qt.Key_Return, 36, 0);
            check("k + Enter picks Hyprland again", Greeter.sessionIndex === 0);
            check("F12 opens the power menu", key(Qt.Key_F12, 96, 0) && Greeter.menu === "power");
            shot("menu");
            return 400;
        case 8:
            key(Qt.Key_Escape, 9, 0);
            check("Esc closes the menu", Greeter.menu === "");
            Greeter.pointerEntered("DEMO-1");
            Greeter.password = "demo";
            check("Enter with the right password", key(Qt.Key_Return, 36, 0) && Greeter.busy);
            return 1500;
        case 9:
            check("launch fades the screen", Greeter.fading);
            check("the fake backend reached the launch step", Greeter.fakeLaunched);
            shot("fading");
            return 500;
        default:
            console.log("SELFTEST done: " + (failures === 0 ? "ALL OK" : failures + " FAILED"));
            Qt.exit(failures === 0 ? 0 : 1);
            return 1000;
        }
    }

    Timer {
        id: timer
        interval: 800
        running: true
        onTriggered: {
            interval = test.run();
            test.step += 1;
            restart();
        }
    }
}
