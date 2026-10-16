// What one output shows. Every output has the black background and the clock; the output that has the pointer also gets
// the form and the bottom bar (the form follows the mouse). The clock block moves up where the form appears.
pragma ComponentBehavior: Bound
import QtQuick

Item {
    id: view

    required property var ctrl
    required property string screenName

    readonly property bool isForm: ctrl.formScreen === screenName
    readonly property real stackHeight: 530
    readonly property real stackTop: Math.max(24, (height - stackHeight) / 2 - 16)

    Rectangle {
        anchors.fill: parent
        color: Theme.bgOled
    }

    // the pointer decides where the form is (a passive handler: it does not block the clicks of the items above it)
    HoverHandler {
        onHoveredChanged: {
            if (hovered)
                view.ctrl.pointerEntered(view.screenName);
        }
    }

    ClockPane {
        id: clockPane
        ctrl: view.ctrl
        x: (parent.width - width) / 2
        y: view.isForm ? view.stackTop : (parent.height - height) / 2
        Behavior on y {
            NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
        }
    }

    Loader {
        id: formLoader
        active: view.isForm
        x: (parent.width - 360) / 2
        y: view.stackTop + 150
        width: 360
        height: 380
        sourceComponent: FormPane {
            ctrl: view.ctrl
            property real appear: 0
            property real idleFade: view.ctrl.idle ? 0 : 1
            opacity: appear * idleFade
            Behavior on idleFade {
                NumberAnimation { duration: 500 }
            }
            Behavior on appear {
                NumberAnimation { duration: 220 }
            }
            Component.onCompleted: appear = 1
        }
    }

    Loader {
        active: view.isForm
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 46
        sourceComponent: BottomBar {
            ctrl: view.ctrl
            opacity: view.ctrl.idle ? 0 : 1
            Behavior on opacity {
                NumberAnimation { duration: 500 }
            }
        }
    }

    // fade to black before the session starts
    Rectangle {
        anchors.fill: parent
        color: Theme.bgOled
        opacity: view.ctrl.fading ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation { duration: 260 }
        }
    }

    Component.onCompleted: ctrl.markAlive()
}
