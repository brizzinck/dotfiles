// Bottom bar of the form output: host name, session / layout / power pills (with their popup menus), battery.
import QtQuick

Item {
    id: bar

    required property var ctrl

    height: 46

    Text {
        anchors.left: parent.left
        anchors.leftMargin: 24
        anchors.verticalCenter: parent.verticalCenter
        text: bar.ctrl.hostname
        color: Theme.muted
        font.family: Theme.font
        font.pixelSize: 13
    }

    Row {
        id: pills
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4

        Pill {
            id: sessionPill
            text: "󰖲  " + (bar.ctrl.sessions.length > 0 ? bar.ctrl.sessions[bar.ctrl.sessionIndex].label : "")
            hint: "F2"
            onClicked: bar.ctrl.openMenu("session")

            Menu {
                ctrl: bar.ctrl
                kind: "session"
                items: bar.ctrl.sessions
                anchors.bottom: parent.top
                anchors.bottomMargin: 10
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }

        // switched with Caps by the compositor; the pill only shows it (yellow while it is not US)
        Pill {
            id: layoutPill
            visible: bar.ctrl.layoutCode !== ""
            text: "󰌌  " + bar.ctrl.layoutCode
            hint: "Caps"
            tint: bar.ctrl.layoutWarn ? Theme.yellow : Theme.muted
        }

        Pill {
            id: powerPill
            text: "󰐥"
            hint: "F12"
            onClicked: bar.ctrl.openMenu("power")

            Menu {
                ctrl: bar.ctrl
                kind: "power"
                items: bar.ctrl.powerItems
                anchors.bottom: parent.top
                anchors.bottomMargin: 10
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    Text {
        anchors.right: parent.right
        anchors.rightMargin: 24
        anchors.verticalCenter: parent.verticalCenter
        visible: bar.ctrl.battery >= 0
        text: "󰁹 " + bar.ctrl.battery + "%"
        color: Theme.muted
        font.family: Theme.font
        font.pixelSize: 13
    }
}
