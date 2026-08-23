import QtQuick
import QtQuick.Layouts

import "../../../common"
import "../../../common/widgets"
import "../../../../services"

// Local "Flip a Coin" card. The result is decided by the plugin before this
// component is created (messageData.coinResult); the animation only
// visualizes it, so spin and outcome always agree. Renders instantly in the
// landed state unless freshly created with _playAnimation set.
ColumnLayout {
    id: root

    required property var messageData
    readonly property bool heads: messageData?.coinResult === true
    readonly property bool shouldAnimate: messageData?.playAnimation === true

    property bool landed: !shouldAnimate
    property real coinRotation: heads ? 180 : 0
    property real coinHop: 0
    property real coinScale: 1

    Layout.fillWidth: true
    spacing: 8

    Item {
        id: coinArea
        width: 80
        height: 84
        anchors.horizontalCenter: parent.horizontalCenter
        Layout.topMargin: 6

        Rectangle {
            id: coin
            width: 72
            height: 72
            radius: 36
            x: (parent.width - width) / 2
            y: (parent.height - height) / 2 - coinHop
            scale: root.coinScale
            color: Appearance.colors.colPrimaryContainer
            border.color: Appearance.colors.colOutline
            border.width: 2

            transform: Rotation {
                id: flipRotation
                origin.x: coin.width / 2
                origin.y: coin.height / 2
                axis { x: 0; y: 1; z: 0 }
                angle: root.coinRotation
            }

            StyledText {
                anchors.centerIn: parent
                text: root.landed ? (root.heads ? "H" : "T") : "?"
                font.pixelSize: 28
                font.bold: true
                color: Appearance.colors.colOnPrimaryContainer
            }
        }
    }

    RowLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Appearance.spacing?.sm ?? 6

        StyledText {
            id: resultLabel
            text: root.landed ? (root.heads ? Translation.tr("HEADS") : Translation.tr("TAILS")) : ""
            font.pixelSize: Appearance.font.pixelSize.small
            font.bold: true
            color: Appearance.colors.colOnSurface
        }

        ButtonGroup {
            AiMessageControlButton {
                buttonIcon: "refresh"
                enabled: root.landed
                opacity: root.landed ? 1 : 0

                Behavior on opacity {
                    NumberAnimation { duration: 180 }
                }

                onClicked: {
                    if (!root.messageData) return;
                    root.messageData.coinResult = Math.random() < 0.5;
                    root.landed = false;
                    root.startSpin();
                }

                StyledToolTip {
                    text: Translation.tr("Flip again")
                }
            }
        }
    }

    function startSpin() {
        // Never restart mid-flight, and always animate FORWARD from wherever
        // the coin currently rests — no snap-backs, no chained replays.
        if (flipAnim.running) return;
        const current = flipRotation.angle;
        const targetMod = root.heads ? 0 : 180;
        const currentMod = ((current % 360) + 360) % 360;
        const delta = 4 * 360 + ((targetMod - currentMod + 360) % 360);
        flipAnim.from = current;
        flipAnim.to = current + delta;
        flipAnim.restart();
    }

    function finishLanding() {
        root.landed = true;
        // One-shot semantics: clear the transient trigger so list recycling
        // (delegate recreation) never replays the spin on its own.
        if (root.messageData) root.messageData.playAnimation = false;
        landBounce.start();
    }

    SequentialAnimation {
        id: flipAnim
        property real from: 0
        property real to: 1440
        NumberAnimation {
            target: flipRotation
            property: "angle"
            from: flipAnim.from
            duration: 1050
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: flipRotation
            property: "angle"
            to: flipAnim.to
            duration: 260
            easing.type: Easing.OutQuad
        }
        ScriptAction { script: root.finishLanding() }
    }

    SequentialAnimation {
        id: landBounce
        NumberAnimation { target: root; property: "coinScale"; from: 1; to: 0.9; duration: 90; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "coinScale"; from: 0.9; to: 1; duration: 170; easing.type: Easing.OutBack }
    }

    Component.onCompleted: {
        if (root.shouldAnimate) startSpin();
        else finishLanding();
    }
}
