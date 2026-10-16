// Login screen (greetd greeter) for the Quickshell runtime: one black full-screen layer per output with the clock, and the
// login form on the output that has the pointer. Runs in a minimal Hyprland (/etc/greetd/hyprland.lua) started by greetd;
// `GREETER_DEMO=1 qs -p <this dir>` shows the same screens in a floating window with a fake greetd (password: demo);
// see "Login screen" in CLAUDE.md.
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell

ShellRoot {
    id: root

    // real mode: one layer-shell window per output (Screens.qml). The component is created only here: PanelWindow cannot
    // even be compiled without a layer-shell backend, which would break the offscreen self-test and the demo window.
    LazyLoader {
        active: !Greeter.demoWindow
        component: Greeter.demoWindow ? null : Qt.createComponent(Qt.resolvedUrl("Screens.qml"))
    }

    // demo mode: a floating window with two virtual outputs side by side (move the pointer between them)
    LazyLoader {
        active: Greeter.demoWindow

        FloatingWindow {
            id: demoWindow

            title: "Greeter demo"
            implicitWidth: 1700
            implicitHeight: 950
            color: Theme.bgOled

            Row {
                id: demoRow

                anchors.fill: parent

                Repeater {
                    model: Greeter.demoScreens

                    OutputView {
                        required property string modelData
                        width: parent.width / 2
                        height: parent.height
                        ctrl: Greeter
                        screenName: modelData
                    }
                }
            }

            // scripted self-test (see SelfTest.qml): only with GREETER_SELFTEST=1 in the demo window
            LazyLoader {
                active: Quickshell.env("GREETER_SELFTEST") === "1"

                SelfTest {
                    target: demoRow
                }
            }
        }
    }
}
