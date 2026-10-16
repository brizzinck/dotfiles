// A 300x48 input field in the hyprlock style: rounded, 2 px outline, placeholder in muted.
pragma ComponentBehavior: Bound
import QtQuick

Rectangle {
    id: field

    required property var ctrl
    property alias text: input.text
    property string placeholder: ""
    property bool secret: false
    property bool active: false             // this field owns the keyboard
    property color outline: Theme.border

    function focusInput() {
        input.forceActiveFocus();
    }

    width: 300
    height: 48
    radius: 8
    color: Theme.bgOled
    border.width: 2
    border.color: outline
    Behavior on border.color {
        ColorAnimation { duration: 120 }
    }

    TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        clip: true
        color: Theme.fg
        selectionColor: Theme.select
        selectedTextColor: Theme.fgHi
        font.family: Theme.font
        font.pixelSize: field.secret ? 13 : 16
        font.letterSpacing: field.secret ? 5 : 0
        echoMode: field.secret ? TextInput.Password : TextInput.Normal
        passwordCharacter: "●"
        passwordMaskDelay: 0
        autoScroll: true
        inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhSensitiveData
        cursorDelegate: Rectangle {
            width: 2
            color: Theme.fgHi
            visible: field.active && input.text !== ""
        }
        Keys.onPressed: event => field.ctrl.handleKey(event)

        Text {
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            visible: input.text === ""
            text: field.placeholder
            color: field.ctrl.layoutWarn && field.secret ? Theme.yellow : Theme.muted
            font.family: Theme.font
            font.pixelSize: 14
            elide: Text.ElideRight
        }
    }
}
