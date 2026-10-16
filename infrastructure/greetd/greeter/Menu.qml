// A small popup list (session or power). Keys are handled by Greeter.handleKey: j/k, arrows, Enter, Esc.
pragma ComponentBehavior: Bound
import QtQuick

Rectangle {
    id: menu

    required property var ctrl
    required property string kind          // "session" or "power"
    property var items: []                  // [{ label, glyph }]

    visible: ctrl.menu === kind
    width: 200
    height: column.implicitHeight + 16
    radius: 10
    color: Theme.surface
    border.width: 1
    border.color: Theme.border

    Column {
        id: column
        anchors.fill: parent
        anchors.margins: 8
        spacing: 2

        Repeater {
            model: menu.items

            Rectangle {
                id: row
                required property int index
                required property var modelData

                width: column.width
                height: 32
                radius: 6
                color: menu.ctrl.menuIndex === index ? Theme.select : "transparent"

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 10
                    text: (row.modelData.glyph ?? "") + (row.modelData.glyph ? "  " : "") + row.modelData.label
                    color: menu.ctrl.menuIndex === row.index ? Theme.fgHi : Theme.subtext
                    font.family: Theme.font
                    font.pixelSize: 13
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    visible: menu.kind === "session" && menu.ctrl.sessionIndex === row.index
                    text: "󰄬"
                    color: Theme.green
                    font.family: Theme.font
                    font.pixelSize: 13
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: menu.ctrl.menuIndex = row.index
                    onClicked: menu.ctrl.menuActivate(row.index)
                }
            }
        }
    }
}
