// A small clickable label of the bottom bar: "<glyph> <text>" and an optional dimmed key hint.
import QtQuick

Item {
    id: pill

    property string text: ""
    property string hint: ""
    property color tint: Theme.muted

    signal clicked

    implicitWidth: row.implicitWidth + 20
    implicitHeight: 30

    Rectangle {
        anchors.fill: parent
        radius: 8
        color: area.containsMouse ? Theme.raised : "transparent"
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 8

        Text {
            text: pill.text
            color: pill.tint
            font.family: Theme.font
            font.pixelSize: 13
        }

        Text {
            visible: pill.hint !== ""
            text: pill.hint
            color: Theme.border
            font.family: Theme.font
            font.pixelSize: 11
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: pill.clicked()
    }
}
