// A 300x48 input field in the hyprlock style: rounded, 2 px outline, placeholder in muted. With `revealable` an eye button
// sits at the right edge (click or Ctrl+E toggles ctrl.revealed; the owner of the field turns `secret` on and off).
pragma ComponentBehavior: Bound
import QtQuick

Rectangle {
    id: field

    required property var ctrl
    property alias text: input.text
    property string placeholder: ""
    property bool secret: false
    property bool revealable: false         // show the eye button (the password field)
    property bool active: false             // this field owns the keyboard
    property color outline: Theme.border

    // the cursor goes to the end of the text, so a kept (failed) password can be edited right away
    function focusInput() {
        input.forceActiveFocus();
        input.cursorPosition = input.length;
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
        anchors.leftMargin: field.revealable ? 44 : 16        // symmetric, so the text stays centred next to the eye
        anchors.rightMargin: field.revealable ? 44 : 16
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

    // eye button: eye = the password is shown, eye-off = hidden (yellow while shown); the tooltip says the state and the key
    Item {
        id: eye
        visible: field.revealable
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 44

        Text {
            anchors.centerIn: parent
            text: field.ctrl.revealed ? "󰈈" : "󰈉"
            color: field.ctrl.revealed ? Theme.yellow : (eyeArea.containsMouse ? Theme.fg : Theme.muted)
            font.family: Theme.font
            font.pixelSize: 18
        }

        MouseArea {
            id: eyeArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: field.ctrl.toggleReveal()
        }

        Rectangle {
            visible: eyeArea.containsMouse
            anchors.right: parent.right
            anchors.bottom: parent.top
            anchors.bottomMargin: 8
            width: tip.implicitWidth + 20
            height: tip.implicitHeight + 12
            radius: 6
            color: Theme.raised
            border.width: 1
            border.color: Theme.border

            Text {
                id: tip
                anchors.centerIn: parent
                text: field.ctrl.revealed ? "Password shown · Ctrl+E hides it" : "Password hidden · Ctrl+E shows it"
                color: Theme.subtext
                font.family: Theme.font
                font.pixelSize: 12
            }
        }
    }
}
