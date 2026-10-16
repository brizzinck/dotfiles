// One black full-screen layer-shell window per output; the keyboard follows the form. Loaded by shell.qml (real mode only).
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland

Variants {
    model: Quickshell.screens

    PanelWindow {
        id: win

        required property var modelData
        readonly property bool isForm: Greeter.formScreen === modelData.name

        screen: modelData
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: Theme.bgOled
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "greeter"
        WlrLayershell.keyboardFocus: isForm ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        OutputView {
            anchors.fill: parent
            ctrl: Greeter
            screenName: win.modelData.name
        }
    }
}
