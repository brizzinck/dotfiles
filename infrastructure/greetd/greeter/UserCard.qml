// One entry of the user row: a monogram avatar (letter in the user's accent inside a ring). The selected entry is large
// with a halo; the others are small and dimmed. "Other user..." is the entry that asks for a typed name.
import QtQuick

Item {
    id: card

    required property var entry
    required property bool selected
    required property color accent

    signal clicked

    readonly property real big: 128
    readonly property real small: 72
    readonly property real centerY: 78
    readonly property bool other: entry.kind === "other"

    width: selected ? 176 : 112
    height: 214
    Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }

    // halo around the selected avatar
    Rectangle {
        width: 156
        height: 156
        radius: 78
        x: (card.width - width) / 2
        y: card.centerY - 78
        color: Theme.alpha(card.accent, 0.18)
        opacity: card.selected ? 1 : 0
        Behavior on opacity {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
    }

    Rectangle {
        id: avatar
        width: card.selected ? card.big : card.small
        height: width
        radius: width / 2
        x: (card.width - width) / 2
        y: card.centerY - height / 2
        color: Theme.surface
        border.width: card.selected ? 3 : 1
        border.color: card.selected ? card.accent : Theme.border
        opacity: card.selected ? 1 : 0.45
        Behavior on width {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
        Behavior on opacity {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }

        Text {
            anchors.centerIn: parent
            text: card.other ? "+" : card.entry.name.charAt(0).toUpperCase()
            color: card.selected ? card.accent : Theme.subtext
            font.family: Theme.font
            font.bold: true
            font.pixelSize: avatar.width * 0.44
        }
    }

    Text {
        id: nameText
        anchors.horizontalCenter: parent.horizontalCenter
        y: 164
        text: card.other ? "Other user..." : card.entry.name
        color: card.selected ? Theme.fgHi : Theme.muted
        font.family: Theme.font
        font.bold: card.selected
        font.pixelSize: card.selected ? 20 : 13
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 192
        visible: card.selected && card.entry.main
        text: "main"
        color: Theme.green
        font.family: Theme.font
        font.pixelSize: 11
        font.letterSpacing: 2.5
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: card.clicked()
    }
}
