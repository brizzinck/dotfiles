// The login form: user row (monogram avatars), optional user name field for "Other user...", password field and the
// status line. Only the output that currently has the pointer shows it (OutputView loads it there).
pragma ComponentBehavior: Bound
import QtQuick

Item {
    id: form

    required property var ctrl
    property real shakeX: 0

    width: 360
    height: 380

    // focus goes to whichever field is active
    function focusField() {
        if (ctrl.otherSelected && ctrl.field === "user")
            userField.focusInput();
        else
            passwordField.focusInput();
    }

    Component.onCompleted: {
        // a form that arrives on another output takes over what was typed on the previous one
        userField.text = ctrl.typedUser;
        passwordField.text = ctrl.password;
        focusField();
    }

    Connections {
        target: form.ctrl

        function onFocusRequested() {
            form.focusField();
        }

        function onShake() {
            shakeAnim.restart();
        }

        function onPasswordChanged() {
            if (passwordField.text !== form.ctrl.password)
                passwordField.text = form.ctrl.password;
        }

        function onTypedUserChanged() {
            if (userField.text !== form.ctrl.typedUser)
                userField.text = form.ctrl.typedUser;
        }
    }

    SequentialAnimation {
        id: shakeAnim
        NumberAnimation { target: form; property: "shakeX"; to: 12; duration: 45 }
        NumberAnimation { target: form; property: "shakeX"; to: -12; duration: 70 }
        NumberAnimation { target: form; property: "shakeX"; to: 8; duration: 60 }
        NumberAnimation { target: form; property: "shakeX"; to: -8; duration: 60 }
        NumberAnimation { target: form; property: "shakeX"; to: 0; duration: 45 }
    }

    Row {
        id: users
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 12

        Repeater {
            model: form.ctrl.entries

            UserCard {
                required property int index
                required property var modelData

                entry: modelData
                selected: form.ctrl.selected === index
                accent: form.ctrl.accentColor(modelData.accent)
                onClicked: {
                    form.ctrl.selectEntry(index);
                }
            }
        }
    }

    Item {
        id: fields
        x: form.shakeX
        y: users.height
        width: parent.width
        height: parent.height - users.height

        Field {
            id: userField
            ctrl: form.ctrl
            x: (parent.width - width) / 2
            y: 24
            placeholder: "user name"
            active: form.ctrl.field === "user"
            outline: form.ctrl.busy ? Theme.yellow : (active ? Theme.green : Theme.border)
            opacity: form.ctrl.otherSelected ? 1 : 0
            enabled: form.ctrl.otherSelected
            visible: opacity > 0
            Behavior on opacity {
                NumberAnimation { duration: 140 }
            }
            onTextChanged: form.ctrl.typedUser = text
        }

        Field {
            id: passwordField
            ctrl: form.ctrl
            x: (parent.width - width) / 2
            y: form.ctrl.otherSelected ? 84 : 24
            secret: !(form.ctrl.awaitingExtra && form.ctrl.extraEcho)
            placeholder: form.ctrl.awaitingExtra ? form.ctrl.extraPrompt.replace(/:\s*$/, "")
                : (form.ctrl.layoutCode !== "" ? form.ctrl.layoutCode + " · password" : "password")
            active: form.ctrl.field === "password"
            outline: form.ctrl.failed ? Theme.red
                : (form.ctrl.busy ? Theme.yellow : (active ? Theme.green : Theme.border))
            Behavior on y {
                NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
            }
            onTextChanged: form.ctrl.password = text
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: passwordField.y + passwordField.height + 14
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: form.ctrl.busy && form.ctrl.statusText === "" ? "checking..." : form.ctrl.statusText
            color: form.ctrl.statusKind === 2 ? Theme.red : Theme.subtext
            font.family: Theme.font
            font.pixelSize: 13
        }
    }
}
