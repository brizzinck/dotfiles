// Clock and date, the hyprlock look: HH:mm at 72 px in fg, "dddd, dd MMMM" at 20 px in subtext.
import QtQuick

Item {
    id: pane

    required property var ctrl

    width: 420
    height: dateText.y + dateText.height

    Text {
        id: timeText
        anchors.horizontalCenter: parent.horizontalCenter
        text: pane.ctrl.timeText
        color: Theme.fg
        font.family: Theme.font
        font.pixelSize: 72
    }

    Text {
        id: dateText
        anchors.horizontalCenter: parent.horizontalCenter
        y: timeText.height + 6
        text: pane.ctrl.dateText
        color: Theme.subtext
        font.family: Theme.font
        font.pixelSize: 20
    }
}
